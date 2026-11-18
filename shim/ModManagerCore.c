// ModManagerCore.c - the two native pieces of the in-app mod manager (shim/ModManager.swift):
//   MSModExtract   unpacks a mod archive (zip / 7z / rar / rar5 / tar.*) with libarchive into a fresh folder
//   MSModCompile   compiles the redscript sources on the phone with scc (Frameworks/libscc_lib.dylib, loaded on demand)
// The archive is untrusted: only regular files and folders are written, every path is rebuilt from checked
// components under the destination (no "..", no absolute paths, no links, O_EXCL|O_NOFOLLOW), nothing is ever run.
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include "third_party/libarchive/include/archive.h"
#include "third_party/libarchive/include/archive_entry.h"

#define MS_EXPORT __attribute__((visibility("default")))

static _Atomic long long g_extractBytes;      /* bytes written so far by the running MSModExtract */
static _Atomic int g_extractCancel;

MS_EXPORT long long MSModExtractProgress(void) { return atomic_load(&g_extractBytes); }
MS_EXPORT void MSModExtractCancel(void) { atomic_store(&g_extractCancel, 1); }

static void ms_err(char *err, size_t cap, const char *fmt, const char *a) {
    if (err && cap) snprintf(err, cap, fmt, a ? a : "");
}

/* mkdir -p for `path` (which lies under a folder we created ourselves) */
static int ms_mkdirs(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        int r = mkdir(path, 0755);
        *p = '/';
        if (r != 0 && errno != EEXIST) return -1;
    }
    if (mkdir(path, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

/* Rebuilds an archive entry name as a clean relative path ("a/b/c"). Returns 0 = ok, 1 = skip (macOS junk / empty),
 * -1 = unsafe ("..", control characters, too long). */
static int ms_clean_path(const char *in, char *out, size_t cap) {
    size_t o = 0;
    const char *p = in;
    if (strlen(in) >= cap) return -1;
    while (*p) {
        while (*p == '/' || *p == '\\') p++;                 /* also drops a leading "/" (absolute path) */
        const char *s = p;
        while (*p && *p != '/' && *p != '\\') { if ((unsigned char)*p < 0x20) return -1; p++; }
        size_t n = (size_t)(p - s);
        if (n == 0) break;
        if (n == 1 && s[0] == '.') continue;
        if (n == 2 && s[0] == '.' && s[1] == '.') return -1;
        if (n >= 2 && s[0] == '.' && s[1] == '_') return 1;                       /* AppleDouble */
        if (n == 9 && strncasecmp(s, ".DS_Store", 9) == 0) return 1;
        if (n == 8 && strncasecmp(s, "__MACOSX", 8) == 0) return 1;
        if (o == 0 && n == 2 && s[1] == ':') continue;                            /* "C:" */
        if (o) out[o++] = '/';
        memcpy(out + o, s, n); o += n;
    }
    out[o] = 0;
    return o ? 0 : 1;
}

/* Unpacks `src` into the existing, empty folder `dst`. maxBytes caps the total unpacked size (zip bombs / full disk).
 * Returns the number of files written, or -1 with a message in err. */
MS_EXPORT int MSModExtract(const char *src, const char *dst, long long maxBytes, char *err, size_t errCap) {
    atomic_store(&g_extractBytes, 0); atomic_store(&g_extractCancel, 0);
    struct archive *a = archive_read_new();
    if (!a) { ms_err(err, errCap, "out of memory%s", ""); return -1; }
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    if (archive_read_open_filename(a, src, 1 << 20) != ARCHIVE_OK) {
        ms_err(err, errCap, "Can't open the archive: %s", archive_error_string(a));
        archive_read_free(a); return -1;
    }
    static const size_t kBuf = 1 << 20;
    char *buf = malloc(kBuf), *path = malloc(4096), *rel = malloc(2048);
    int files = 0, rc = 0, entries = 0;
    long long total = 0;
    struct archive_entry *e;
    for (;;) {
        int r = archive_read_next_header(a, &e);
        if (r == ARCHIVE_EOF) break;
        if (r == ARCHIVE_RETRY) continue;
        if (r < ARCHIVE_WARN) { ms_err(err, errCap, "The archive is damaged or not supported: %s", archive_error_string(a)); rc = -1; break; }
        if (atomic_load(&g_extractCancel)) { ms_err(err, errCap, "Cancelled%s", ""); rc = -1; break; }
        if (++entries > 200000) { ms_err(err, errCap, "Too many files in the archive%s", ""); rc = -1; break; }
        const char *name = archive_entry_pathname_utf8(e);
        if (!name) name = archive_entry_pathname(e);
        if (!name) continue;
        int c = ms_clean_path(name, rel, 2048);
        if (c < 0) { ms_err(err, errCap, "Refused: the archive has an unsafe file path (%s)", name); rc = -1; break; }
        if (c > 0) continue;
        if (archive_entry_is_encrypted(e)) { ms_err(err, errCap, "Password-protected archives are not supported%s", ""); rc = -1; break; }
        mode_t type = archive_entry_filetype(e);
        if (archive_entry_hardlink(e) || archive_entry_symlink(e)) continue;      /* links are never created */
        snprintf(path, 4096, "%s/%s", dst, rel);
        if (type == AE_IFDIR) { if (ms_mkdirs(path) != 0) { ms_err(err, errCap, "Can't create a folder: %s", strerror(errno)); rc = -1; break; } continue; }
        if (type != AE_IFREG) continue;                                           /* devices, fifos, sockets */
        char *slash = strrchr(path, '/');
        *slash = 0;
        if (ms_mkdirs(path) != 0) { ms_err(err, errCap, "Can't create a folder: %s", strerror(errno)); rc = -1; break; }
        *slash = '/';
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
        if (fd < 0) {
            if (errno == EEXIST) continue;                                        /* same name twice: the first one stays */
            ms_err(err, errCap, "Can't write a file: %s", strerror(errno)); rc = -1; break;
        }
        for (;;) {
            la_ssize_t n = archive_read_data(a, buf, kBuf);
            if (n == 0) break;
            if (n == ARCHIVE_RETRY) continue;
            if (n < 0) { ms_err(err, errCap, "The archive is damaged or not supported: %s", archive_error_string(a)); rc = -1; break; }
            total += n;
            if (total > maxBytes) { ms_err(err, errCap, "Not enough free space to unpack this mod%s", ""); rc = -1; break; }
            if (atomic_load(&g_extractCancel)) { ms_err(err, errCap, "Cancelled%s", ""); rc = -1; break; }
            ssize_t w = 0;
            while (w < n) { ssize_t k = write(fd, buf + w, (size_t)(n - w)); if (k < 0) { if (errno == EINTR) continue; break; } w += k; }
            if (w < n) { ms_err(err, errCap, "Can't write a file: %s", strerror(errno)); rc = -1; break; }
            atomic_store(&g_extractBytes, total);
        }
        close(fd);
        if (rc != 0) break;
        files++;
    }
    free(buf); free(path); free(rel);
    archive_read_free(a);
    return rc != 0 ? -1 : files;
}

/* ---------------------------------------------------------------- redscript (scc) */
typedef struct SccSettings SccSettings;
typedef struct SccResult SccResult;
typedef struct {
    const char *lib, *r6, *inBlob, *outBlob;
    const char *const *paths; int npaths;
    char *err; size_t errCap;
    int rc;
} MSCompileJob;

static void *ms_compile_thread(void *arg) {
    MSCompileJob *j = arg;
    j->rc = -1;
    void *h = dlopen(j->lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) { ms_err(j->err, j->errCap, "The script compiler is not in this build of the app (%s)", dlerror()); return NULL; }
    SccSettings *(*s_new)(const char *) = dlsym(h, "scc_settings_new");
    void (*s_in)(SccSettings *, const char *) = dlsym(h, "scc_settings_set_custom_cache_file");
    void (*s_out)(SccSettings *, const char *) = dlsym(h, "scc_settings_set_output_cache_file");
    void (*s_add)(SccSettings *, const char *) = dlsym(h, "scc_settings_add_script_path");
    void (*s_nopopup)(SccSettings *) = dlsym(h, "scc_settings_disable_error_popup");
    SccResult *(*compile)(SccSettings *) = dlsym(h, "scc_compile");
    void *(*success)(SccResult *) = dlsym(h, "scc_get_success");
    size_t (*copy_error)(SccResult *, char *, size_t) = dlsym(h, "scc_copy_error");
    void (*free_result)(SccResult *) = dlsym(h, "scc_free_result");
    if (!s_new || !s_in || !s_out || !s_add || !compile || !success || !copy_error || !free_result) {
        ms_err(j->err, j->errCap, "The script compiler library is not the expected one%s", ""); return NULL;
    }
    SccSettings *st = s_new(j->r6);
    if (s_nopopup) s_nopopup(st);
    s_in(st, j->inBlob);
    s_out(st, j->outBlob);
    for (int i = 0; i < j->npaths; i++) s_add(st, j->paths[i]);
    SccResult *res = compile(st);                       /* consumes the settings; never NULL */
    if (success(res)) j->rc = 0;
    else if (j->err && j->errCap) { j->err[0] = 0; copy_error(res, j->err, j->errCap); if (!j->err[0]) ms_err(j->err, j->errCap, "compile failed%s", ""); }
    free_result(res);
    /* the library stays loaded: it keeps a global logger, and unloading Rust code with live TLS is not safe */
    return NULL;
}

/* Compiles <r6>/scripts + the extra script folders against inBlob and writes outBlob (inBlob is not modified).
 * Blocking; runs scc on its own thread with an 8 MB stack. Returns 0 on success, -1 with the compiler's text in err. */
MS_EXPORT int MSModCompile(const char *sccLib, const char *r6, const char *inBlob, const char *outBlob,
                           const char *const *paths, int npaths, char *err, size_t errCap) {
    MSCompileJob j = { sccLib, r6, inBlob, outBlob, paths, npaths, err, errCap, -1 };
    if (err && errCap) err[0] = 0;
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 8u << 20);
    pthread_t t;
    if (pthread_create(&t, &at, ms_compile_thread, &j) != 0) { ms_err(err, errCap, "can't start the compiler thread%s", ""); return -1; }
    pthread_attr_destroy(&at);
    pthread_join(t, NULL);
    return j.rc;
}
