// Compiles each given .metal file with Metal's runtime compiler
// (newLibraryWithSource:), exactly like the objects do at load time.
// Exit status = number of sources that failed to compile.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, char **argv)
{
  @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if(!dev) {
      fprintf(stderr, "msltest: no Metal device available\n");
      return 100;
    }
    int bad = 0;
    for(int i = 1; i < argc; i++) {
      NSString *path = [NSString stringWithUTF8String:argv[i]];
      NSString *src = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
      NSError *err = nil;
      id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
      printf("%s  %s\n", lib ? "OK  " : "FAIL", argv[i]);
      if(!lib) {
        bad++;
        printf("%s\n", [[err localizedDescription] UTF8String]);
      }
    }
    return bad;
  }
}
