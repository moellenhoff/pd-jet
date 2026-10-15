// Checks everything jet_shader does that can go wrong without Pd:
//  1. every effect file given on the command line parses, compiles and
//     builds a render pipeline - via the very same jet_shader_core.h code
//     the object uses;
//  2. a layout self-test: parameters of mixed types (float, float3, float4,
//     float2, color) are written with fillBuffer(), a tiny shader writes
//     some of them back out as a pixel, and we read that pixel from the
//     GPU - catches any disagreement between our offsets and Metal's.
// Exit status = number of failures.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../src/jet_shader_core.h"

static id<MTLRenderPipelineState> makePipeline(id<MTLDevice> dev, const jetsh::Spec &sp,
                                               const std::string &user, const char *name,
                                               std::string *why)
{
  std::string src = jetsh::buildSource(sp, user, name);
  NSError *err = nil;
  id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:src.c_str()]
                                         options:nil error:&err];
  if(!lib) { *why = [[err localizedDescription] UTF8String]; return nil; }
  MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
  d.vertexFunction = [lib newFunctionWithName:@"jet_vertex"];
  d.fragmentFunction = [lib newFunctionWithName:@"jet_fragment"];
  d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
  if(!ps) *why = [[err localizedDescription] UTF8String];
  return ps;
}

int main(int argc, char **argv)
{
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if(!dev) { fprintf(stderr, "effecttest: no Metal device\n"); return 100; }
    int bad = 0;

    for(int i = 1; i < argc; i++) {
      NSString *p = [NSString stringWithUTF8String:argv[i]];
      NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
      std::string user = s ? [s UTF8String] : "";
      jetsh::Spec sp = jetsh::parse(user);
      std::string why = sp.error;
      id<MTLRenderPipelineState> ps = nil;
      if(why.empty()) ps = makePipeline(dev, sp, user, [[p lastPathComponent] UTF8String], &why);
      printf("%s  %s", ps ? "OK  " : "FAIL", argv[i]);
      if(ps) printf("  (%zu params, %zu inputs)\n", sp.params.size(), sp.inputs.size());
      else { printf("\n%s\n", why.c_str()); bad++; }
    }

    // ---- layout self-test ----
    const char *testSrc =
      "// @param float a = 0.25\n"
      "// @param float3 b = 0.5 0.75 1.0\n"
      "// @param float4 c = 0.1 0.2 0.3 0.4\n"
      "// @param float2 d = 0.6 0.9\n"
      "// @param color e\n"
      "float4 effect(float2 uv, constant JetParams &p, JetTex t) {\n"
      "  // one pixel built from members that sit behind each alignment case\n"
      "  float x = (p.a + p.b.z + p.c.w + p.d.y + p.e.a + p.resolution.x + p.frame) * 0.0;\n"
      "  return float4(p.b.y + x, p.c.w + x, p.d.y + x, p.e.g * 0.5 + x);\n"
      "}\n";
    jetsh::Spec sp = jetsh::parse(testSrc);
    std::string why = sp.error;
    id<MTLRenderPipelineState> ps = why.empty() ? makePipeline(dev, sp, testSrc, "layout", &why) : nil;
    bool ok = false;
    if(ps) {
      std::vector<std::vector<float> > vals;
      for(auto &pm : sp.params) vals.push_back(pm.def);
      std::vector<unsigned char> buf;
      jetsh::fillBuffer(sp, vals, 0, 0, 1, 1, 0, 0, buf);

      MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:1 height:1 mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget;
      td.storageMode = MTLStorageModeShared;
      id<MTLTexture> out = [dev newTextureWithDescriptor:td];
      id<MTLCommandQueue> q = [dev newCommandQueue];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = out;
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
      [e setRenderPipelineState:ps];
      [e setFragmentBytes:buf.data() length:buf.size() atIndex:0];
      id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:[[MTLSamplerDescriptor alloc] init]];
      [e setFragmentSamplerState:ss atIndex:0];
      [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
      [e endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      unsigned char px[4] = {0};
      [out getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
      const float want[4] = { 0.75f, 0.4f, 0.9f, 0.5f };
      ok = true;
      for(int k = 0; k < 4; k++) if(fabsf(px[k] / 255.f - want[k]) > 0.01f) ok = false;
      printf("%s  layout self-test (got %d %d %d %d, want %d %d %d %d, struct %zu bytes)\n",
             ok ? "OK  " : "FAIL", px[0], px[1], px[2], px[3],
             (int)(want[0] * 255 + .5f), (int)(want[1] * 255 + .5f), (int)(want[2] * 255 + .5f),
             (int)(want[3] * 255 + .5f), sp.structSize);
    } else {
      printf("FAIL  layout self-test could not be built: %s\n", why.c_str());
    }
    if(!ok) bad++;
    return bad;
  }
}
