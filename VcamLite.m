//
//  VcamLite.m — 融合版相机替换内核 v2.3.2
//  v2.3：私有 Lossy 格式（&xv0 / &8v0 等）直转 + render 去重 + VT session 锁 + 私有格式 srcID 缓存
//  v2.3.1：FIX-P/Q/R/S
//  v2.3.2（仅针对"动作按键后还原真实相机"）：
//        FIX-T  vplist_enabled 加 lastKnown 缓存，读不到时保持上次已知值
//               对齐 VcamMax 的 lastEnabledState 思路
//        FIX-U  LiteCore.enabled 加连续 NO 防抖（1.5 秒窗口）
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
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#include <time.h>

// ══════════════════════════════════════════════════════════════════════
//  常量
// ══════════════════════════════════════════════════════════════════════
static NSString *const kVideoPath = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kPlistPath = @"/var/mobile/Media/DCIM/vc.plist";
static const char *const kNotifyAction = "com.vlite.action.changed";

static NSString *const kEnableKey     = @"enabled";
static NSString *const kActionToken   = @"actionToken";
static NSString *const kActionActive  = @"actionActive";
static NSString *const kManualRotKey  = @"manualRotation";

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

static CFStringRef const kVLProcessedKey = CFSTR("com.vlite.processed");

// ══════════════════════════════════════════════════════════════════════
//  Filza 日志
// ══════════════════════════════════════════════════════════════════════
static FILE *g_vl_log_fp = NULL;
static pthread_mutex_t g_vl_log_mutex = PTHREAD_MUTEX_INITIALIZER;

static void vl_write_log_file(const char *tag, const char *msg) {
    if (!msg) return;
    pthread_mutex_lock(&g_vl_log_mutex);
    if (!g_vl_log_fp) {
        const char *paths[] = {
            "/var/mobile/Media/DCIM/vlite_debug.log",
            "/var/mobile/Library/Preferences/vlite_debug.log",
            "/var/mobile/vlite_debug.log",
            "/tmp/vlite_debug.log",
            "/var/tmp/vlite_debug.log",
            NULL
        };
        for (int i = 0; paths[i]; i++) {
            g_vl_log_fp = fopen(paths[i], "a");
            if (g_vl_log_fp) {
                fprintf(g_vl_log_fp, "===== vlite log opened at %s (pid=%d) =====\n",
                        paths[i], (int)getpid());
                fflush(g_vl_log_fp);
                break;
            }
        }
    }
    if (g_vl_log_fp) {
        struct timeval tv; gettimeofday(&tv, NULL);
        struct tm tmv; time_t sec = tv.tv_sec; localtime_r(&sec, &tmv);
        fprintf(g_vl_log_fp, "[%02d:%02d:%02d.%03d][%s] %s\n",
                tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
                (int)(tv.tv_usec / 1000), tag ? tag : "?", msg);
        fflush(g_vl_log_fp);
    }
    pthread_mutex_unlock(&g_vl_log_mutex);
}

__attribute__((used))
static void vlog_always(NSString *tag, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[vlite][%@] %@", tag, m);
    vl_write_log_file([tag UTF8String], [m UTF8String]);
}

static void vlog(NSString *tag, NSString *fmt, ...) {
    static NSMutableDictionary<NSString *, NSNumber *> *sLast = nil;
    static NSLock *sLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sLast = [NSMutableDictionary new]; sLock = [NSLock new]; });
    [sLock lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *prev = sLast[tag];
    if (prev && now - [prev doubleValue] < 1.0) { [sLock unlock]; return; }
    sLast[tag] = @(now);
    [sLock unlock];
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[vlite][%@] %@", tag, m);
    vl_write_log_file([tag UTF8String], [m UTF8String]);
}

// ══════════════════════════════════════════════════════════════════════
//  plist
//  FIX-P: vplist_update 读失败时 abort，不写空字典
//  FIX-Q: vplist_cached 读失败保留旧 cache
// ══════════════════════════════════════════════════════════════════════
__attribute__((used))
static NSDictionary *vplist_cached(void) {
    static NSDictionary *cache = nil;
    static double lastMtime = -1;
    static NSLock *lk = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lk = [NSLock new]; });

    struct stat st;
    double m = -1;
    if (stat(kPlistPath.fileSystemRepresentation, &st) == 0) {
        m = (double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec / 1e9;
    }

    [lk lock];
    if (m != lastMtime || !cache) {
        NSDictionary *newCache = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
        if (newCache) {
            lastMtime = m;
            cache = newCache;
        } else if (!cache) {
            lastMtime = m;
        }
        // 已有 cache 但读失败：保留旧 cache，不更新 lastMtime
    }
    NSDictionary *r = cache;
    [lk unlock];
    return r;
}

__attribute__((used))
static void vplist_update(void (^block)(NSMutableDictionary *)) {
    @synchronized(@"vlite.plist") {
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
        if (!existing) {
            [NSThread sleepForTimeInterval:0.03];
            existing = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
        }
        if (!existing) {
            vlog_always(@"plist", @"update read failed, ABORT to protect fields");
            return;
        }
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:existing];
        block(d);
        [d writeToFile:kPlistPath atomically:YES];
    }
    notify_post(kNotifyAction);
}

// ★ FIX-T: vplist_enabled 加 lastKnown 缓存
//   对齐 VcamMax 的 lastEnabledState 思路：
//   只有读到明确值才更新缓存，读不到时保持上次已知状态
__attribute__((used))
static BOOL vplist_enabled(void) {
    static BOOL sLastKnown = NO;
    static BOOL sHasKnown = NO;
    static NSLock *sLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sLock = [NSLock new]; });

    NSDictionary *d = vplist_cached();
    NSNumber *n = d ? d[kEnableKey] : nil;

    if (n) {
        [sLock lock];
        sLastKnown = [n boolValue];
        sHasKnown = YES;
        [sLock unlock];
        return sLastKnown;
    }

    // 缓存里读不到：直读一次
    NSDictionary *fresh = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
    NSNumber *fn = fresh ? fresh[kEnableKey] : nil;
    if (fn) {
        [sLock lock];
        sLastKnown = [fn boolValue];
        sHasKnown = YES;
        [sLock unlock];
        return sLastKnown;
    }

    // ★ 彻底读不到：返回上次已知状态（默认 NO）
    [sLock lock];
    BOOL r = sHasKnown ? sLastKnown : NO;
    [sLock unlock];
    return r;
}

__attribute__((used))
static void vplist_set_enabled(BOOL en) {
    vplist_update(^(NSMutableDictionary *d) { d[kEnableKey] = @(en); });
}

__attribute__((used))
static int vplist_manualRotation(void) {
    NSDictionary *d = vplist_cached();
    NSNumber *n = d[kManualRotKey];
    int v = n ? [n intValue] : 0;
    v = v % 360; if (v < 0) v += 360;
    return v;
}

__attribute__((used))
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
//  可写检查 + 首次日志
// ══════════════════════════════════════════════════════════════════════
__attribute__((used))
static BOOL vl_writableBuffer(CVPixelBufferRef pb) {
    if (!pb) return NO;
    return CVPixelBufferGetIOSurface(pb) != NULL;
}

__attribute__((used))
static void vl_logNewFormat(CVPixelBufferRef dst, const char *from) {
    static NSMutableSet<NSString *> *sSeen = nil;
    static NSLock *sLock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sSeen = [NSMutableSet new]; sLock = [NSLock new]; });
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    OSType fmt = CVPixelBufferGetPixelFormatType(dst);
    char fcc[5] = {0};
    fcc[0] = (fmt >> 24) & 0xff; fcc[1] = (fmt >> 16) & 0xff;
    fcc[2] = (fmt >> 8) & 0xff;  fcc[3] = fmt & 0xff;
    NSString *key = [NSString stringWithFormat:@"%s_%zux%zu_%s", from, w, h, fcc];
    [sLock lock];
    BOOL first = ![sSeen containsObject:key];
    if (first) [sSeen addObject:key];
    [sLock unlock];
    if (first) {
        IOSurfaceRef surf = CVPixelBufferGetIOSurface(dst);
        vlog_always(@"replace", @"NEW[%s] %zux%zu '%s' (0x%08x) surface=%p",
                    from, w, h, fcc, (unsigned)fmt, surf);
    }
}

// ══════════════════════════════════════════════════════════════════════
//  LiteVideoDecoder
// ══════════════════════════════════════════════════════════════════════
typedef NS_ENUM(int, VLState) {
    VL_STATE_LOOP = 0,
    VL_STATE_ACTION,
    VL_STATE_FROZEN,
};

@interface LiteVideoDecoder : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (void)start;
- (void)stop;
- (CVPixelBufferRef)latestFrameRetained CF_RETURNS_RETAINED;
- (uint64_t)latestFrameID;
- (int)preferredRotation;
- (void)seekToActionStartUs:(int64_t)startUs endUs:(int64_t)endUs;
- (void)exitAction;
@end

@implementation LiteVideoDecoder {
    NSString *_path;
    dispatch_queue_t _q;
    os_unfair_lock _frameLock;
    CVPixelBufferRef _frame;
    _Atomic uint64_t _frameID;
    _Atomic int _running;
    _Atomic int _gen;
    _Atomic int _state;
    _Atomic int64_t _actionStartUs;
    _Atomic int64_t _actionEndUs;
    _Atomic int _actionDirty;
    _Atomic int _preferredRotation;
    double _fps;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _q = dispatch_queue_create("vlite.decoder", DISPATCH_QUEUE_SERIAL);
        _frameLock = OS_UNFAIR_LOCK_INIT;
        _fps = 30.0;
        atomic_store(&_state, VL_STATE_LOOP);
        atomic_store(&_preferredRotation, 0);
    }
    return self;
}

- (void)dealloc {
    atomic_fetch_add(&_gen, 1);
    atomic_store(&_running, 0);
    os_unfair_lock_lock(&_frameLock);
    if (_frame) { CVPixelBufferRelease(_frame); _frame = NULL; }
    os_unfair_lock_unlock(&_frameLock);
}

- (void)start {
    int myGen = (int)(atomic_fetch_add(&_gen, 1) + 1);
    atomic_store(&_running, 1);
    dispatch_async(_q, ^{ [self loopWithGen:myGen]; });
    vlog(@"decoder", @"start gen=%d", myGen);
}

- (void)stop {
    atomic_fetch_add(&_gen, 1);
    atomic_store(&_running, 0);
}

- (void)seekToActionStartUs:(int64_t)startUs endUs:(int64_t)endUs {
    if (startUs < 0) startUs = 0;
    if (endUs <= startUs) endUs = startUs + 1000000LL;
    atomic_store(&_actionStartUs, startUs);
    atomic_store(&_actionEndUs, endUs);
    atomic_store(&_state, VL_STATE_ACTION);
    atomic_store(&_actionDirty, 1);
}

- (void)exitAction {
    atomic_store(&_state, VL_STATE_LOOP);
    atomic_store(&_actionDirty, 1);
}

- (CVPixelBufferRef)latestFrameRetained {
    os_unfair_lock_lock(&_frameLock);
    CVPixelBufferRef pb = _frame;
    if (pb) CVPixelBufferRetain(pb);
    os_unfair_lock_unlock(&_frameLock);
    return pb;
}

- (uint64_t)latestFrameID { return atomic_load(&_frameID); }
- (int)preferredRotation { return atomic_load(&_preferredRotation); }

- (void)loopWithGen:(int)myGen {
    while (atomic_load(&_running) && atomic_load(&_gen) == myGen) {
        @autoreleasepool {
            if (atomic_load(&_gen) != myGen) break;
            VLState st = (VLState)atomic_load(&_state);
            BOOL dirty = atomic_exchange(&_actionDirty, 0);

            if (st == VL_STATE_FROZEN && !dirty) {
                [NSThread sleepForTimeInterval:0.05];
                continue;
            }

            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:
                [NSURL fileURLWithPath:_path]
                options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
            NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if (tracks.count == 0) { sleep(1); continue; }
            AVAssetTrack *track = tracks[0];

            CGAffineTransform pt = track.preferredTransform;
            int rot = 0;
            if (pt.a == 0 && pt.b == 1 && pt.c == -1 && pt.d == 0)       rot = 90;
            else if (pt.a == -1 && pt.b == 0 && pt.c == 0 && pt.d == -1) rot = 180;
            else if (pt.a == 0 && pt.b == -1 && pt.c == 1 && pt.d == 0)  rot = 270;
            if (rot != atomic_load(&_preferredRotation)) {
                atomic_store(&_preferredRotation, rot);
                vlog_always(@"decoder", @"preferredRotation = %d", rot);
            }

            double nominal = track.nominalFrameRate;
            if (nominal > 1.0 && nominal < 240.0) _fps = nominal;
            NSTimeInterval frameInterval = 1.0 / _fps;

            int64_t localStart = 0, localEnd = 0;
            if (st == VL_STATE_ACTION) {
                localStart = atomic_load(&_actionStartUs);
                localEnd   = atomic_load(&_actionEndUs);
                double durSec = CMTimeGetSeconds(asset.duration);
                if (durSec > 0.05) {
                    int64_t durUs = (int64_t)llround(durSec * 1e6);
                    if (localEnd > durUs) localEnd = durUs;
                    if (localStart >= durUs - 10000LL) localStart = 0;
                }
                if (localEnd <= localStart + 1000LL) {
                    atomic_store(&_state, VL_STATE_LOOP);
                    continue;
                }
            }

            NSError *err = nil;
            AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
            if (!reader) { sleep(1); continue; }
            NSDictionary *settings = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:track outputSettings:settings];
            out.alwaysCopiesSampleData = NO;
            if (![reader canAddOutput:out]) { sleep(1); continue; }
            [reader addOutput:out];

            if (st == VL_STATE_ACTION) {
                CMTime start = CMTimeMake(localStart, 1000000);
                CMTime end   = CMTimeMake(localEnd,   1000000);
                reader.timeRange = CMTimeRangeMake(start, CMTimeSubtract(end, start));
                vlog(@"action", @"range [%.3fs-%.3fs]", localStart/1e6, localEnd/1e6);
            }

            if (![reader startReading]) { sleep(1); continue; }

            NSTimeInterval nextTick = CACurrentMediaTime();
            while (atomic_load(&_running) &&
                   atomic_load(&_gen) == myGen &&
                   reader.status == AVAssetReaderStatusReading) {
                if (atomic_load(&_gen) != myGen) break;
                if (atomic_load(&_state) != (int)st || atomic_load(&_actionDirty)) break;

                CMSampleBufferRef sb = [out copyNextSampleBuffer];
                if (!sb) break;
                CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
                if (pb) {
                    CVPixelBufferRetain(pb);
                    os_unfair_lock_lock(&_frameLock);
                    CVPixelBufferRef old = _frame;
                    _frame = pb;
                    atomic_fetch_add(&_frameID, 1);
                    os_unfair_lock_unlock(&_frameLock);
                    if (old) CVPixelBufferRelease(old);
                }
                CFRelease(sb);

                nextTick += frameInterval;
                NSTimeInterval wait = nextTick - CACurrentMediaTime();
                if (wait > 0.001) [NSThread sleepForTimeInterval:wait];
                else nextTick = CACurrentMediaTime();
            }
            [reader cancelReading];

            int curState = atomic_load(&_state);
            BOOL interrupted = (curState != (int)st) || (atomic_load(&_actionDirty) != 0);
            if (!interrupted && curState == VL_STATE_ACTION) {
                atomic_store(&_state, VL_STATE_FROZEN);
                vlog(@"action", @"done -> frozen");
            }
        }
    }
    vlog(@"decoder", @"loop exit gen=%d", myGen);
}

@end

// ══════════════════════════════════════════════════════════════════════
//  LiteProcessor
// ══════════════════════════════════════════════════════════════════════
@interface LiteCache : NSObject
@property (nonatomic, assign) CVPixelBufferRef buf;
@property (nonatomic, assign) uint64_t srcID;
@end
@implementation LiteCache
- (void)dealloc { if (_buf) CVPixelBufferRelease(_buf); }
@end

@interface LitePrivateCache : NSObject
@property (nonatomic, assign) uint32_t iosurfaceID;
@property (nonatomic, assign) uint64_t srcID;
@property (nonatomic, assign) CFAbsoluteTime lastUse;
@end
@implementation LitePrivateCache
@end

@interface LiteProcessor : NSObject
- (BOOL)transfer:(CVPixelBufferRef)src srcID:(uint64_t)srcID into:(CVPixelBufferRef)dst;
- (CVPixelBufferRef)rotateBuffer:(CVPixelBufferRef)src byDegrees:(int)deg CF_RETURNS_RETAINED;
- (BOOL)rotationAvailable;
@end

@implementation LiteProcessor {
    VTPixelTransferSessionRef _sess;
    VTPixelTransferSessionRef _slowSess;
    NSRecursiveLock *_lock;
    NSMutableDictionary<NSString *, LiteCache *> *_caches;
    NSLock *_vtLock;
    NSMutableDictionary<NSNumber *, LitePrivateCache *> *_privateCache;

    VTPixelRotationSessionRef _rotSess;
    BOOL _rotAvailable;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSRecursiveLock new];
        _caches = [NSMutableDictionary new];
        _vtLock = [NSLock new];
        _privateCache = [NSMutableDictionary new];

        _rotSess = NULL;
        _rotAvailable = NO;
        @try {
            typedef OSStatus (*RotCreateFn)(CFAllocatorRef, VTPixelRotationSessionRef *);
            RotCreateFn createRot = (RotCreateFn)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionCreate");
            typedef OSStatus (*RotXferFn)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);
            RotXferFn xferRot = (RotXferFn)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionRotateImage");
            if (createRot && xferRot) {
                VTPixelRotationSessionRef s = NULL;
                if (createRot(kCFAllocatorDefault, &s) == noErr && s) {
                    _rotSess = s;
                    _rotAvailable = YES;
                }
            }
        } @catch (NSException *e) {
            _rotSess = NULL;
            _rotAvailable = NO;
        }

        OSStatus s = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_sess);
        if (s != noErr || !_sess) { _sess = NULL; return self; }
        CFStringRef *pRT = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_RealTime");
        CFStringRef *pSM = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_ScalingMode");
        if (pRT && *pRT) VTSessionSetProperty(_sess, *pRT, kCFBooleanTrue);
        if (pSM && *pSM) VTSessionSetProperty(_sess, *pSM, CFSTR("Trim"));

        OSStatus s2 = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_slowSess);
        if (s2 != noErr || !_slowSess) { _slowSess = NULL; }
        else {
            if (pSM && *pSM) VTSessionSetProperty(_slowSess, *pSM, CFSTR("Trim"));
        }
    }
    return self;
}

- (void)dealloc {
    if (_sess) { VTPixelTransferSessionInvalidate(_sess); CFRelease(_sess); }
    if (_slowSess) { VTPixelTransferSessionInvalidate(_slowSess); CFRelease(_slowSess); }
    if (_rotSess) {
        typedef void (*RotInvFn)(VTPixelRotationSessionRef);
        RotInvFn invRot = (RotInvFn)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionInvalidate");
        if (invRot) invRot(_rotSess);
        CFRelease(_rotSess);
        _rotSess = NULL;
    }
}

- (BOOL)rotationAvailable { return _rotAvailable; }

- (CVPixelBufferRef)rotateBuffer:(CVPixelBufferRef)src byDegrees:(int)deg CF_RETURNS_RETAINED {
    if (!src || deg == 0 || !_rotAvailable || !_rotSess) return NULL;
    deg = deg % 360; if (deg < 0) deg += 360;
    if (deg == 0) return NULL;

    typedef OSStatus (*RotXferFn)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);
    static RotXferFn xferRot = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xferRot = (RotXferFn)dlsym(RTLD_DEFAULT, "VTPixelRotationSessionRotateImage");
    });
    if (!xferRot) return NULL;

    static CFStringRef propKey = NULL;
    static CFStringRef ccw90 = NULL, cw90 = NULL, r180 = NULL;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        void *p = dlsym(RTLD_DEFAULT, "kVTPixelRotationPropertyKey_Rotation");
        propKey = p ? *(CFStringRef *)p : CFSTR("Rotation");
        void *a = dlsym(RTLD_DEFAULT, "kVTRotation_CCW90");
        void *b = dlsym(RTLD_DEFAULT, "kVTRotation_CW90");
        void *c = dlsym(RTLD_DEFAULT, "kVTRotation_180");
        ccw90 = a ? *(CFStringRef *)a : CFSTR("CCW90");
        cw90  = b ? *(CFStringRef *)b : CFSTR("CW90");
        r180  = c ? *(CFStringRef *)c : CFSTR("180");
    });

    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    size_t ow = (deg == 90 || deg == 270) ? sh : sw;
    size_t oh = (deg == 90 || deg == 270) ? sw : sh;
    OSType fmt = CVPixelBufferGetPixelFormatType(src);

    CVPixelBufferRef out = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey:  @(ow),
        (id)kCVPixelBufferHeightKey: @(oh),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, ow, oh, fmt,
                            (__bridge CFDictionaryRef)attrs, &out) != kCVReturnSuccess || !out) {
        return NULL;
    }

    CFStringRef rotVal;
    if (deg == 90)       rotVal = cw90;
    else if (deg == 180) rotVal = r180;
    else if (deg == 270) rotVal = ccw90;
    else { CVPixelBufferRelease(out); return NULL; }

    VTSessionSetProperty(_rotSess, propKey, rotVal);
    OSStatus st = xferRot(_rotSess, src, out);
    if (st != noErr) {
        CVPixelBufferRelease(out);
        return NULL;
    }
    return out;
}

static BOOL vmemcpy(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (CVPixelBufferGetPixelFormatType(src) != CVPixelBufferGetPixelFormatType(dst)) return NO;
    if (CVPixelBufferGetWidth(src) != CVPixelBufferGetWidth(dst)) return NO;
    if (CVPixelBufferGetHeight(src) != CVPixelBufferGetHeight(dst)) return NO;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    BOOL ok = YES;
    if (CVPixelBufferIsPlanar(src)) {
        size_t np = CVPixelBufferGetPlaneCount(src);
        for (size_t p = 0; p < np; p++) {
            const uint8_t *sp = CVPixelBufferGetBaseAddressOfPlane(src, p);
            uint8_t *dp = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t ss = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t ds = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t h  = CVPixelBufferGetHeightOfPlane(src, p);
            size_t copy = ss < ds ? ss : ds;
            if (!sp || !dp) { ok = NO; break; }
            for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy);
        }
    } else {
        const uint8_t *sp = CVPixelBufferGetBaseAddress(src);
        uint8_t *dp = CVPixelBufferGetBaseAddress(dst);
        size_t ss = CVPixelBufferGetBytesPerRow(src);
        size_t ds = CVPixelBufferGetBytesPerRow(dst);
        size_t h  = CVPixelBufferGetHeight(src);
        size_t copy = ss < ds ? ss : ds;
        if (!sp || !dp) ok = NO;
        else for (size_t y = 0; y < h; y++) memcpy(dp + y*ds, sp + y*ss, copy);
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return ok;
}

static BOOL vl_is_private_format(OSType fmt) {
    if (fmt == kCVPixelFormatType_32BGRA) return NO;
    if (fmt == 0x34323076) return NO;
    if (fmt == 0x34323066) return NO;
    if (fmt == 0x70343230) return NO;
    return YES;
}

- (BOOL)transfer:(CVPixelBufferRef)src srcID:(uint64_t)srcID into:(CVPixelBufferRef)dst {
    if (!src || !dst || !_sess) return NO;
    size_t dw = CVPixelBufferGetWidth(dst);
    size_t dh = CVPixelBufferGetHeight(dst);
    OSType fmt = CVPixelBufferGetPixelFormatType(dst);

    if (vl_is_private_format(fmt)) {
        IOSurfaceRef surf = CVPixelBufferGetIOSurface(dst);
        uint32_t surfID = surf ? IOSurfaceGetID(surf) : 0;
        NSNumber *cacheKey = @(surfID);

        [_lock lock];
        LitePrivateCache *pc = _privateCache[cacheKey];
        if (pc && pc.srcID == srcID && srcID != 0) {
            [_lock unlock];
            return YES;
        }
        if (!pc) {
            pc = [LitePrivateCache new];
            pc.iosurfaceID = surfID;
            _privateCache[cacheKey] = pc;
        }
        [_lock unlock];

        [_vtLock lock];
        OSStatus s = VTPixelTransferSessionTransferImage(_sess, src, dst);
        if (s != noErr && _slowSess) {
            s = VTPixelTransferSessionTransferImage(_slowSess, src, dst);
        }
        [_vtLock unlock];

        if (s == noErr) {
            [_lock lock];
            pc.srcID = srcID;
            pc.lastUse = CFAbsoluteTimeGetCurrent();
            if (_privateCache.count > 64) {
                CFAbsoluteTime cutoff = CFAbsoluteTimeGetCurrent() - 10.0;
                NSMutableArray *toRemove = [NSMutableArray array];
                for (NSNumber *k in _privateCache) {
                    if (_privateCache[k].lastUse < cutoff) [toRemove addObject:k];
                }
                [_privateCache removeObjectsForKeys:toRemove];
            }
            [_lock unlock];
        }

        static NSMutableSet<NSNumber *> *sSeen = nil;
        static NSLock *sSeenLock = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sSeen = [NSMutableSet new]; sSeenLock = [NSLock new]; });
        NSNumber *dk = @(fmt);
        [sSeenLock lock];
        BOOL first = ![sSeen containsObject:dk];
        if (first) [sSeen addObject:dk];
        [sSeenLock unlock];
        if (first) {
            char fcc[5] = {0};
            fcc[0] = (fmt >> 24) & 0xff; fcc[1] = (fmt >> 16) & 0xff;
            fcc[2] = (fmt >> 8) & 0xff;  fcc[3] = fmt & 0xff;
            vlog_always(@"proc", @"DIRECT-VT fmt='%s'(0x%x) %zux%zu status=%d",
                        fcc, (unsigned)fmt, dw, dh, (int)s);
        }
        return s == noErr;
    }

    NSString *key = [NSString stringWithFormat:@"%zu_%zu_%u", dw, dh, (unsigned)fmt];

    [_lock lock];
    LiteCache *c = _caches[key];
    if (!c) {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferWidthKey:  @(dw),
            (id)kCVPixelBufferHeightKey: @(dh),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferRef pb = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, dw, dh, fmt,
                                (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
            [_lock unlock]; return NO;
        }
        c = [LiteCache new];
        c.buf = pb;
        c.srcID = 0;
        _caches[key] = c;
    }
    if (c.srcID != srcID) {
        [_vtLock lock];
        OSStatus s = VTPixelTransferSessionTransferImage(_sess, src, c.buf);
        [_vtLock unlock];
        if (s == noErr) c.srcID = srcID;
        else { c.srcID = 0; [_lock unlock]; return NO; }
    }
    BOOL ok = vmemcpy(c.buf, dst);
    [_lock unlock];
    return ok;
}

@end

// ══════════════════════════════════════════════════════════════════════
//  LiteCore
//  ★ FIX-U: enabled 加连续 NO 防抖
// ══════════════════════════════════════════════════════════════════════
@interface LiteCore : NSObject
+ (instancetype)shared;
- (BOOL)enabled;
- (void)replaceInPlace:(CMSampleBufferRef)sb from:(const char *)from;
- (void)checkActionFromPlist;
@end

@implementation LiteCore {
    LiteVideoDecoder *_dec;
    LiteProcessor *_proc;
    BOOL _started;
    CFAbsoluteTime _lastCheck;
    BOOL _enabledCache;
    int64_t _lastToken;
    BOOL _actionInited;
    os_unfair_lock _coreLock;

    int _manualRotation;
    NSInteger _lastSyncedManualRot;
    CVPixelBufferRef _rotCache;
    uint64_t _rotCacheSrcID;
    int _rotCacheDeg;
    NSLock *_rotLock;

    int _consecutiveNO;   // ★ FIX-U
}

+ (instancetype)shared {
    static LiteCore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LiteCore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _proc = [LiteProcessor new];
        _dec = [[LiteVideoDecoder alloc] initWithPath:kVideoPath];
        _lastToken = -1;
        _actionInited = NO;
        _coreLock = OS_UNFAIR_LOCK_INIT;

        _manualRotation = 0;
        _lastSyncedManualRot = -1;
        _rotCache = NULL;
        _rotCacheSrcID = 0;
        _rotCacheDeg = 0;
        _rotLock = [NSLock new];

        _consecutiveNO = 0;
    }
    return self;
}

- (void)dealloc {
    if (_rotCache) { CVPixelBufferRelease(_rotCache); _rotCache = NULL; }
}

- (BOOL)enabled {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastCheck < 0.5) return _enabledCache;
    os_unfair_lock_lock(&_coreLock);
    if (now - _lastCheck < 0.5) {
        BOOL r = _enabledCache;
        os_unfair_lock_unlock(&_coreLock);
        return r;
    }
    _lastCheck = now;
    os_unfair_lock_unlock(&_coreLock);

    BOOL plist = vplist_enabled();
    BOOL vid   = [[NSFileManager defaultManager] fileExistsAtPath:kVideoPath];
    BOOL en    = plist && vid;

    // ★ FIX-U: 连续 3 次（1.5 秒）NO 才真正翻转
    os_unfair_lock_lock(&_coreLock);
    if (en) {
        _consecutiveNO = 0;
    } else {
        _consecutiveNO++;
        if (_consecutiveNO < 3 && _enabledCache) {
            en = _enabledCache;
        }
    }
    os_unfair_lock_unlock(&_coreLock);

    BOOL shouldStart = NO, shouldStop = NO;
    os_unfair_lock_lock(&_coreLock);
    if (en && !_started) { shouldStart = YES; _started = YES; }
    else if (!en && _started) { shouldStop = YES; _started = NO; }
    _enabledCache = en;
    os_unfair_lock_unlock(&_coreLock);

    if (shouldStart) [_dec start];
    if (shouldStop) { [_dec stop]; [_dec exitAction]; }
    return en;
}

- (void)doAction:(int)act plist:(NSDictionary *)pl {
    int64_t s = 0, e = 0;
    if (act == 1) {
        s = vplist_get_us(pl, kBlinkS_us, kBlinkS_s, kBlinkStartDefUs);
        e = vplist_get_us(pl, kBlinkE_us, kBlinkE_s, kBlinkEndDefUs);
    } else if (act == 2) {
        s = vplist_get_us(pl, kMouthS_us, kMouthS_s, kMouthStartDefUs);
        e = vplist_get_us(pl, kMouthE_us, kMouthE_s, kMouthEndDefUs);
    } else {
        s = vplist_get_us(pl, kHeadS_us, kHeadS_s, kHeadStartDefUs);
        e = vplist_get_us(pl, kHeadE_us, kHeadE_s, kHeadEndDefUs);
    }
    [_dec seekToActionStartUs:s endUs:e];
    vlog(@"action", @"START act=%d [%.3fs-%.3fs]", act, s/1e6, e/1e6);
}

- (void)checkActionFromPlist {
    NSDictionary *pl = vplist_cached();
    if (!pl) return;

    NSNumber *mr = pl[kManualRotKey];
    NSInteger curManualRot = mr ? [mr integerValue] : 0;
    if (curManualRot != _lastSyncedManualRot) {
        _lastSyncedManualRot = curManualRot;
        _manualRotation = (int)(curManualRot % 360);
        if (_manualRotation < 0) _manualRotation += 360;
        [_rotLock lock];
        if (_rotCache) { CVPixelBufferRelease(_rotCache); _rotCache = NULL; }
        _rotCacheSrcID = 0;
        [_rotLock unlock];
        vlog_always(@"rotate", @"manualRotation -> %d", _manualRotation);
    }

    NSNumber *t = pl[kActionToken];
    NSNumber *a = pl[kActionActive];
    int64_t tok = t ? [t longLongValue] : 0;
    int act = a ? [a intValue] : 0;

    BOOL needAction = NO;
    int actionAct = 0;
    BOOL needExit = NO;

    os_unfair_lock_lock(&_coreLock);
    if (!_actionInited) {
        _actionInited = YES;
        _lastToken = tok;
        if (act >= 1 && act <= 3) { needAction = YES; actionAct = act; }
    } else if (tok != _lastToken) {
        _lastToken = tok;
        if (act >= 1 && act <= 3) { needAction = YES; actionAct = act; }
        else { needExit = YES; }
    }
    os_unfair_lock_unlock(&_coreLock);

    if (needAction) [self doAction:actionAct plist:pl];
    if (needExit) { [_dec exitAction]; vlog(@"action", @"EXIT"); }
}

- (void)replaceInPlace:(CMSampleBufferRef)sb from:(const char *)from {
    if (!sb) return;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (!fd || CMFormatDescriptionGetMediaType(fd) != kCMMediaType_Video) return;

    CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(sb);
    if (!dst) return;

    vl_logNewFormat(dst, from);
    OSType fmt = CVPixelBufferGetPixelFormatType(dst);

    if (fmt == 0x2D387630 || fmt == 0x2D386630 ||
        fmt == 0x2D787630 || fmt == 0x2D786630 || fmt == 0x2D343230 ||
        fmt == 0x26787630 || fmt == 0x26387630 ||
        fmt == 0x26786630 || fmt == 0x26386630) {
        static NSMutableSet<NSString *> *sSeenLossy = nil;
        static NSLock *sLL = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sSeenLossy = [NSMutableSet new]; sLL = [NSLock new]; });
        NSString *k = [NSString stringWithFormat:@"%s_0x%x", from, (unsigned)fmt];
        [sLL lock];
        BOOL first = ![sSeenLossy containsObject:k];
        if (first) [sSeenLossy addObject:k];
        [sLL unlock];
        if (first) vlog_always(@"replace", @"HIT lossy 0x%x from=%s (will attempt)", (unsigned)fmt, from);
    }

    if (!vl_writableBuffer(dst)) {
        static NSMutableSet<NSString *> *sWarn = nil;
        static NSLock *sWL = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sWarn = [NSMutableSet new]; sWL = [NSLock new]; });
        size_t w = CVPixelBufferGetWidth(dst);
        size_t h = CVPixelBufferGetHeight(dst);
        NSString *k = [NSString stringWithFormat:@"%zux%zu_%u", w, h, (unsigned)fmt];
        [sWL lock];
        BOOL first = ![sWarn containsObject:k];
        if (first) [sWarn addObject:k];
        [sWL unlock];
        if (first) vlog_always(@"replace", @"WARN non-writable %zux%zu fmt=0x%x from=%s", w, h, (unsigned)fmt, from);
    }

    uint64_t srcID = [_dec latestFrameID];
    if (srcID == 0) return;
    CVPixelBufferRef src = [_dec latestFrameRetained];
    if (!src) return;

    int preferred = [_dec preferredRotation];
    int manual = _manualRotation;
    int totalRot = (preferred + manual) % 360;
    if (totalRot < 0) totalRot += 360;

    CVPixelBufferRef srcToTransfer = src;
    CVPixelBufferRef rotatedTmp = NULL;
    if (totalRot != 0 && [_proc rotationAvailable]) {
        [_rotLock lock];
        if (_rotCache && _rotCacheSrcID == srcID && _rotCacheDeg == totalRot && srcID != 0) {
            rotatedTmp = CVPixelBufferRetain(_rotCache);
        }
        [_rotLock unlock];
        if (!rotatedTmp) {
            CVPixelBufferRef r = [_proc rotateBuffer:src byDegrees:totalRot];
            if (r) {
                rotatedTmp = r;
                [_rotLock lock];
                if (_rotCache) CVPixelBufferRelease(_rotCache);
                _rotCache = CVPixelBufferRetain(r);
                _rotCacheSrcID = srcID;
                _rotCacheDeg = totalRot;
                [_rotLock unlock];
            }
        }
        if (rotatedTmp) srcToTransfer = rotatedTmp;
    }

    static NSMutableSet<NSString *> *sDone = nil;
    static NSLock *sDL = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{ sDone = [NSMutableSet new]; sDL = [NSLock new]; });
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    NSString *k = [NSString stringWithFormat:@"%s_%zux%zu_%u", from, w, h, (unsigned)fmt];
    [sDL lock];
    BOOL firstLog = ![sDone containsObject:k];
    if (firstLog) [sDone addObject:k];
    [sDL unlock];

    BOOL ok = [_proc transfer:srcToTransfer srcID:srcID into:dst];
    if (firstLog) {
        vlog_always(@"replace", @"REPLACE[%s] %zux%zu fmt=0x%x rot=%d ok=%d",
                    from, w, h, (unsigned)fmt, totalRot, ok);
    }
    if (rotatedTmp) CVPixelBufferRelease(rotatedTmp);
    CVPixelBufferRelease(src);
}

@end

// ══════════════════════════════════════════════════════════════════════
//  Hook 层
// ══════════════════════════════════════════════════════════════════════
static NSMutableDictionary<NSValue *, NSValue *> *gOrigIMP = nil;
static _Atomic int gInstalled = 0;

__attribute__((used))
static BOOL class_owns_method(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL owns = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (sel_isEqual(method_getName(list[i]), sel)) { owns = YES; break; }
    }
    if (list) free(list);
    return owns;
}

__attribute__((used))
static IMP orig_imp_for(Class cls) {
    if (!gOrigIMP) return NULL;
    @synchronized(gOrigIMP) {
        NSValue *v = gOrigIMP[[NSValue valueWithPointer:(__bridge const void *)cls]];
        return v ? (IMP)[v pointerValue] : NULL;
    }
}

__attribute__((used))
static IMP orig_imp_for_instance(id _self) {
    Class c = object_getClass(_self);
    while (c) {
        IMP f = orig_imp_for(c);
        if (f) return f;
        c = class_getSuperclass(c);
    }
    return NULL;
}

__attribute__((used))
static void vl_emit_body(id _self, SEL _cmd, CMSampleBufferRef sb) {
    static _Atomic int sCnt = 0;
    int c = atomic_fetch_add(&sCnt, 1);
    if ((c % 120) == 0) {
        CVPixelBufferRef pb = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
        OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
        const char *cls = object_getClassName(_self);
        vlog_always(@"emit-trace", @"#%d cls=%s fmt=0x%x", c, cls, (unsigned)fmt);
    }

    @autoreleasepool {
        if (sb) {
            CFTypeRef processed = CMGetAttachment(sb, kVLProcessedKey, NULL);
            BOOL alreadyProcessed = (processed != NULL &&
                                     CFGetTypeID(processed) == CFBooleanGetTypeID() &&
                                     CFBooleanGetValue((CFBooleanRef)processed));
            if (!alreadyProcessed && [LiteCore.shared enabled]) {
                CMSetAttachment(sb, kVLProcessedKey, kCFBooleanTrue,
                                kCMAttachmentMode_ShouldNotPropagate);
                @try {
                    [LiteCore.shared checkActionFromPlist];
                    SEL mtSel = sel_registerName("mediaType");
                    BOOL isVideo = YES;
                    if ([_self respondsToSelector:mtSel]) {
                        uint32_t mt = ((uint32_t(*)(id,SEL))objc_msgSend)(_self, mtSel);
                        if (mt != 'vide') isVideo = NO;
                    }
                    if (isVideo) {
                        NSString *cls = NSStringFromClass(object_getClass(_self));
                        [LiteCore.shared replaceInPlace:sb from:[cls UTF8String]];
                    }
                } @catch (NSException *e) { vlog(@"emit", @"exc: %@", e); }
            }
        }
    }
    IMP orig = orig_imp_for_instance(_self);
    if (orig) ((void(*)(id,SEL,CMSampleBufferRef))orig)(_self, _cmd, sb);
}

__attribute__((used))
static void vl_render_body(id _self, SEL _cmd, CMSampleBufferRef sb, id input) {
    static _Atomic int sCnt2 = 0;
    int c = atomic_fetch_add(&sCnt2, 1);
    if ((c % 120) == 0) {
        CVPixelBufferRef pb = sb ? CMSampleBufferGetImageBuffer(sb) : NULL;
        OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
        const char *cls = object_getClassName(_self);
        vlog_always(@"render-trace", @"#%d cls=%s fmt=0x%x", c, cls, (unsigned)fmt);
    }

    @autoreleasepool {
        if (sb && [LiteCore.shared enabled]) {
            CFTypeRef processed = CMGetAttachment(sb, kVLProcessedKey, NULL);
            BOOL alreadyProcessed = (processed != NULL &&
                                     CFGetTypeID(processed) == CFBooleanGetTypeID() &&
                                     CFBooleanGetValue((CFBooleanRef)processed));
            if (!alreadyProcessed) {
                CMSetAttachment(sb, kVLProcessedKey, kCFBooleanTrue,
                                kCMAttachmentMode_ShouldNotPropagate);
                @try {
                    NSString *cls = NSStringFromClass(object_getClass(_self));
                    [LiteCore.shared replaceInPlace:sb from:[cls UTF8String]];
                }
                @catch (NSException *e) { vlog(@"render", @"exc: %@", e); }
            }
        }
    }
    IMP orig = orig_imp_for_instance(_self);
    if (orig) ((void(*)(id,SEL,CMSampleBufferRef,id))orig)(_self, _cmd, sb, input);
}

__attribute__((used))
static BOOL hook_class_method(Class cls, SEL sel, IMP newImp, BOOL requireOwns) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    Class owner = cls;
    while (owner && !class_owns_method(owner, sel)) {
        owner = class_getSuperclass(owner);
    }
    if (!owner) return NO;

    (void)requireOwns;

    IMP curIMP = method_getImplementation(m);
    if (curIMP == newImp) return NO;

    if (!gOrigIMP) gOrigIMP = [NSMutableDictionary new];
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)owner];
    @synchronized(gOrigIMP) {
        if (gOrigIMP[key]) return NO;
        gOrigIMP[key] = [NSValue valueWithPointer:(const void *)curIMP];
    }
    method_setImplementation(m, newImp);
    return YES;
}

__attribute__((used))
static int hook_all_subclasses(const char *baseName, SEL sel, IMP newImp) {
    Class base = objc_getClass(baseName);
    if (!base) return 0;
    int hooked = 0;
    if (hook_class_method(base, sel, newImp, YES)) hooked++;
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        if (c == base) continue;
        Class p = c;
        BOOL isDesc = NO;
        while (p) { if (p == base) { isDesc = YES; break; } p = class_getSuperclass(p); }
        if (!isDesc) continue;
        if (hook_class_method(c, sel, newImp, YES)) hooked++;
    }
    if (all) free(all);
    return hooked;
}

__attribute__((used))
static int hook_all_render_classes(void) {
    int hooked = 0;
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        const char *name = class_getName(c);
        if (!strstr(name, "BW")) continue;

        if (hook_class_method(c, @selector(renderSampleBuffer:forInput:),
                              (IMP)vl_render_body, YES)) {
            vlog_always(@"hook", @"+render: %s", name);
            hooked++;
        }
        if (hook_class_method(c, @selector(emitSampleBuffer:),
                              (IMP)vl_emit_body, YES)) {
            vlog_always(@"hook", @"+emit: %s", name);
            hooked++;
        }
    }
    if (all) free(all);
    return hooked;
}

__attribute__((used))
static void vl_dump_bw_methods_once(void) {
    static BOOL sDone = NO;
    if (sDone) return;
    sDone = YES;
    vlog_always(@"dump", @"===== BW methods dump start =====");
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        const char *name = class_getName(c);
        if (!strstr(name, "BW")) continue;

        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        for (unsigned int j = 0; j < n; j++) {
            const char *sn = sel_getName(method_getName(list[j]));
            if (strstr(sn, "uffer") || strstr(sn, "emit") ||
                strstr(sn, "render") || strstr(sn, "ncode") ||
                strstr(sn, "rite") || strstr(sn, "onsume") ||
                strstr(sn, "rocess") || strstr(sn, "eceive") ||
                strstr(sn, "apture") || strstr(sn, "ample")) {
                const char *enc = method_getTypeEncoding(list[j]);
                vlog_always(@"dump", @"%s -> %s | %s", name, sn, enc ? enc : "?");
            }
        }
        if (list) free(list);
    }
    free(all);
    vlog_always(@"dump", @"===== BW methods dump end =====");
}

__attribute__((used))
static void install_hooks(void) {
    int n1 = hook_all_subclasses("BWNodeOutput",
                @selector(emitSampleBuffer:), (IMP)vl_emit_body);
    int n2 = hook_all_subclasses("BWStillImageScalerNode",
                @selector(renderSampleBuffer:forInput:), (IMP)vl_render_body);
    int n3 = hook_all_subclasses("BWPhotoEncoderNode",
                @selector(renderSampleBuffer:forInput:), (IMP)vl_render_body);
    int n4 = hook_all_render_classes();

    if (n1 + n2 + n3 + n4 > 0) {
        vlog_always(@"hook", @"new pass: emit=%d scaler=%d encoder=%d generic=%d",
                    n1, n2, n3, n4);
    }

    vl_dump_bw_methods_once();

    if (atomic_exchange(&gInstalled, 1) == 0) {
        int token = -1;
        notify_register_dispatch(kNotifyAction, &token,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^(int t) {
                @autoreleasepool {
                    if ([LiteCore.shared enabled]) {
                        [LiteCore.shared checkActionFromPlist];
                    }
                }
            });
        vlog(@"hook", @"notify registered (token=%d)", token);
    }
}

__attribute__((used))
static void *install_thread(void *arg) {
    (void)arg;
    while (1) {
        @autoreleasepool {
            if (objc_getClass("BWNodeOutput")) {
                install_hooks();
            }
        }
        sleep(1);
    }
    return NULL;
}

// ══════════════════════════════════════════════════════════════════════
//  UI 层
// ══════════════════════════════════════════════════════════════════════
@interface VLWindow : UIWindow @end
@implementation VLWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface VLHitThroughView : UIView @end
@implementation VLHitThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}
@end

@interface VLBall : NSObject <PHPickerViewControllerDelegate>
+ (instancetype)shared;
- (void)show;
@end

@implementation VLBall {
    VLWindow *_win;
    UIButton *_ball;
    UIView *_panel;
    UIButton *_tabControlBtn;
    UIButton *_tabTimeBtn;
    UIView *_pageControl;
    UIView *_pageTime;
    UIButton *_toggleBtn;
    int _currentTab;
}

+ (instancetype)shared {
    static VLBall *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VLBall new]; });
    return s;
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_win) return;
        [self createWindow];
    });
}

- (void)createWindow {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
        }
    }
    if (!scene) {
        static int sRetry = 0;
        sRetry++;
        if (sRetry > 60) { vlog_always(@"ui", @"createWindow: give up"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self createWindow]; });
        return;
    }

    CGRect screen = scene.coordinateSpace.bounds;
    _win = [[VLWindow alloc] initWithWindowScene:scene];
    _win.frame = screen;
    _win.windowLevel = UIWindowLevelAlert + 100;
    _win.backgroundColor = [UIColor clearColor];
    _win.hidden = NO;

    UIViewController *rootVC = [UIViewController new];
    rootVC.view.backgroundColor = [UIColor clearColor];
    rootVC.view.userInteractionEnabled = YES;
    _win.rootViewController = rootVC;

    CGFloat bs = 50;
    CGFloat bx = screen.size.width - bs - 20;
    CGFloat by = screen.size.height / 2 - bs / 2;
    _ball = [UIButton buttonWithType:UIButtonTypeSystem];
    _ball.frame = CGRectMake(bx, by, bs, bs);
    _ball.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.38 alpha:0.92];
    _ball.layer.cornerRadius = bs / 2;
    _ball.layer.borderWidth = 2;
    _ball.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1].CGColor;
    UIImage *icon = [UIImage systemImageNamed:@"video.fill"];
    if (icon) {
        [_ball setImage:icon forState:UIControlStateNormal];
        _ball.tintColor = [UIColor whiteColor];
    } else {
        [_ball setTitle:@"●" forState:UIControlStateNormal];
        [_ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _ball.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    }
    [_ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(ballDragged:)];
    [_ball addGestureRecognizer:pan];
    [rootVC.view addSubview:_ball];

    vlog_always(@"ui", @"ball created at (%.0f,%.0f) size %.0f", bx, by, bs);
}

- (void)ballTapped {
    if (_panel) { [self dismissPanel]; return; }
    [self showPanel];
}

- (void)ballDragged:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && _panel) {
        [self dismissPanel];
    }
    CGPoint t = [g translationInView:_win];
    CGPoint c = CGPointMake(_ball.center.x + t.x, _ball.center.y + t.y);
    CGFloat hw = _ball.frame.size.width / 2;
    CGFloat hh = _ball.frame.size.height / 2;
    c.x = MAX(hw, MIN(_win.bounds.size.width - hw, c.x));
    c.y = MAX(hh, MIN(_win.bounds.size.height - hh, c.y));
    _ball.center = c;
    [g setTranslation:CGPointZero inView:_win];
    [self updatePanelPosition];
}

- (void)updatePanelPosition {
    if (!_panel || !_ball || !_win) return;
    CGFloat w = _panel.frame.size.width;
    CGFloat h = _panel.frame.size.height;

    CGRect ballF = _ball.frame;
    CGFloat screenW = _win.bounds.size.width;
    CGFloat screenH = _win.bounds.size.height;
    CGFloat px = 5, py = 5;
    BOOL found = NO;

    CGFloat rightX = CGRectGetMaxX(ballF) + 8;
    if (rightX + w <= screenW - 5) {
        CGFloat ty = ballF.origin.y + ballF.size.height/2 - h/2;
        if (ty < 5) ty = 5;
        if (ty + h > screenH - 5) ty = screenH - h - 5;
        px = rightX; py = ty; found = YES;
    }
    if (!found) {
        CGFloat leftX = ballF.origin.x - w - 8;
        if (leftX >= 5) {
            CGFloat ty = ballF.origin.y + ballF.size.height/2 - h/2;
            if (ty < 5) ty = 5;
            if (ty + h > screenH - 5) ty = screenH - h - 5;
            px = leftX; py = ty; found = YES;
        }
    }
    if (!found) {
        CGFloat upY = ballF.origin.y - h - 8;
        if (upY >= 5) {
            CGFloat tx = ballF.origin.x + ballF.size.width/2 - w/2;
            if (tx < 5) tx = 5;
            if (tx + w > screenW - 5) tx = screenW - w - 5;
            px = tx; py = upY; found = YES;
        }
    }
    if (!found) {
        CGFloat downY = CGRectGetMaxY(ballF) + 8;
        if (downY + h <= screenH - 5) {
            CGFloat tx = ballF.origin.x + ballF.size.width/2 - w/2;
            if (tx < 5) tx = 5;
            if (tx + w > screenW - 5) tx = screenW - w - 5;
            px = tx; py = downY; found = YES;
        }
    }
    if (!found) {
        px = 5;
        CGFloat ballCY = ballF.origin.y + ballF.size.height/2;
        CGFloat topY = 5;
        CGFloat botY = screenH - h - 5;
        py = (fabs(ballCY - (topY + h/2)) > fabs(ballCY - (botY + h/2))) ? botY : topY;
    }
    _panel.frame = CGRectMake(px, py, w, h);
}

- (void)showPanel {
    CGFloat w = 240, pad = 10, tabH = 36, tabGap = 6, rowGap = 6;
    CGFloat controlH = 40 + rowGap + 48 + rowGap + 36;
    CGFloat timeH = 3 * 40 + 2 * rowGap;
    CGFloat contentH = MAX(controlH, timeH);
    CGFloat h = pad + tabH + tabGap + contentH + pad;

    _panel = [[VLHitThroughView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    _panel.backgroundColor = [UIColor colorWithRed:0.24 green:0.25 blue:0.27 alpha:0.96];
    _panel.layer.cornerRadius = 12;
    _panel.layer.masksToBounds = YES;

    CGFloat tabW = (w - 2 * pad - tabGap) / 2.0;
    _tabControlBtn = [self makeTab:@"控制" x:pad y:pad w:tabW h:tabH tag:0];
    _tabTimeBtn    = [self makeTab:@"时间" x:pad + tabW + tabGap y:pad w:tabW h:tabH tag:1];
    [_panel addSubview:_tabControlBtn];
    [_panel addSubview:_tabTimeBtn];

    CGFloat contentY = pad + tabH + tabGap;
    CGFloat contentW = w - 2 * pad;
    CGRect contentFrame = CGRectMake(pad, contentY, contentW, contentH);
    _pageControl = [self makePageWithFrame:contentFrame];
    _pageTime    = [self makePageWithFrame:contentFrame];

    [self fillControlPage];
    [self fillTimePage];

    [_panel addSubview:_pageControl];
    [_panel addSubview:_pageTime];
    [self switchToTab:_currentTab];

    [self updatePanelPosition];
    [_win.rootViewController.view addSubview:_panel];
}

- (UIView *)makePageWithFrame:(CGRect)frame {
    UIView *p = [[UIView alloc] initWithFrame:frame];
    p.backgroundColor = [UIColor clearColor];
    p.hidden = YES;
    return p;
}

- (UIButton *)makeTab:(NSString *)t x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h tag:(int)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    b.backgroundColor = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1];
    b.layer.cornerRadius = 7;
    b.tag = tag;
    [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)tabTapped:(UIButton *)sender {
    _currentTab = (int)sender.tag;
    [self switchToTab:_currentTab];
}

- (void)switchToTab:(int)tab {
    _pageControl.hidden = (tab != 0);
    _pageTime.hidden    = (tab != 1);
    UIColor *inactive = [UIColor colorWithRed:0.32 green:0.33 blue:0.35 alpha:1];
    UIColor *active   = [UIColor colorWithRed:0.58 green:0.59 blue:0.61 alpha:1];
    _tabControlBtn.backgroundColor = (tab == 0) ? active : inactive;
    _tabTimeBtn.backgroundColor    = (tab == 1) ? active : inactive;
}

- (UIButton *)makeBtnAt:(NSString *)t x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1];
    b.layer.cornerRadius = 8;
    return b;
}

- (void)fillControlPage {
    CGFloat w = _pageControl.bounds.size.width;
    CGFloat gap = 6;
    CGFloat y = 0;

    CGFloat row1H = 40;
    CGFloat halfW = (w - gap) / 2.0;
    UIButton *pick = [self makeBtnAt:@"选择视频" x:0 y:y w:halfW h:row1H];
    [pick addTarget:self action:@selector(pickVideo) forControlEvents:UIControlEventTouchUpInside];
    [_pageControl addSubview:pick];

    BOOL en = vplist_enabled();
    _toggleBtn = [self makeBtnAt:(en ? @"禁用相机" : @"启用相机")
                              x:halfW + gap y:y w:halfW h:row1H];
    [_toggleBtn addTarget:self action:@selector(toggleEnabled:)
         forControlEvents:UIControlEventTouchUpInside];
    [_pageControl addSubview:_toggleBtn];
    y += row1H + gap;

    CGFloat row2H = 48;
    CGFloat qW = (w - gap * 3) / 4.0;

    UIButton *rot = [self makeBtnAt:@"旋转" x:0 y:y w:qW h:row2H];
    rot.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [rot addTarget:self action:@selector(rotateTapped) forControlEvents:UIControlEventTouchUpInside];
    [_pageControl addSubview:rot];

    UIButton *bk = [self makeBtnAt:@"眨" x:qW + gap y:y w:qW h:row2H];
    bk.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [bk addTarget:self action:@selector(actionBlink) forControlEvents:UIControlEventTouchUpInside];
    [_pageControl addSubview:bk];

    UIButton *mh = [self makeBtnAt:@"嘴" x:(qW + gap) * 2 y:y w:qW h:row2H];
    mh.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [mh addTarget:self action:@selector(actionMouth) forControlEvents:UIControlEventTouchUpInside];
    [_pageControl addSubview:mh];

    UIButton *hd = [self makeBtnAt:@"头" x:(qW + gap) * 3 y:y w:qW h:row2H];
    hd.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [hd addTarget:self action:@selector(actionHead) forControlEvents:UIControlEventTouchUpInside];
    [_pageControl addSubview:hd];
    y += row2H + gap;

    CGFloat row3H = 36;
    UIButton *ex = [self makeBtnAt:@"退出动作" x:0 y:y w:w h:row3H];
    ex.backgroundColor = [UIColor colorWithRed:0.55 green:0.30 blue:0.30 alpha:1];
    [ex addTarget:self action:@selector(actionExit) forControlEvents:UIControlEventTouchUpInside];
    [_pageControl addSubview:ex];
}

- (void)fillTimePage {
    CGFloat w = _pageTime.bounds.size.width;
    CGFloat rowH = 40, gap = 6, y = 0;
    NSString *titles[3] = {@"眨时间", @"嘴时间", @"头时间"};
    SEL sels[3] = {@selector(timeBlink), @selector(timeMouth), @selector(timeHead)};
    for (int i = 0; i < 3; i++) {
        UIButton *b = [self makeBtnAt:titles[i] x:0 y:y w:w h:rowH];
        [b addTarget:self action:sels[i] forControlEvents:UIControlEventTouchUpInside];
        [_pageTime addSubview:b];
        y += rowH + gap;
    }
}

- (void)dismissPanel {
    [_panel removeFromSuperview];
    _panel = nil;
    _pageControl = nil;
    _pageTime = nil;
}

- (void)toggleEnabled:(UIButton *)b {
    BOOL en = vplist_enabled();
    vplist_set_enabled(!en);
    [b setTitle:(!en ? @"禁用相机" : @"启用相机") forState:UIControlStateNormal];
}

- (void)rotateTapped {
    vplist_update(^(NSMutableDictionary *d) {
        NSInteger old = [d[kManualRotKey] integerValue];
        NSInteger nv = ((old + 90) % 360 + 360) % 360;
        d[kManualRotKey] = @(nv);
    });
    vlog(@"ui", @"rotate tapped -> next");
}

- (void)pickVideo {
    PHPickerConfiguration *cfg = [PHPickerConfiguration new];
    cfg.selectionLimit = 1;
    cfg.filter = [PHPickerFilter videosFilter];
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self;
    [_win.rootViewController presentViewController:p animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    NSItemProvider *prov = results.firstObject.itemProvider;
    [prov loadFileRepresentationForTypeIdentifier:@"public.movie"
                               completionHandler:^(NSURL *url, NSError *err) {
        if (!url) { vlog(@"ui", @"pick failed: %@", err); return; }
        NSString *dst = kVideoPath;
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        NSError *cpErr = nil;
        if ([[NSFileManager defaultManager] copyItemAtPath:url.path toPath:dst error:&cpErr]) {
            vlog(@"ui", @"video copied");
            vplist_update(^(NSMutableDictionary *d) {
                d[kEnableKey] = @YES;
                NSNumber *oldTok = d[kActionToken];
                d[kActionToken] = @([oldTok longLongValue] + 1);
                d[kActionActive] = @0;
                d[kManualRotKey] = @0;
            });
        } else {
            vlog(@"ui", @"copy failed: %@", cpErr);
        }
    }];
}

- (void)triggerAction:(int)act {
    vplist_update(^(NSMutableDictionary *d) {
        NSNumber *oldTok = d[kActionToken];
        d[kActionToken] = @([oldTok longLongValue] + 1);
        d[kActionActive] = @(act);
    });
    vlog(@"ui", @"action triggered act=%d", act);
}

- (void)actionBlink { [self triggerAction:1]; }
- (void)actionMouth { [self triggerAction:2]; }
- (void)actionHead  { [self triggerAction:3]; }
- (void)actionExit  { [self triggerAction:0]; }

- (void)timeBlink { [self editTime:1]; }
- (void)timeMouth { [self editTime:2]; }
- (void)timeHead  { [self editTime:3]; }

- (void)editTime:(int)which {
    NSString *name = @""; NSString *usS = nil, *usE = nil, *sS = nil, *sE = nil;
    int64_t defS = 0, defE = 0;
    if (which == 1) { name = @"眨"; usS=kBlinkS_us; usE=kBlinkE_us; sS=kBlinkS_s; sE=kBlinkE_s;
        defS=kBlinkStartDefUs; defE=kBlinkEndDefUs; }
    else if (which == 2) { name = @"嘴"; usS=kMouthS_us; usE=kMouthE_us; sS=kMouthS_s; sE=kMouthE_s;
        defS=kMouthStartDefUs; defE=kMouthEndDefUs; }
    else { name = @"头"; usS=kHeadS_us; usE=kHeadE_us; sS=kHeadS_s; sE=kHeadE_s;
        defS=kHeadStartDefUs; defE=kHeadEndDefUs; }

    NSDictionary *pl = vplist_cached();
    double curS = vplist_get_us(pl, usS, sS, defS) / 1e6;
    double curE = vplist_get_us(pl, usE, sE, defE) / 1e6;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"设置「%@」时间", name]
        message:@"单位：秒" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"起始"; tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", curS];
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"结束"; tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", curE];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *act) {
        double s = [a.textFields[0].text doubleValue];
        double e = [a.textFields[1].text doubleValue];
        if (s < 0) s = 0;
        if (e <= s) e = s + 0.1;
        int64_t us = (int64_t)llround(s * 1e6);
        int64_t ue = (int64_t)llround(e * 1e6);
        vplist_update(^(NSMutableDictionary *d) {
            d[usS] = @(us); d[sS] = @((double)us / 1e6);
            d[usE] = @(ue); d[sE] = @((double)ue / 1e6);
        });
        vlog(@"ui", @"time saved %@ [%.3f-%.3f]", name, s, e);
    }]];
    [_win.rootViewController presentViewController:a animated:YES completion:nil];
}

@end

// ══════════════════════════════════════════════════════════════════════
//  入口
// ══════════════════════════════════════════════════════════════════════
__attribute__((used, constructor))
static void vcamLite_init(void) {
    @autoreleasepool {
        NSString *proc = [NSProcessInfo processInfo].processName;
        if ([proc isEqualToString:@"mediaserverd"]) {
            vlog_always(@"init", @"loaded in mediaserverd pid=%d build=v2.3.2", getpid());
            (void)[LiteCore shared];
            pthread_t th;
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            pthread_create(&th, &attr, install_thread, NULL);
            pthread_attr_destroy(&attr);
            return;
        }
        if ([proc isEqualToString:@"SpringBoard"]) {
            vlog_always(@"init", @"loaded in SpringBoard pid=%d build=v2.3.2", getpid());
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                [[VLBall shared] show];
            });
            return;
        }
    }
}
