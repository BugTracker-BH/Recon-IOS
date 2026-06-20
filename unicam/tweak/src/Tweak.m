// Tweak.m — UniCam: runtime camera-frame injection for authorized liveness testing.
//
// Hooks AVCaptureVideoDataOutput's sample-buffer delegate AT RUNTIME (no Logos,
// no hard-coded SDK class) and replaces live sensor frames with frames decoded
// from a user-supplied video, re-rendered to match the original buffer's pixel
// format, dimensions, and timing — so downstream code (and the backend) sees a
// well-formed capture stream.
//
// AUTHORIZED USE ONLY: Unico IDTech HackerOne liveness bug-bounty, in-scope test
// apps, on a device you own. Not for use against third-party apps/users.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- Config ---------------------------------------------------------------
// Place your spoof video here (must be readable by the target app's sandbox;
// on most rootless jailbreaks injected code can read /var/mobile/Documents).
static NSString *const kVideoPath = @"/var/mobile/Documents/vcam.mp4";
static NSString *const kTag       = @"[UniCam]";

#pragma mark - Frame source (decodes the spoof video, loops)

@interface VCamSource : NSObject
+ (instancetype)shared;
- (CIImage *)currentImage;     // latest decoded frame, or nil if not ready
@end

@implementation VCamSource {
    AVAssetReaderTrackOutput *_output;
    AVAssetReader *_reader;
    NSURL *_url;
    dispatch_queue_t _q;
    CIImage *_latest;
    BOOL _ok;
}

+ (instancetype)shared {
    static VCamSource *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VCamSource new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("com.local.unicam.src", DISPATCH_QUEUE_SERIAL);
        _url = [NSURL fileURLWithPath:kVideoPath];
        [self setupReader];
        [self pump];
    }
    return self;
}

- (void)setupReader {
    _ok = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:kVideoPath]) {
        NSLog(@"%@ spoof video missing at %@", kTag, kVideoPath);
        return;
    }
    AVAsset *asset = [AVURLAsset URLAssetWithURL:_url options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) { NSLog(@"%@ no video track", kTag); return; }

    NSError *err = nil;
    _reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!_reader) { NSLog(@"%@ reader err: %@", kTag, err); return; }
    NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    _output.alwaysCopiesSampleData = NO;
    if ([_reader canAddOutput:_output]) [_reader addOutput:_output];
    _ok = [_reader startReading];
}

- (void)pump {
    dispatch_async(_q, ^{
        while (1) {
            if (!self->_ok) { [NSThread sleepForTimeInterval:0.5]; [self setupReader]; continue; }
            CMSampleBufferRef sb = [self->_output copyNextSampleBuffer];
            if (!sb) { [self setupReader]; continue; }          // EOF -> loop
            CVImageBufferRef pix = CMSampleBufferGetImageBuffer(sb);
            if (pix) {
                CIImage *img = [CIImage imageWithCVPixelBuffer:pix];
                @synchronized (self) { self->_latest = img; }
            }
            CFRelease(sb);
            [NSThread sleepForTimeInterval:1.0 / 30.0];          // ~30 fps pacing
        }
    });
}

- (CIImage *)currentImage { @synchronized (self) { return _latest; } }
@end

#pragma mark - Replacement buffer construction

static CIContext *gCtx;

static CVPixelBufferRef MakeMatchingBuffer(CIImage *src, size_t w, size_t h, OSType fmt) {
    NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(fmt),
                             (id)kCVPixelBufferWidthKey  : @(w),
                             (id)kCVPixelBufferHeightKey : @(h),
                             (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
    CVPixelBufferRef out = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
            (__bridge CFDictionaryRef)attrs, &out) != kCVReturnSuccess) return NULL;

    CGRect ext = src.extent;
    if (ext.size.width < 1 || ext.size.height < 1) { CVPixelBufferRelease(out); return NULL; }
    CGFloat sx = (CGFloat)w / ext.size.width;
    CGFloat sy = (CGFloat)h / ext.size.height;
    CIImage *scaled = [src imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];

    if (!gCtx) gCtx = [CIContext contextWithOptions:nil];
    [gCtx render:scaled toCVPixelBuffer:out];
    return out;
}

static CMSampleBufferRef BuildReplacement(CMSampleBufferRef orig) {
    CIImage *src = [[VCamSource shared] currentImage];
    if (!src) return NULL;                                   // not ready -> pass-through
    CVImageBufferRef ob = CMSampleBufferGetImageBuffer(orig);
    if (!ob) return NULL;

    size_t w = CVPixelBufferGetWidth(ob);
    size_t h = CVPixelBufferGetHeight(ob);
    OSType fmt = CVPixelBufferGetPixelFormatType(ob);
    CVPixelBufferRef np = MakeMatchingBuffer(src, w, h, fmt);
    if (!np) return NULL;

    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(orig, 0, &timing) != noErr) {
        timing.duration = kCMTimeInvalid;
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(orig);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMVideoFormatDescriptionRef desc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, np, &desc);

    CMSampleBufferRef out = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, np, desc, &timing, &out);
    if (desc) CFRelease(desc);
    CVPixelBufferRelease(np);
    return out;                                              // caller releases
}

#pragma mark - Swizzles

static NSObject *gLock;
static NSMutableSet<NSString *> *gHooked;

// Replacement for the SDK's frame callback. After install, the ORIGINAL impl is
// reachable under the unicam_ selector.
static void vcam_didOutput(id self, SEL _cmd, AVCaptureOutput *output,
                           CMSampleBufferRef sampleBuffer, AVCaptureConnection *conn) {
    CMSampleBufferRef rep = BuildReplacement(sampleBuffer);
    CMSampleBufferRef use = rep ? rep : sampleBuffer;
    ((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(
        self, @selector(unicam_captureOutput:didOutputSampleBuffer:fromConnection:),
        output, use, conn);
    if (rep) CFRelease(rep);
}

static void InstallDelegateHook(Class cls) {
    if (!cls) return;
    @synchronized (gLock) {
        NSString *name = NSStringFromClass(cls);
        if ([gHooked containsObject:name]) return;

        SEL origSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        Method m = class_getInstanceMethod(cls, origSel);
        if (!m) { NSLog(@"%@ delegate %@ has no didOutputSampleBuffer:", kTag, name); return; }

        SEL newSel = @selector(unicam_captureOutput:didOutputSampleBuffer:fromConnection:);
        class_addMethod(cls, newSel, (IMP)vcam_didOutput, method_getTypeEncoding(m));
        Method n = class_getInstanceMethod(cls, newSel);
        method_exchangeImplementations(m, n);     // origSel -> ours, newSel -> original

        [gHooked addObject:name];
        NSLog(@"%@ injected into frame delegate: %@", kTag, name);
    }
}

// Hook the delegate setter so we learn the delegate's class at runtime.
static void (*orig_setDelegate)(id, SEL, id, dispatch_queue_t);
static void new_setDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if (delegate) InstallDelegateHook(object_getClass(delegate));
    orig_setDelegate(self, _cmd, delegate, queue);
}

__attribute__((constructor))
static void UniCamInit(void) {
    gLock = [NSObject new];
    gHooked = [NSMutableSet set];

    [VCamSource shared];                          // begin decoding the spoof video

    Class avo = objc_getClass("AVCaptureVideoDataOutput");
    if (!avo) { NSLog(@"%@ AVCaptureVideoDataOutput unavailable", kTag); return; }
    Method m = class_getInstanceMethod(avo, @selector(setSampleBufferDelegate:queue:));
    if (!m) { NSLog(@"%@ setSampleBufferDelegate:queue: not found", kTag); return; }
    orig_setDelegate = (void (*)(id, SEL, id, dispatch_queue_t))method_getImplementation(m);
    method_setImplementation(m, (IMP)new_setDelegate);

    NSLog(@"%@ loaded; spoof video: %@", kTag, kVideoPath);
}
