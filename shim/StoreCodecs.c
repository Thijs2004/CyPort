/* Decoders for store downloads (shim/Stores.swift): Steam depot chunks are LZMA ("VZa") or zstd ("VSZa").
   zlib (GOG, Epic, Steam manifests) comes from the system libz. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "third_party/lzma/LzmaDec.h"
#include "third_party/zstd/zstddeclib.c"

static void *ms_lz_alloc(ISzAllocPtr p, size_t n) { (void)p; return malloc(n); }
static void ms_lz_free(ISzAllocPtr p, void *a) { (void)p; free(a); }

/* raw LZMA1 stream with its 5 property bytes; returns bytes written or -1 */
long ms_lzma_decode(const uint8_t *props5, const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen) {
    ISzAlloc al = { ms_lz_alloc, ms_lz_free };
    SizeT dl = dstLen, sl = srcLen; ELzmaStatus st;
    SRes r = LzmaDecode(dst, &dl, src, &sl, props5, LZMA_PROPS_SIZE, LZMA_FINISH_ANY, &st, &al);
    return r == SZ_OK ? (long)dl : -1;
}
/* one zstd frame; returns bytes written or -1 */
long ms_zstd_decode(const uint8_t *src, size_t srcLen, uint8_t *dst, size_t dstLen) {
    size_t r = ZSTD_decompress(dst, dstLen, src, srcLen);
    return ZSTD_isError(r) ? -1 : (long)r;
}
