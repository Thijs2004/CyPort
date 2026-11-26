#import <Metal/Metal.h>
#include <stdlib.h>
BOOL MSPassMergeInstall(id<MTLDevice>, BOOL); NSString *MSPassMergeStats(void);
void MacShimLogC(const char *w, const char *d) { fprintf(stderr, "[%s] %s\n", w, d); }
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V{float4 p [[position]];};\n"
 "vertex V vs(uint i [[vertex_id]], constant float &z [[buffer(0)]]){V o; float2 u=float2((i<<1)&2,i&2); o.p=float4(u*2-1,z,1); return o;}\n"
 "struct F{half4 a [[color(0)]]; half4 b [[color(1)]];};\n"
 "fragment F fs(constant float &k [[buffer(0)]]){F f; f.a=half4(k,0.01h,0,1); f.b=half4(0.02h,k*0.5h,0,1); return f;}\n";
id<MTLDevice> d; id<MTLCommandQueue> q; id<MTLRenderPipelineState> ps; id dsNoWrite, dsWrite, dsStencil; id<MTLTexture> A,B,Z; int W=96,H=64;
static MTLRenderPassDescriptor *RP(MTLLoadAction la, MTLStoreAction sa, MTLLoadAction lz, MTLStoreAction sz) {
  MTLRenderPassDescriptor*rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=A; rp.colorAttachments[1].texture=B; rp.depthAttachment.texture=Z; rp.stencilAttachment.texture=Z;
  for(int i=0;i<2;i++){rp.colorAttachments[i].loadAction=la; rp.colorAttachments[i].storeAction=sa; rp.colorAttachments[i].clearColor=MTLClearColorMake(0.1,0.2,0.3,1);}
  rp.depthAttachment.loadAction=lz; rp.depthAttachment.storeAction=sz; rp.depthAttachment.clearDepth=1;
  rp.stencilAttachment.loadAction=lz; rp.stencilAttachment.storeAction=sz; return rp; }
static void draw(id<MTLRenderCommandEncoder> e, float z, float k){ [e setRenderPipelineState:ps]; [e setVertexBytes:&z length:4 atIndex:0]; [e setFragmentBytes:&k length:4 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
static uint64_t sum(id<MTLCommandBuffer> cb0){ [cb0 commit]; [cb0 waitUntilCompleted];
  uint64_t h=1469598103934665603ull; for(id<MTLTexture> t in @[A,B]){ id<MTLBuffer> bf=[d newBufferWithLength:W*H*8 options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder]; [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:(MTLOrigin){0,0,0} sourceSize:(MTLSize){W,H,1} toBuffer:bf destinationOffset:0 destinationBytesPerRow:W*8 destinationBytesPerImage:W*H*8]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
  const uint8_t*p=bf.contents; for(int i=0;i<W*H*8;i++){h^=p[i]; h*=1099511628211ull;} } return h; }
static void clearAll(void){ id<MTLCommandBuffer> cb=[q commandBuffer]; id e=[cb renderCommandEncoderWithDescriptor:RP(MTLLoadActionClear,MTLStoreActionStore,MTLLoadActionClear,MTLStoreActionStore)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
int main(int argc,char**argv){ @autoreleasepool {
 int on=atoi(getenv("PM")?:"0"); d=MTLCreateSystemDefaultDevice(); q=[d newCommandQueue]; if(on) MSPassMergeInstall(d,YES);
 NSError*e; id<MTLLibrary> lib=[d newLibraryWithSource:src options:nil error:&e];
 MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"vs"]; pd.fragmentFunction=[lib newFunctionWithName:@"fs"];
 for(int i=0;i<2;i++){pd.colorAttachments[i].pixelFormat=MTLPixelFormatRGBA16Float; pd.colorAttachments[i].blendingEnabled=YES; pd.colorAttachments[i].destinationRGBBlendFactor=MTLBlendFactorOne; pd.colorAttachments[i].destinationAlphaBlendFactor=MTLBlendFactorOne;}
 pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8; pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8; ps=[d newRenderPipelineStateWithDescriptor:pd error:&e];
 MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new]; dd.depthCompareFunction=MTLCompareFunctionLess; dd.depthWriteEnabled=NO; dsNoWrite=[d newDepthStencilStateWithDescriptor:dd];
 dd.depthWriteEnabled=YES; dsWrite=[d newDepthStencilStateWithDescriptor:dd];
 MTLDepthStencilDescriptor *sd=[MTLDepthStencilDescriptor new]; MTLStencilDescriptor*st=[MTLStencilDescriptor new]; st.stencilCompareFunction=MTLCompareFunctionEqual; st.readMask=0xff; sd.frontFaceStencil=st; sd.backFaceStencil=st; dsStencil=[d newDepthStencilStateWithDescriptor:sd];
 MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:W height:H mipmapped:NO]; td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead; td.storageMode=MTLStorageModePrivate;
 A=[d newTextureWithDescriptor:td]; B=[d newTextureWithDescriptor:td]; td.pixelFormat=MTLPixelFormatDepth32Float_Stencil8; Z=[d newTextureWithDescriptor:td];
 id<MTLFence> fence=[d newFence];
 for(int sc=1; sc<=8; sc++){ clearAll(); id<MTLCommandBuffer> cb=[q commandBuffer];
  #define PASS(la,sa,lz,sz) ({ id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:RP(la,sa,lz,sz)]; en; })
  if(sc==1){ for(int p=0;p<60;p++){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionDontCare); [en setDepthStencilState:dsNoWrite]; [en setScissorRect:(MTLScissorRect){(NSUInteger)(p*5%80),(NSUInteger)(p*3%50),16,12}]; draw(en,0.5,0.05); [en endEncoding]; } }
  if(sc==2){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); [en setViewport:(MTLViewport){0,0,10,10,0,1}]; [en setScissorRect:(MTLScissorRect){0,0,10,10}]; [en setCullMode:MTLCullModeFront]; draw(en,0.5,0.3); [en endEncoding];
             en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); draw(en,0.5,0.2); [en endEncoding]; }
  if(sc==3){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionDontCare); [en setDepthStencilState:dsWrite]; draw(en,0.2,0.3); [en endEncoding];
             en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionDontCare); [en setDepthStencilState:dsNoWrite]; draw(en,0.5,0.4); [en endEncoding]; }
  if(sc==4){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); draw(en,0.5,0.3); [en endEncoding];
             en=PASS(MTLLoadActionClear,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); draw(en,0.5,0.1); [en endEncoding]; }
  if(sc==5){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); draw(en,0.5,0.3); [en endEncoding];
             id bl=[cb blitCommandEncoder]; [bl copyFromTexture:A toTexture:B]; [bl endEncoding];
             en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); draw(en,0.5,0.1); [en endEncoding]; }
  if(sc==6){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); draw(en,0.5,0.3); [en updateFence:fence afterStages:MTLRenderStageFragment]; [en endEncoding];
             en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); [en waitForFence:fence beforeStages:MTLRenderStageVertex]; draw(en,0.5,0.1); [en endEncoding]; }
  if(sc==7){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); [en setStencilReferenceValue:7]; [en setDepthStencilState:dsStencil]; draw(en,0.5,0.3); [en endEncoding];
             en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); [en setDepthStencilState:dsStencil]; draw(en,0.5,0.25); [en endEncoding]; }
  if(sc==8){ id en=PASS(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionStore); draw(en,0.5,0.3); [en endEncoding];  /* held pass, then commit right away */ }
  printf("scene %d: %016llx\n", sc, sum(cb)); }
 NSString *st0 = MSPassMergeStats(); if (st0) fprintf(stderr, "%s\n", st0.UTF8String);
 // speed: 60-pass scene
 double t=0; for(int r=0;r<45;r++){ id<MTLCommandBuffer> cb=[q commandBuffer]; for(int p=0;p<60;p++){ id en=[cb renderCommandEncoderWithDescriptor:RP(MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionDontCare)]; [en setDepthStencilState:dsNoWrite]; draw(en,0.5,0.001); [en endEncoding]; } [cb commit]; [cb waitUntilCompleted]; if(r>=5) t+=cb.GPUEndTime-cb.GPUStartTime; }
 printf("60-pass frame: %.3f ms GPU\n", t/40*1000);
 // stress: 6 threads encode their own command buffers (passes + blits + fences), commits happen on another queue
 dispatch_queue_t cq = dispatch_queue_create("commit", DISPATCH_QUEUE_SERIAL); dispatch_group_t g = dispatch_group_create();
 for (int th=0; th<6; th++) dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
   MTLTextureDescriptor*t2=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:W height:H mipmapped:NO]; t2.usage=MTLTextureUsageRenderTarget; t2.storageMode=MTLStorageModePrivate;
   for (int f=0; f<150; f++) @autoreleasepool { id<MTLCommandBuffer> cb=[q commandBuffer];
     for (int p=0;p<20;p++){ id en=[cb renderCommandEncoderWithDescriptor:RP(p%7==0?MTLLoadActionClear:MTLLoadActionLoad,MTLStoreActionStore,MTLLoadActionLoad,MTLStoreActionDontCare)]; [en setDepthStencilState:p%5?dsNoWrite:dsWrite]; draw(en,0.5,0.001); [en endEncoding];
       if (p%9==8) { id bl=[cb blitCommandEncoder]; [bl endEncoding]; } }
     dispatch_sync(cq, ^{ [cb commit]; }); if (f%50==49) [cb waitUntilCompleted]; } });
 dispatch_group_wait(g, DISPATCH_TIME_FOREVER); id<MTLCommandBuffer> last=[q commandBuffer]; [last commit]; [last waitUntilCompleted];
 NSString *st1 = MSPassMergeStats(); fprintf(stderr, "stress done: %s\n", st1.UTF8String ?: "-");
}}
