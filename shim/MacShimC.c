/*
 * MacShimC.c - C-level stand-ins for macOS-only APIs that the Cyberpunk 2077 Mac binary imports
 * but iOS does not provide: IOKit, CoreAudio (AudioObject*), CoreGraphics display/event calls,
 * a few macOS-only Security calls, and an OFFLINE stub of libcurl (iOS ships no libcurl).
 *
 * Deliberately header-free (own typedefs) so it builds without a macOS SDK and cannot clash with
 * iOS headers. Everything here fails gracefully; none of it changes game code.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

extern void *malloc(size_t); extern void *calloc(size_t, size_t); extern void free(void *);
extern char *strdup(const char *);

/* implemented in MacShim.m */
extern void MacShimScreenInfo(double *w_points, double *h_points, double *scale, double *max_fps);
extern void MacShimSetPointerLocked(int locked);
extern void MacShimLogC(const char *what, const char *detail);

/* CoreFoundation, declared by hand */
extern void *CFArrayCreate(const void *alloc, const void **values, long n, const void *callbacks);
extern void *CFStringCreateWithCString(const void *alloc, const char *s, uint32_t enc);
extern void *CFRetain(const void *cf);

#define EXPORT __attribute__((visibility("default"), used))
typedef int32_t kern_return_t;
typedef uint32_t mach_port_t, io_object_t, CGDirectDisplayID;
typedef struct { double x, y, w, h; } MSRect;

/* ============================== IOKit ============================== */
#define kIOReturnUnsupported ((kern_return_t)0xe00002c7)
EXPORT const mach_port_t kIOMainPortDefault = 0;

EXPORT void *IOServiceMatching(const char *name)                         { (void)name; return 0; }
EXPORT void *IORegistryEntryIDMatching(uint64_t id)                      { (void)id; return 0; }
EXPORT mach_port_t IOServiceGetMatchingService(mach_port_t p, void *m)   { (void)p; (void)m; return 0; }
EXPORT kern_return_t IOServiceGetMatchingServices(mach_port_t p, void *m, io_object_t *it) { (void)p; (void)m; if (it) *it = 0; return kIOReturnUnsupported; }
EXPORT io_object_t IOIteratorNext(io_object_t it)                        { (void)it; return 0; }
EXPORT kern_return_t IOObjectRelease(io_object_t o)                      { (void)o; return 0; }
EXPORT void *IORegistryEntryCreateCFProperty(io_object_t e, const void *k, const void *a, uint32_t o) { (void)e; (void)k; (void)a; (void)o; return 0; }
EXPORT void *IORegistryEntrySearchCFProperty(io_object_t e, const char *plane, const void *k, const void *a, uint32_t o) { (void)e; (void)plane; (void)k; (void)a; (void)o; return 0; }
EXPORT kern_return_t IOServiceOpen(io_object_t s, mach_port_t t, uint32_t type, io_object_t *c) { (void)s; (void)t; (void)type; if (c) *c = 0; return kIOReturnUnsupported; }
EXPORT kern_return_t IOServiceClose(io_object_t c)                       { (void)c; return 0; }
EXPORT kern_return_t IOConnectCallStructMethod(mach_port_t c, uint32_t sel, const void *in, size_t inSz, void *out, size_t *outSz) { (void)c; (void)sel; (void)in; (void)inSz; (void)out; (void)outSz; return kIOReturnUnsupported; }
EXPORT void *IONotificationPortCreate(mach_port_t p)                     { (void)p; return 0; }
EXPORT void IONotificationPortDestroy(void *n)                           { (void)n; }
EXPORT void IONotificationPortSetDispatchQueue(void *n, void *q)         { (void)n; (void)q; }
EXPORT kern_return_t IOServiceAddInterestNotification(void *n, io_object_t s, const char *t, void *cb, void *ref, io_object_t *o) { (void)n; (void)s; (void)t; (void)cb; (void)ref; if (o) *o = 0; return kIOReturnUnsupported; }
EXPORT void *IODisplayCreateInfoDictionary(io_object_t d, uint32_t opt)  { (void)d; (void)opt; return 0; }
EXPORT kern_return_t IODisplayGetFloatParameter(io_object_t d, uint32_t opt, const void *name, float *v) { (void)d; (void)opt; (void)name; if (v) *v = 0; return kIOReturnUnsupported; }

/* ============================== CoreAudio (AudioObject*) ============================== */
#define kAudioHardwareUnknownPropertyError ((int32_t)0x77686F3F) /* 'who?' */
EXPORT int32_t AudioObjectGetPropertyData(uint32_t o, const void *a, uint32_t qs, const void *q, uint32_t *sz, void *d) { (void)o; (void)a; (void)qs; (void)q; (void)sz; (void)d; return kAudioHardwareUnknownPropertyError; }
EXPORT int32_t AudioObjectGetPropertyDataSize(uint32_t o, const void *a, uint32_t qs, const void *q, uint32_t *sz) { (void)o; (void)a; (void)qs; (void)q; if (sz) *sz = 0; return kAudioHardwareUnknownPropertyError; }
EXPORT int32_t AudioObjectSetPropertyData(uint32_t o, const void *a, uint32_t qs, const void *q, uint32_t sz, const void *d) { (void)o; (void)a; (void)qs; (void)q; (void)sz; (void)d; return kAudioHardwareUnknownPropertyError; }

/* ============================== CoreGraphics (macOS-only parts) ============================== */
EXPORT const void *kCGDisplayShowDuplicateLowResolutionModes = 0;
__attribute__((constructor)) static void ms_init_cg(void) {
    kCGDisplayShowDuplicateLowResolutionModes = CFStringCreateWithCString(0, "kCGDisplayShowDuplicateLowResolutionModes", 0x08000100);
}

static void screen_px(double *wpx, double *hpx, double *wpt, double *hpt, double *fps) {
    double w, h, s, f; MacShimScreenInfo(&w, &h, &s, &f);
    if (wpx) *wpx = w * s; if (hpx) *hpx = h * s; if (wpt) *wpt = w; if (hpt) *hpt = h; if (fps) *fps = f;
}
EXPORT CGDirectDisplayID CGMainDisplayID(void) { return 1; }
EXPORT int32_t CGGetActiveDisplayList(uint32_t max, CGDirectDisplayID *list, uint32_t *count) { if (list && max) list[0] = 1; if (count) *count = 1; return 0; }
extern double MacShimAppKitScale(void);     /* AppKit points per UIKit point (the game sees a 2x display) */
EXPORT MSRect CGDisplayBounds(CGDirectDisplayID d) { double w, h, k = MacShimAppKitScale(); (void)d; screen_px(0, 0, &w, &h, 0); MSRect r = {0, 0, w * k, h * k}; return r; }
static size_t mode_dim(void *m, int height);
EXPORT size_t CGDisplayPixelsWide(CGDirectDisplayID d) { (void)d; return mode_dim(0, 0); }     /* = the chosen output */
EXPORT size_t CGDisplayPixelsHigh(CGDirectDisplayID d) { (void)d; return mode_dim(0, 1); }
EXPORT uint32_t CGDisplayIsBuiltin(CGDirectDisplayID d)     { (void)d; return 1; }
EXPORT uint32_t CGDisplayIsInMirrorSet(CGDirectDisplayID d) { (void)d; return 0; }
EXPORT uint32_t CGDisplayVendorNumber(CGDirectDisplayID d)  { (void)d; return 0x0610; }  /* Apple */
EXPORT uint32_t CGDisplayModelNumber(CGDirectDisplayID d)   { (void)d; return 0; }
EXPORT uint32_t CGDisplaySerialNumber(CGDirectDisplayID d)  { (void)d; return 0; }
EXPORT mach_port_t CGDisplayIOServicePort(CGDirectDisplayID d) { (void)d; return 0; }

/* Display modes = render resolutions offered to the game: the screen size times MacShimModeScale(i) (1x, 1.5x, 2x, native).
 * The game used to see only the screen size in points (956x440 on a 16 Pro Max). The current mode is the one picked on
 * the start screen. Mode objects are slots of a static array; arrays use NULL callbacks so CF never retains them. */
extern int MacShimModeCount(void); extern double MacShimModeScale(int i); extern int MacShimCurrentMode(void);
static int g_mode_tokens[16];
static int mode_idx(void *m) { long i = (int *)m - g_mode_tokens; return i >= 0 && i < MacShimModeCount() ? (int)i : MacShimCurrentMode(); }
static size_t mode_dim(void *m, int height) {
    double w, h; screen_px(0, 0, &w, &h, 0); double v = (height ? h : w) * MacShimModeScale(mode_idx(m));
    return (size_t)(v + 0.5);                                   /* rounded like the game (1194.9 -> 1195) */
}
EXPORT void *CGDisplayCopyDisplayMode(CGDirectDisplayID d)        { (void)d; return &g_mode_tokens[MacShimCurrentMode()]; }
EXPORT void *CGDisplayCopyAllDisplayModes(CGDirectDisplayID d, const void *opts) {
    /* Only the mode picked on the start screen. With several modes the engine started in 1912x880 (the largest
       within 1920x1080) whatever was chosen; with exactly one it uses that one (measured). */
    const void *v[1]; int n = 1; (void)d; (void)opts;
    v[0] = &g_mode_tokens[MacShimCurrentMode()];
    { static int logged; if (logged++ < 3) { char b[64]; size_t w = mode_dim(&g_mode_tokens[MacShimCurrentMode()], 0), h = mode_dim(&g_mode_tokens[MacShimCurrentMode()], 1);
        int k = 0; size_t vals[2] = { w, h }; for (int q = 0; q < 2; q++) { char t[24]; int m = 0; size_t x = vals[q]; do { t[m++] = '0' + x % 10; x /= 10; } while (x); while (m) b[k++] = t[--m]; if (!q) b[k++] = 'x'; } b[k] = 0;
        MacShimLogC("game read the display modes; current", b); } }
    return CFArrayCreate(0, v, n, 0);
}
EXPORT void CGDisplayModeRelease(void *m)                         { (void)m; }
EXPORT size_t CGDisplayModeGetWidth(void *m)                      { return mode_dim(m, 0); }
EXPORT size_t CGDisplayModeGetHeight(void *m)                     { return mode_dim(m, 1); }
EXPORT size_t CGDisplayModeGetPixelWidth(void *m)                 { return mode_dim(m, 0); }
EXPORT size_t CGDisplayModeGetPixelHeight(void *m)                { return mode_dim(m, 1); }
EXPORT double CGDisplayModeGetRefreshRate(void *m)                { double f; (void)m; screen_px(0, 0, 0, 0, &f); return f; }
/* the game takes the mode flagged native (kDisplayModeNativeFlag) as the panel resolution, else assumes 1920x1080 */
EXPORT uint32_t CGDisplayModeGetIOFlags(void *m)                  { return mode_idx(m) == MacShimCurrentMode() ? 0x02000003 : 0x00000003; }
EXPORT uint32_t CGDisplayModeIsUsableForDesktopGUI(void *m)       { (void)m; return 1; }

/* mouse cursor control -> UIKit pointer lock (see MacShim.m) */
EXPORT int32_t CGAssociateMouseAndMouseCursorPosition(uint32_t connected) { MacShimSetPointerLocked(!connected); return 0; }
typedef struct { double x, y; } MSPoint;
EXPORT int32_t CGWarpMouseCursorPosition(MSPoint p) { (void)p; return 0; }           /* iPadOS cannot warp the pointer */
EXPORT void *CGEventSourceCreate(int32_t stateID) {                                 /* any real CF object, so CFRelease() is safe */
    static void *s; (void)stateID; if (!s) s = CFStringCreateWithCString(0, "MacShimEventSource", 0x08000100);
    return CFRetain(s);
}
EXPORT void CGEventSourceSetLocalEventsSuppressionInterval(void *src, double sec) { (void)src; (void)sec; }

/* ============================== Security (macOS-only calls) ============================== */
extern void *SecCertificateCopySubjectSummary(const void *cert);   /* exists on iOS */
#define errSecUnimplemented ((int32_t)-4)
EXPORT int32_t SecItemImport(const void *d, const void *name, void *fmt, void *type, uint32_t flags, const void *kp, void *kc, void **items) { (void)d; (void)name; (void)fmt; (void)type; (void)flags; (void)kp; (void)kc; if (items) *items = 0; return errSecUnimplemented; }
EXPORT int32_t SecItemExport(const void *item, uint32_t fmt, uint32_t flags, const void *kp, void **out) { (void)item; (void)fmt; (void)flags; (void)kp; if (out) *out = 0; return errSecUnimplemented; }
EXPORT int32_t SecIdentityCreateWithCertificate(const void *keychains, const void *cert, void **identity) { (void)keychains; (void)cert; if (identity) *identity = 0; return errSecUnimplemented; }
EXPORT int32_t SecCertificateCopyCommonName(const void *cert, void **cn) { if (cn) *cn = SecCertificateCopySubjectSummary(cert); return 0; }
EXPORT void *SecCertificateCopyLongDescription(const void *alloc, const void *cert, void **err) { (void)alloc; if (err) *err = 0; return SecCertificateCopySubjectSummary(cert); }

/* ============================== libcurl: offline stub ============================== */
/* iOS has no libcurl. Online features (telemetry, Galaxy, update checks) simply fail with
 * CURLE_COULDNT_CONNECT; the offline game does not need them. */
#define CURLE_OK 0
#define CURLE_COULDNT_CONNECT 7
#define CURLE_UNKNOWN_OPTION 48
struct curl_slist { char *data; struct curl_slist *next; };
typedef struct { int msg; void *easy_handle; union { void *whatever; int result; } data; } MSCurlMsg;

EXPORT int curl_global_init_mem(long flags, void *m, void *f, void *r, void *s, void *c) { (void)flags; (void)m; (void)f; (void)r; (void)s; (void)c; return CURLE_OK; }
EXPORT void curl_global_cleanup(void) {}
/* Easy handles keep what the engine reads back: CURLOPT_PRIVATE (its request object, fetched with CURLINFO_PRIVATE
 * when a transfer finishes) and the URL. curl_easy_getinfo must succeed like real libcurl does for a failed transfer:
 * the engine treats a getinfo error as "no request object", so the request was never completed and stayed pending. */
typedef struct { void *priv; char url[200]; } MSCurlEasy;
#define CURLOPT_URL 10002
#define CURLOPT_PRIVATE 10103
#define CURLINFO_EFFECTIVE_URL 0x100001
#define CURLINFO_PRIVATE 0x100015
EXPORT void *curl_easy_init(void)               { return calloc(1, sizeof(MSCurlEasy)); }
EXPORT void curl_easy_cleanup(void *h)          { free(h); }
EXPORT int curl_easy_setopt(void *h, int opt, ...) {
    MSCurlEasy *e = (MSCurlEasy *)h; va_list ap; va_start(ap, opt);
    if (e && opt == CURLOPT_PRIVATE) e->priv = va_arg(ap, void *);
    else if (e && opt == CURLOPT_URL) {
        const char *u = va_arg(ap, const char *); size_t i = 0;
        if (u) for (; u[i] && i < sizeof e->url - 1; i++) e->url[i] = u[i];
        e->url[i] = 0;
    }
    va_end(ap); return CURLE_OK;
}
EXPORT int curl_easy_getinfo(void *h, int info, ...) {
    MSCurlEasy *e = (MSCurlEasy *)h; va_list ap; va_start(ap, info); void *out = va_arg(ap, void *); va_end(ap);
    if (!out) return CURLE_OK;
    switch (info & 0xf00000) {
        case 0x100000: *(const char **)out = info == CURLINFO_PRIVATE ? (const char *)(e ? e->priv : 0) : info == CURLINFO_EFFECTIVE_URL && e ? e->url : 0; break;
        case 0x200000: *(long *)out = 0; break;                     /* response code 0: no response */
        case 0x300000: *(double *)out = 0; break;
        case 0x400000: *(void **)out = 0; break;                    /* slist / ptr */
        case 0x500000: *(int *)out = -1; break;                     /* socket */
        case 0x600000: *(int64_t *)out = 0; break;                  /* curl_off_t */
        default: return CURLE_UNKNOWN_OPTION;
    }
    return CURLE_OK;
}
static void MSCurlLog(void *h, const char *what) {
    static int n; MSCurlEasy *e = (MSCurlEasy *)h; if (n++ >= 40) return;
    MacShimLogC(what, e && e->url[0] ? e->url : "?");
}
EXPORT int curl_easy_perform(void *h)           { MSCurlLog(h, "curl perform (offline)"); return CURLE_COULDNT_CONNECT; }
EXPORT const char *curl_easy_strerror(int code) { (void)code; return "offline (curl unavailable on iOS)"; }
EXPORT struct curl_slist *curl_slist_append(struct curl_slist *l, const char *s) {
    struct curl_slist *n = (struct curl_slist *)malloc(sizeof *n); if (!n) return l;
    n->data = strdup(s ? s : ""); n->next = 0;
    if (!l) return n; struct curl_slist *t = l; while (t->next) t = t->next; t->next = n; return l;
}
EXPORT void curl_slist_free_all(struct curl_slist *l) { while (l) { struct curl_slist *n = l->next; free(l->data); free(l); l = n; } }

#define MS_MAXQ 128
typedef struct { void *queue[MS_MAXQ]; int head, tail; } MSMulti;
EXPORT void *curl_multi_init(void)              { return calloc(1, sizeof(MSMulti)); }
EXPORT int curl_multi_cleanup(void *m)          { free(m); return 0; }
EXPORT int curl_multi_add_handle(void *m, void *easy) { MSCurlLog(easy, "curl request (offline)"); MSMulti *q = (MSMulti *)m; if (q && q->tail - q->head < MS_MAXQ) { q->queue[q->tail % MS_MAXQ] = easy; q->tail++; } return 0; }
EXPORT int curl_multi_remove_handle(void *m, void *easy) { MSMulti *q = (MSMulti *)m; if (q) for (int i = q->head; i < q->tail; i++) if (q->queue[i % MS_MAXQ] == easy) q->queue[i % MS_MAXQ] = 0; return 0; }
EXPORT int curl_multi_perform(void *m, int *running) { (void)m; if (running) *running = 0; return 0; }
EXPORT MSCurlMsg *curl_multi_info_read(void *m, int *left) {      /* report every added handle as "done: couldn't connect" */
    static MSCurlMsg msg; MSMulti *q = (MSMulti *)m;
    while (q && q->head < q->tail) {
        void *e = q->queue[q->head % MS_MAXQ]; q->head++;
        if (e) { msg.msg = 1 /* CURLMSG_DONE */; msg.easy_handle = e; msg.data.result = CURLE_COULDNT_CONNECT; if (left) *left = q->tail - q->head; return &msg; }
    }
    if (left) *left = 0; return 0;
}
