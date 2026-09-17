//
//  VcamLite.m — 融合版相机替换内核 v1.7.1
//
//  v1.7 修复：
//    A. 用 CMGetAttachment / CMSetAttachment 防止父类/子类双重替换
//    B. 格式白名单（BGRA / 420f / 420v / x420 / xf20）
//    C. IOSurface 可写检查
//    D. 首次见 (w,h,fmt) 日志
//  v1.7.1 修复：
//    - CMSampleBufferGetAttachment 不存在 → 改用 CMGetAttachment
//    - CFTypeRef 类型检查（避免误转 CFBoolean 崩溃）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <os/lock.h>
#import <mach/mach_time.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <pthread.h>
#import <math.h>
#import <notify.h>

// ══════════════════════════════════════════════════════════════════════
//  常量
// ══════════════════════════════════════════════════════════════════════
static NSString *const kVideoPath = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kPlistPath = @"/var/mobile/Media/DCIM/vc.plist";
static const char *const kNotifyAction = "com.vlite.action.changed";

static NSString *const kEnableKey     = @"enabled";
static NSString *const kActionToken   = @"actionToken";
static NSString *const kActionActive  = @"actionActive";

static NSString *const kBlinkS_us = @"actionBlinkStartUs";
static NSString *const kBlinkE_us = @"actionBlinkEndUs";
static NSString *const kMouthS_us = @"actionMouthStartUs";
static NSString *const kMouthE_us = @"actionMouthEndUs";
static NSString *const kHeadS_us  = @"actionHeadStartUs";
static NSString *const kHeadE_us  = @"actionHeadEndUs";
static NSString *const kBlinkS_s  = @"actionBlinkStart";
static NSString *const kBlinkE_s  = @"actionBlinkEnd";
static NSString *const kMouthS_s  = @"actionMouthStart";
static NSString *const kMouthE_s  = @"actionMouthEnd";
static NSString *const kHeadS_s   = @"actionHeadStart";
static NSString *const kHeadE_s   = @"actionHeadEnd";

static const int64_t kBlinkStartDefUs = 1000000LL;
static const int64_t kBlinkEndDefUs   = 2000000LL;
static const int64_t kMouthStartDefUs = 2500000LL;
static const int64_t kMouthEndDefUs   = 3500000LL;
static const int64_t kHeadStartDefUs  = 4000000LL;
static const int64_t kHeadEndDefUs    = 5500000LL;

// 防双重替换用的 attachment key
static CFStringRef const kVLProcessedKey = CFSTR("com.vlite.processed");

// ══════════════════════════════════════════════════════════════════════
//  日志
// ══════════════════════════════════════════════════════════════════════
static void vlog(NSString *tag, NSString *fmt, ...) {
    static NSMutableDictionary<NSString *, NSNumber *> *sLastByTag = nil;
    static NSLock *sLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLastByTag = [NSMutableDictionary new];
        sLock = [NSLock new];
    });
    [sLock lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *prev = sLastByTag[tag];
    if (prev && now - [prev doubleValue] < 1.0) {
        [sLock unlock];
        return;
    }
    sLastByTag[tag] = @(now);
    [sLock unlock];

    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[vlite][%@] %@", tag, m);
}

static void vlog_always(NSString *tag, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[vlite][%@] %@", tag, m);
}

// ══════════════════════════════════════════════════════════════════════
//  plist 缓存层
// ══════════════════════════════════════════════════════════════════════
static NSDictionary *vplist_cached(void) {
    static NSDictionary *cache = nil;
    static double lastMtime = -1;
    static NSLock *lk = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lk = [NSLock new]; });

    struct stat st;
    double m = 0;
    if (stat(kPlistPath.fileSystemRepresentation, &st) == 0) {
        m = (double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec / 1e9;
    }

    [lk lock];
    if (m != lastMtime || !cache) {
        lastMtime = m;
        cache = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
    }
    NSDictionary *r = cache;
    [lk unlock];
    return r;
}

static void vplist_update(void (^block)(NSMutableDictionary *)) {
    @synchronized(@"vlite.plist") {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:
            [NSDictionary dictionaryWithContentsOfFile:kPlistPath] ?: @{}];
        block(d);
        [d writeToFile:kPlistPath atomically:YES];
    }
    notify_post(kNotifyAction);
}

static BOOL vplist_enabled(void) {
    NSDictionary *d = vplist_cached();
    NSNumber *n = d[kEnableKey];
    return n ? [n boolValue] : NO;
}

static void vplist_set_enabled(BOOL en) {
    vplist_update(^(NSMutableDictionary *d) { d[kEnableKey] = @(en); });
}

static int64_t vplist_get_us(NSDictionary *pl, NSString *usKey,
                             NSString *secKey, int64_t defUs) {
    if (!pl) return defUs;
    NSNumber *n = pl[usKey];
    if (n) return [n longLongValue];
    n = pl[secKey];
    if (n) return (int64_t)llround([n doubleValue] * 1000000.0);
    return defUs;
}

// ══════════════════════════════════════════════════════════════════════
//  格式白名单 + 可写检查 + 首次见日志
// ══════════════════════════════════════════════════════════════════════
static BOOL vl_supportedFormat(OSType fmt) {
    switch (fmt) {
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return YES;
        default:
            if (fmt == 0x78343230) return YES; // 'x420'
            if (fmt == 0x78663230) return YES; // 'xf20'
            return NO;
    }
}

static BOOL vl_writableBuffer(CVPixelBufferRef pb) {
    if (!pb) return NO;
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(pb);
    return surf != NULL;
}

static void vl_logNewFormat(CVPixelBufferRef dst) {
    static NSMutableSet<NSString *> *sSeen = nil;
    static NSLock *sLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sSeen = [NSMutableSet new];
        sLock = [NSLock new];
    });

    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    OSType fmt = CVPixelBufferGetPixelFormatType(dst);
    char fcc[5] = {0};
    fcc[0] = (fmt >> 24) & 0xff;
    fcc[1] = (fmt >> 16) & 0xff;
    fcc[2] = (fmt >> 8) & 0xff;
    fcc[3] = fmt & 0xff;
    NSString *key = [NSString stringWithFormat:@"%zux%zu_%s", w, h, fcc];

    [sLock lock];
    BOOL first = ![sSeen containsObject:key];
    if (first) [sSeen addObject:key];
    [sLock unlock];

    if (first) {
        IOSurfaceRef surf = CVPixelBufferGetIOSurface(dst);
        vlog_always(@"replace",
            @"NEW FORMAT: %zux%zu '%s' (0x%08x) surface=%p",
            w, h, fcc, (unsigned)fmt, surf);
    }
}
