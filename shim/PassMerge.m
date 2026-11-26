// Render pass merging for Apple's tile-based GPUs.
//
// In the open world the Mac build draws ~60 small render passes per frame back to back on the same images (decals,
// lights: "717x330:LS 717x330:LS 717x330:L" in the gpu breakdown line). Every pass loads its images from memory into
// the GPU's tile memory and stores them back. The driver doesn't join them: on an M4, 60 such passes took 5.1 ms of
// GPU time per frame, the same 60 draws in one pass 0.04 ms. On the phone that is ~400-575 MB of memory traffic per
// city frame.
//
// When the game ends a pass (endEncoding) whose images, store actions and contents allow it, the real endEncoding is
// held back. If the next thing the game does on that command buffer is to start a pass on exactly the same images that
// loads them (no clear), keeps what the first one stored, and nothing else happened in between, the game gets the
// still-open encoder back with its state reset to a new encoder's defaults - one pass on the GPU instead of two. Any
// other call on the command buffer (another kind of encoder, commit, present, events, debug groups, residency) first
// really ends the held pass. Not merged: fences updated in the first pass, a depth/stencil the first pass may have
// written but didn't store, MSAA, visibility results, rasterization rate maps, counters, memoryless/tile settings.
// A command buffer that comes back with a GPU error turns merging off for good on this device (CyPortPassMergeOff).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

extern void MacShimLogC(const char *what, const char *detail);
static void PMLog(NSString *s) { MacShimLogC("pass merge", s.UTF8String); }

static _Atomic BOOL g_pmOn;
static _Atomic long long g_pmPasses, g_pmMerged, g_pmHeld;   // for the stats line
// why passes were not joined (stats line): the previous pass was ended by another command buffer call (which), or
// was not held, or this pass differs from it (how)
enum { PMR_NOPREV, PMR_NOTCAND, PMR_SIZE, PMR_TEX, PMR_SUB, PMR_CLEAR, PMR_UNSTORED, PMR_STORE, PMR_FENCE, PMR_DS, PMR_N };
static const char *g_pmRName[PMR_N] = { "nothing held", "this pass can't take part", "other size", "other images", "other mip/slice",
                                         "clears", "would read unstored drawing", "stores more", "fence", "depth written, not stored" };
static _Atomic long long g_pmR[PMR_N];
#define PM_FLN 40
static _Atomic long long g_pmFlushBy[PM_FLN]; static const char *g_pmFlushName[PM_FLN];
static char g_pmKey;                                          // command buffer -> state; encoder -> state

enum { PM_ATT = 10 };   // 8 colour, depth, stencil
@interface MSPMState : NSObject { @public
    id open;                    // the game's current mergeable encoder on this command buffer
    id pending;                 // its endEncoding held back
    id tex[PM_ATT]; NSUInteger lvl[PM_ATT], slc[PM_ATT], dpl[PM_ATT]; MTLStoreAction st[PM_ATT];
    BOOL wroteDS, fence, merged;
    NSUInteger w, h; int chain;
    NSMutableString *seq; NSMutableDictionary *ids; int seqPasses;   // sequence sample (one command buffer a minute)
    BOOL used;                                                       // a pass was made since the last commit (the driver reuses command buffers)
}
@end
@implementation MSPMState @end

// depth/stencil states: which ones can write. Unknown ones (made before the hook) count as writing.
static NSMapTable *g_dsWrites; static os_unfair_lock g_dsLock = OS_UNFAIR_LOCK_INIT;
static IMP g_oNewDS;
static BOOL PMStencilWrites(MTLStencilDescriptor *s) {
    return s && s.writeMask && (s.stencilFailureOperation != MTLStencilOperationKeep || s.depthFailureOperation != MTLStencilOperationKeep ||
                                s.depthStencilPassOperation != MTLStencilOperationKeep);
}
typedef id (*PMNewDSFn)(id, SEL, id) NS_RETURNS_RETAINED;
static id pm_newDS(id self, SEL c, MTLDepthStencilDescriptor *d) NS_RETURNS_RETAINED;
static id pm_newDS(id self, SEL c, MTLDepthStencilDescriptor *d) {
    id s = ((PMNewDSFn)g_oNewDS)(self, c, d);
    if (s && d) {
        BOOL w = d.depthWriteEnabled || PMStencilWrites(d.frontFaceStencil) || PMStencilWrites(d.backFaceStencil);
        os_unfair_lock_lock(&g_dsLock); [g_dsWrites setObject:@(w) forKey:s]; os_unfair_lock_unlock(&g_dsLock);
    }
    return s;
}
static BOOL PMDSWrites(id s) {
    if (!s) return NO;
    os_unfair_lock_lock(&g_dsLock); NSNumber *n = [g_dsWrites objectForKey:s]; os_unfair_lock_unlock(&g_dsLock);
    return n ? n.boolValue : YES;
}
static id g_defaultDS;   // what a new encoder uses: compare always, no writes

static MTLRenderPassAttachmentDescriptor *PMAtt(MTLRenderPassDescriptor *d, int i) {
    return i < 8 ? (MTLRenderPassAttachmentDescriptor *)d.colorAttachments[i] : i == 8 ? (MTLRenderPassAttachmentDescriptor *)d.depthAttachment : (MTLRenderPassAttachmentDescriptor *)d.stencilAttachment;
}
static BOOL PMStoreKnown(MTLStoreAction a) { return a == MTLStoreActionStore || a == MTLStoreActionDontCare; }
// a pass that may take part at all (as the first or a later one)
static char g_pmWhy;   /* why the last PMCandidate said no (sequence sample): v visibility, r rate map, i imageblock/threadgroup/tile,
                          a array length, c counters, m MSAA/resolve, l memoryless, s store action not known yet, 0 no attachments */
static BOOL PMCandidate(MTLRenderPassDescriptor *d) {
#define PMC(ch) do { g_pmWhy = ch; return NO; } while (0)
    if (!d) PMC('0');
    if (d.visibilityResultBuffer) PMC('v');
    if (d.rasterizationRateMap) PMC('r');
    if (d.imageblockSampleLength || d.threadgroupMemoryLength || d.tileWidth || d.tileHeight) PMC('i');
    if (d.renderTargetArrayLength > 1) PMC('a');
    if (@available(iOS 14.0, macOS 11.0, *)) { if (d.sampleBufferAttachments[0].sampleBuffer) PMC('c'); }
    int n = 0;
    for (int i = 0; i < PM_ATT; i++) {
        MTLRenderPassAttachmentDescriptor *a = PMAtt(d, i); id<MTLTexture> t = a.texture; if (!t) continue;
        if (t.sampleCount > 1 || a.resolveTexture) PMC('m');
        if (t.storageMode == MTLStorageModeMemoryless) PMC('l');
        if (!PMStoreKnown(a.storeAction)) PMC('s');
        n++;
    }
    if (!n) PMC('0');
    return YES;
}
static void PMRecord(MSPMState *s, MTLRenderPassDescriptor *d, id enc) {
    s->open = enc; s->pending = nil; s->wroteDS = NO; s->fence = NO; s->chain = 0;
    s->w = d.renderTargetWidth; s->h = d.renderTargetHeight;
    for (int i = 0; i < PM_ATT; i++) {
        MTLRenderPassAttachmentDescriptor *a = PMAtt(d, i);
        s->tex[i] = a.texture; s->lvl[i] = a.level; s->slc[i] = a.slice; s->dpl[i] = a.depthPlane; s->st[i] = a.storeAction;
    }
}
#define PMNO(r) do { g_pmR[r]++; return NO; } while (0)
static BOOL PMCanMerge(MSPMState *s, MTLRenderPassDescriptor *d) {
    if (s->fence) PMNO(PMR_FENCE);
    if (s->chain >= 200 || !PMCandidate(d)) PMNO(PMR_NOTCAND);
    if (d.renderTargetWidth != s->w || d.renderTargetHeight != s->h) PMNO(PMR_SIZE);
    for (int i = 0; i < PM_ATT; i++) if (PMAtt(d, i).texture != s->tex[i]) PMNO(PMR_TEX);
    for (int i = 0; i < PM_ATT; i++) {
        MTLRenderPassAttachmentDescriptor *a = PMAtt(d, i); id<MTLTexture> t = a.texture;
        if (!t) continue;
        if (a.level != s->lvl[i] || a.slice != s->slc[i] || a.depthPlane != s->dpl[i]) PMNO(PMR_SUB);
        if (a.loadAction == MTLLoadActionClear) PMNO(PMR_CLEAR);                    // can't clear in the middle of a pass
        BOOL ds = i >= 8;
        if (a.loadAction == MTLLoadActionLoad && s->st[i] != MTLStoreActionStore && ds && s->wroteDS) PMNO(PMR_DS);
        if (a.loadAction == MTLLoadActionLoad && s->st[i] != MTLStoreActionStore && !ds) PMNO(PMR_UNSTORED);   // it would see unsaved drawing
        if (a.storeAction == MTLStoreActionStore && s->st[i] != MTLStoreActionStore) PMNO(PMR_STORE);           // the merged pass ends with the first one's stores
    }
    return YES;
}
static void PMResetEncoder(id<MTLRenderCommandEncoder> e, MSPMState *s) {
    NSUInteger w = 1, h = 1;   /* a new encoder's viewport / scissor: the whole render target */
    for (int i = 0; i < PM_ATT; i++) if (s->tex[i]) { id<MTLTexture> t = s->tex[i]; w = MAX(1, t.width >> s->lvl[i]); h = MAX(1, t.height >> s->lvl[i]); break; }
    if (s->w) w = s->w; if (s->h) h = s->h;
    [e setViewport:(MTLViewport){0, 0, (double)w, (double)h, 0, 1}];
    [e setScissorRect:(MTLScissorRect){0, 0, w, h}];
    [e setCullMode:MTLCullModeNone]; [e setFrontFacingWinding:MTLWindingClockwise];
    [e setDepthBias:0 slopeScale:0 clamp:0]; [e setTriangleFillMode:MTLTriangleFillModeFill];
    [e setDepthClipMode:MTLDepthClipModeClip]; [e setStencilReferenceValue:0];
    [e setBlendColorRed:0 green:0 blue:0 alpha:0]; [e setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    if (g_defaultDS) [e setDepthStencilState:g_defaultDS];
}

static IMP g_oRender, g_oEnd, g_oUpdFence, g_oSetDS;
static void PMFlush(MSPMState *s) {
    id p = s->pending; if (!p) return;
    s->pending = nil; s->open = nil;
    ((void (*)(id, SEL))g_oEnd)(p, @selector(endEncoding));
}
static MSPMState *PMStateOf(id cb) { return cb ? objc_getAssociatedObject(cb, &g_pmKey) : nil; }
static _Atomic double g_pmSeqNext = 20;   // seconds since start; one sample a minute
static NSString *PMTexId(MSPMState *s, id t) {
    if (!t) return @"-";
    NSValue *k = [NSValue valueWithPointer:(__bridge void *)t]; NSNumber *n = s->ids[k];
    if (!n) { n = @(s->ids.count + 1); s->ids[k] = n; }
    return [NSString stringWithFormat:@"t%@", n];
}
static const char *PMLA(MTLLoadAction a) { return a == MTLLoadActionLoad ? "L" : a == MTLLoadActionClear ? "C" : "-"; }
static const char *PMSA(MTLStoreAction a) { return a == MTLStoreActionStore ? "S" : a == MTLStoreActionDontCare ? "-" : "?"; }
static void PMSeqPass(MSPMState *s, MTLRenderPassDescriptor *d, BOOL joined) {
    if (!s || !s->seq || s->seq.length > 6000) return;
    s->seqPasses++;
    [s->seq appendString:joined ? @" +R(" : @" R("];
    for (int i = 0; i < PM_ATT; i++) { MTLRenderPassAttachmentDescriptor *a = PMAtt(d, i); if (!a.texture || (i == 9 && a.texture == d.depthAttachment.texture)) continue;
        [s->seq appendFormat:@"%s%@%s%s%s", i == 8 ? "|" : i == 9 ? "/s" : "", PMTexId(s, a.texture), PMLA(a.loadAction), PMSA(a.storeAction), i < 7 && PMAtt(d, i + 1).texture ? "," : ""]; }
    [s->seq appendString:@")"];
}
static void PMSeqCall(MSPMState *s, SEL c) {
    if (!s || !s->seq || s->seq.length > 6000) return;
    const char *n = sel_getName(c);
    [s->seq appendFormat:@" %s", !strncmp(n, "blit", 4) ? "blit" : !strncmp(n, "compute", 7) ? "compute" : !strncmp(n, "commit", 6) ? "commit" : n];
}
void MSPassMergeFlush(id cb) { MSPMState *s = PMStateOf(cb); if (s && s->pending) PMFlush(s); }

static id pm_render(id cb, SEL c, MTLRenderPassDescriptor *d) {
    if (!g_pmOn) return ((id (*)(id, SEL, id))g_oRender)(cb, c, d);
    g_pmPasses++;
    MSPMState *s = PMStateOf(cb);
    if (!s) { s = [MSPMState new]; objc_setAssociatedObject(cb, &g_pmKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    if (!s->used) { s->used = YES; double now = CACurrentMediaTime();
        if (!s->seq && now >= g_pmSeqNext) { g_pmSeqNext = now + 1e9; s->seq = [NSMutableString string]; s->ids = [NSMutableDictionary dictionary]; s->seqPasses = 0; } }
    if (!s->pending) g_pmR[PMR_NOPREV]++;
    if (s && s->pending) {
        if (PMCanMerge(s, d)) {
            id e = s->pending; s->pending = nil; s->chain++; s->merged = YES; g_pmMerged++;
            PMResetEncoder(e, s); PMSeqPass(s, d, YES);
            return e;
        }
        PMFlush(s);
    }
    id e = ((id (*)(id, SEL, id))g_oRender)(cb, c, d);
    if (e && PMCandidate(d)) {
        if (!s) { s = [MSPMState new]; objc_setAssociatedObject(cb, &g_pmKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        PMRecord(s, d, e);
        objc_setAssociatedObject(e, &g_pmKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   /* the driver may reuse encoder objects: always set */
    } else {
        if (e) objc_setAssociatedObject(e, &g_pmKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   /* never held (open is nil): only for the sequence's "e" */
        s->open = nil;
        if (s->seq && s->seq.length < 6000) [s->seq appendFormat:@" x%c", g_pmWhy];
    }
    if (e) PMSeqPass(s, d, NO);
    return e;
}
static void pm_end(id e, SEL c) {
    MSPMState *s = g_pmOn ? objc_getAssociatedObject(e, &g_pmKey) : nil;
    if (s && s->open == e && !s->pending) { s->pending = e; g_pmHeld++; if (s->seq && s->seq.length < 6000) [s->seq appendString:@"h"]; return; }
    if (s && s->seq && s->seq.length < 6000) [s->seq appendString:@"e"];
    ((void (*)(id, SEL))g_oEnd)(e, c);
}
static void pm_updFence(id e, SEL c, id f, NSUInteger stages) {
    MSPMState *s = objc_getAssociatedObject(e, &g_pmKey); if (s && s->open == e) { s->fence = YES; if (s->seq && s->seq.length < 3000) [s->seq appendString:@"F"]; }
    ((void (*)(id, SEL, id, NSUInteger))g_oUpdFence)(e, c, f, stages);
}
static void pm_setDS(id e, SEL c, id ds) {
    MSPMState *s = objc_getAssociatedObject(e, &g_pmKey); if (s && s->open == e && PMDSWrites(ds)) s->wroteDS = YES;
    ((void (*)(id, SEL, id))g_oSetDS)(e, c, ds);
}

// every other command buffer call first ends a held pass: one wrapper per method signature
#define PM_MAXW 48
static struct { SEL sel; IMP orig; } g_pmW[PM_MAXW]; static int g_pmWN;
static IMP PMOrig(SEL s) { for (int i = 0; i < g_pmWN; i++) if (g_pmW[i].sel == s) return g_pmW[i].orig; return NULL; }
static void PMFlushBy(MSPMState *s, SEL c) {
    const char *n = sel_getName(c); int i = 0;
    for (; i < PM_FLN && g_pmFlushName[i]; i++) if (g_pmFlushName[i] == n) break;
    if (i < PM_FLN) { if (!g_pmFlushName[i]) g_pmFlushName[i] = n; g_pmFlushBy[i]++; }
    PMFlush(s);
}
#define PMF(cb) do { MSPMState *s_ = PMStateOf(cb); PMSeqCall(s_, c); if (s_ && s_->pending) PMFlushBy(s_, c); } while (0)
static id   pmw_o(id cb, SEL c)                          { PMF(cb); return ((id (*)(id, SEL))PMOrig(c))(cb, c); }
static id   pmw_oo(id cb, SEL c, id a)                   { PMF(cb); return ((id (*)(id, SEL, id))PMOrig(c))(cb, c, a); }
static id   pmw_oq(id cb, SEL c, NSUInteger a)           { PMF(cb); return ((id (*)(id, SEL, NSUInteger))PMOrig(c))(cb, c, a); }
static void pmw_v(id cb, SEL c)                          { PMF(cb); ((void (*)(id, SEL))PMOrig(c))(cb, c); }
static void pmw_vo(id cb, SEL c, id a)                   { PMF(cb); ((void (*)(id, SEL, id))PMOrig(c))(cb, c, a); }
static void pmw_vq(id cb, SEL c, NSUInteger a)           { PMF(cb); ((void (*)(id, SEL, NSUInteger))PMOrig(c))(cb, c, a); }
static void pmw_vod(id cb, SEL c, id a, double t)        { PMF(cb); ((void (*)(id, SEL, id, double))PMOrig(c))(cb, c, a, t); }
static void pmw_voq(id cb, SEL c, id a, uint64_t v)      { PMF(cb); ((void (*)(id, SEL, id, uint64_t))PMOrig(c))(cb, c, a, v); }
static void pmw_voqq(id cb, SEL c, id a, uint64_t v, uint64_t m) { PMF(cb); ((void (*)(id, SEL, id, uint64_t, uint64_t))PMOrig(c))(cb, c, a, v, m); }
static void pmw_voqi(id cb, SEL c, id a, uint64_t v, uint32_t t) { PMF(cb); ((void (*)(id, SEL, id, uint64_t, uint32_t))PMOrig(c))(cb, c, a, v, t); }
static void pmw_vpq(id cb, SEL c, const void *a, NSUInteger n)   { PMF(cb); ((void (*)(id, SEL, const void *, NSUInteger))PMOrig(c))(cb, c, a, n); }
static void pmw_voo(id cb, SEL c, id a, id b)            { PMF(cb); ((void (*)(id, SEL, id, id))PMOrig(c))(cb, c, a, b); }
static BOOL pmw_b(id cb, SEL c)                          { PMF(cb); return ((BOOL (*)(id, SEL))PMOrig(c))(cb, c); }
static BOOL pmw_bq(id cb, SEL c, uint64_t a)             { PMF(cb); return ((BOOL (*)(id, SEL, uint64_t))PMOrig(c))(cb, c, a); }

// type encodings without offsets: "@@:" etc.
static void PMStrip(const char *t, char *o, size_t n) { size_t k = 0; for (; *t && k + 1 < n; t++) if (!(*t >= '0' && *t <= '9')) o[k++] = *t; o[k] = 0; }
static BOOL PMWrap(Class C, const char *name) {
    SEL sel = sel_registerName(name); Method m = class_getInstanceMethod(C, sel); if (!m) return YES;   // not on this OS: nothing to do
    char t[64]; PMStrip(method_getTypeEncoding(m), t, sizeof t);
    IMP w = NULL;
    if      (!strcmp(t, "@@:"))     w = (IMP)pmw_o;    else if (!strcmp(t, "@@:@"))   w = (IMP)pmw_oo;
    else if (!strcmp(t, "@@:Q"))    w = (IMP)pmw_oq;   else if (!strcmp(t, "v@:"))    w = (IMP)pmw_v;
    else if (!strcmp(t, "v@:@"))    w = (IMP)pmw_vo;   else if (!strcmp(t, "v@:Q"))   w = (IMP)pmw_vq;
    else if (!strcmp(t, "v@:@d"))   w = (IMP)pmw_vod;  else if (!strcmp(t, "v@:@Q"))  w = (IMP)pmw_voq;
    else if (!strcmp(t, "v@:@QQ"))  w = (IMP)pmw_voqq; else if (!strcmp(t, "v@:@QI")) w = (IMP)pmw_voqi;
    else if (!strcmp(t, "v@:r^@Q")) w = (IMP)pmw_vpq;  else if (!strcmp(t, "v@:@@"))  w = (IMP)pmw_voo;
    else if (!strcmp(t, "B@:"))     w = (IMP)pmw_b;    else if (!strcmp(t, "B@:Q"))   w = (IMP)pmw_bq;
    if (!w || g_pmWN >= PM_MAXW) { PMLog([NSString stringWithFormat:@"off: -[%s %s] has an unexpected type %s", class_getName(C), name, t]); return NO; }
    g_pmW[g_pmWN].sel = sel; g_pmW[g_pmWN].orig = method_setImplementation(m, w); g_pmWN++;
    return YES;
}

static void PMWatchErrors(id cb) {
    MSPMState *s = PMStateOf(cb); if (!s || !s->merged) return;
    [(id<MTLCommandBuffer>)cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
        if (b.status != MTLCommandBufferStatusError || !g_pmOn) return;
        g_pmOn = NO; [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"CyPortPassMergeOff"];
        PMLog([NSString stringWithFormat:@"turned off for good on this device: a merged command buffer failed (%@)", b.error.localizedDescription]);
    }];
}
static IMP g_oCommitPM;
static void pm_commit(id cb, SEL c) {
    PMF(cb); PMWatchErrors(cb);
    MSPMState *s = PMStateOf(cb);
    if (s) s->used = NO;
    if (s && s->seq) {
        static int logged; double now = CACurrentMediaTime();
        BOOL big = s->seqPasses >= 20;
        if (big) { logged++; g_pmSeqNext = logged >= 20 ? 1e18 : now + 20; } else g_pmSeqNext = now;   /* busy command buffers only: one every 20 s, at most 20 */
        if (big) PMLog([NSString stringWithFormat:@"sequence of one command buffer (%d passes; t<n> = image, L/C/- load, S/- store, |depth, +R joined, F fence, h held / e ended, x<why> = pass that can't take part: v visibility, r rate map, i imageblock/tile, a array, c counters, m MSAA, l memoryless, s store unknown):%@", s->seqPasses, s->seq]);
        s->seq = nil; s->ids = nil;
    }
    ((void (*)(id, SEL))g_oCommitPM)(cb, c);
}

NSString *MSPassMergeStats(void) {
    static long long p0, m0, r0[PMR_N], f0[PM_FLN]; long long p = g_pmPasses, m = g_pmMerged;
    if (!g_pmOn || p <= p0) return nil;
    NSMutableString *r = [NSMutableString stringWithFormat:@"pass merge: %lld of %lld render passes joined to the one before (%.0f%%) | not joined:", m - m0, p - p0, 100.0 * (m - m0) / (p - p0)];
    for (int i = 0; i < PMR_N; i++) { long long v = g_pmR[i]; if (v > r0[i]) [r appendFormat:@" %s %lld,", g_pmRName[i], v - r0[i]]; r0[i] = v; }
    [r appendString:@" | held pass ended by:"];
    for (int i = 0; i < PM_FLN && g_pmFlushName[i]; i++) { long long v = g_pmFlushBy[i]; if (v > f0[i]) [r appendFormat:@" %s %lld,", g_pmFlushName[i], v - f0[i]]; f0[i] = v; }
    p0 = p; m0 = m; return r;
}

// cb/enc: a command buffer and render encoder of the game's device (their classes get the hooks)
BOOL MSPassMergeInstall(id<MTLDevice> dev, BOOL wanted) {
    static BOOL done; if (done) return g_pmOn; done = YES;
    if (!wanted) { PMLog(@"off (PassMerge = NO)"); return NO; }
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"CyPortPassMergeOff"]) { PMLog(@"off: it failed on this device before (CyPortPassMergeOff)"); return NO; }
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp]; [enc endEncoding];
    if (!cb || !enc) { PMLog(@"off: no command buffer / encoder to look at"); return NO; }
    Class C = object_getClass(cb), E = object_getClass(enc), D = object_getClass(dev);
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; g_defaultDS = [dev newDepthStencilStateWithDescriptor:dd];
    g_dsWrites = [NSMapTable weakToStrongObjectsMapTable];
    if (g_defaultDS) [g_dsWrites setObject:@NO forKey:g_defaultDS];   /* made before the hook: known not to write */
    Method mr = class_getInstanceMethod(C, @selector(renderCommandEncoderWithDescriptor:)), me = class_getInstanceMethod(E, @selector(endEncoding));
    Method mf = class_getInstanceMethod(E, @selector(updateFence:afterStages:)), ms = class_getInstanceMethod(E, @selector(setDepthStencilState:));
    Method mc = class_getInstanceMethod(C, @selector(commit)), md = class_getInstanceMethod(D, @selector(newDepthStencilStateWithDescriptor:));
    if (!mr || !me || !mf || !ms || !mc || !md) { PMLog(@"off: a Metal method is missing"); return NO; }
    static const char *flush[] = {
        "blitCommandEncoder", "blitCommandEncoderWithDescriptor:", "computeCommandEncoder", "computeCommandEncoderWithDescriptor:",
        "computeCommandEncoderWithDispatchType:", "parallelRenderCommandEncoderWithDescriptor:", "resourceStateCommandEncoder",
        "resourceStateCommandEncoderWithDescriptor:", "accelerationStructureCommandEncoder", "accelerationStructureCommandEncoderWithDescriptor:",
        "enqueue", "commitAndReset", "commitAndHold", "commitWithDeadline:", "commitAndWaitUntilSubmitted", "commitAndWaitUntilSubmittedWithDeadline:",
        "presentDrawable:", "presentDrawable:atTime:", "presentDrawable:afterMinimumDuration:", "presentDrawable:options:",
        "encodeSignalEvent:value:", "encodeSignalEvent:value:agentMask:", "encodeSignalEventScheduled:value:", "encodeWaitForEvent:value:",
        "encodeWaitForEvent:value:timeout:", "encodeConditionalAbortEvent:", "pushDebugGroup:", "popDebugGroup",
        "useResidencySet:", "useResidencySets:count:", "waitUntilScheduled", "waitUntilCompleted" };
    // check every signature first, then hook: all or nothing
    for (size_t i = 0; i < sizeof flush / sizeof *flush; i++) {
        Method m = class_getInstanceMethod(C, sel_registerName(flush[i])); if (!m) continue;
        char t[64]; PMStrip(method_getTypeEncoding(m), t, sizeof t);
        static const char *ok[] = { "@@:", "@@:@", "@@:Q", "v@:", "v@:@", "v@:Q", "v@:@d", "v@:@Q", "v@:@QQ", "v@:@QI", "v@:r^@Q", "v@:@@", "B@:", "B@:Q" };
        BOOL k = NO; for (size_t j = 0; j < sizeof ok / sizeof *ok; j++) if (!strcmp(t, ok[j])) k = YES;
        if (!k) { PMLog([NSString stringWithFormat:@"off: -[%s %s] has an unexpected type %s", class_getName(C), flush[i], t]); return NO; }
    }
    for (size_t i = 0; i < sizeof flush / sizeof *flush; i++) if (!PMWrap(C, flush[i])) return NO;
    g_oNewDS = method_setImplementation(md, (IMP)pm_newDS);
    g_oRender = method_setImplementation(mr, (IMP)pm_render);
    g_oEnd = method_setImplementation(me, (IMP)pm_end);
    g_oUpdFence = method_setImplementation(mf, (IMP)pm_updFence);
    g_oSetDS = method_setImplementation(ms, (IMP)pm_setDS);
    g_oCommitPM = method_setImplementation(mc, (IMP)pm_commit);
    g_pmOn = YES; g_pmSeqNext = CACurrentMediaTime() + 120;   /* sequences from gameplay, not the menu */
    PMLog([NSString stringWithFormat:@"on (%s / %s, %d command buffer calls end a held pass)", class_getName(C), class_getName(E), g_pmWN]);
    return YES;
}
