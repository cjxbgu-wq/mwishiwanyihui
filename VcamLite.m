//
//  VcamLite.m — 融合版相机替换内核 v1.3.1（生产版）
//
//  融合来源：
//    - vcamplus-msd: 遍历所有子类 hook + 双路径缓存
//    - VcamMax:     三节点 hook + 自适应解码 + plist 同步 + 动作切片
//
//  修复历史：
//    P0-1   vplist_cached 用纳秒精度
//    P0-2   decoder 用 generation counter 保证 loop 唯一
//    P1-3   LiteCore 加 os_unfair_lock 保证多线程安全
//    P1-4   editTime 合并写 plist
//    v1.3-P0  LiteProcessor.transfer 的 memcpy 挪进锁内（防撕裂）
//    v1.3-P1  LiteCore.enabled 副作用挪出锁外（防锁内 dispatch）
//    v1.3.1   显式 #import <VideoToolbox/VideoToolbox.h>（Theos 编译必需）
//    v1.3.1   install_thread(void *arg) 加参数名（C99 兼容）
//
//  精简掉：卡密 / 拍照 / 反检测 / 三指手势
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

// ══════════════════════════════════════════════════════════════════════
//  常量
// ══════════════════════════════════════════════════════════════════════
static NSString *const kVideoPath = @"/var/mobile/Media/DCIM/vcam.mp4";
static NSString *const kPlistPath = @"/var/mobile/Media/DCIM/vc.plist";

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

// ══════════════════════════════════════════════════════════════════════
//  日志（按 tag 限流）
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

// ══════════════════════════════════════════════════════════════════════
//  plist 缓存层
//  P0-1：st_mtimespec 纳秒精度
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
        m = (double)st.st_mtimespec.tv_sec
          + (double)st.st_mtimespec.tv_nsec / 1e9;
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
//  LiteVideoDecoder — 自适应 fps 解码 + 动作切片 + 冻结
//  P0-2：generation counter 保证旧 loop 立即退出
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

- (void)seekToActionStartUs:(int64_t)startUs endUs:(int64_t)endUs;
- (void)exitAction;

@property (nonatomic, readonly) VLState state;
@property (nonatomic, readonly) int currentAction;
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
    _Atomic int _curAction;
    _Atomic int64_t _actionStartUs;
    _Atomic int64_t _actionEndUs;
    _Atomic int _actionDirty;
    double _fps;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _q = dispatch_queue_create("vlite.decoder", DISPATCH_QUEUE_SERIAL);
        _frameLock = OS_UNFAIR_LOCK_INIT;
        _fps = 30.0;
        atomic_store(&_state, VL_STATE_LOOP);
        atomic_store(&_gen, 0);
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

- (VLState)state { return (VLState)atomic_load(&_state); }
- (int)currentAction { return atomic_load(&_curAction); }

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
    atomic_store(&_curAction, 0);
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

            double nominal = track.nominalFrameRate;
            if (nominal > 1.0 && nominal < 240.0) _fps = nominal;
            NSTimeInterval frameInterval = 1.0 / _fps;

            int64_t localStart = 0, localEnd = 0;
            if (st == VL_STATE_ACTION) {
                localStart = atomic_load(&_actionStartUs);
                localEnd   = atomic_load(&_actionEndUs);

                CMTime ad = asset.duration;
                double durSec = CMTimeGetSeconds(ad);
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
                reader.timeRange = CMTimeRangeMake(start,
                    CMTimeSubtract(end, start));
                vlog(@"action", @"range [%.3fs-%.3fs]",
                     localStart / 1e6, localEnd / 1e6);
            }

            if (![reader startReading]) { sleep(1); continue; }

            NSTimeInterval nextTick = CACurrentMediaTime();
            while (atomic_load(&_running) &&
                   atomic_load(&_gen) == myGen &&
                   reader.status == AVAssetReaderStatusReading) {
                if (atomic_load(&_gen) != myGen) break;
                if (atomic_load(&_state) != (int)st ||
                    atomic_load(&_actionDirty)) {
                    break;
                }

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
            if (curState == VL_STATE_ACTION) {
                atomic_store(&_state, VL_STATE_FROZEN);
                vlog(@"action", @"done -> frozen");
            }
        }
    }
    vlog(@"decoder", @"loop exit gen=%d", myGen);
}

@end

// ══════════════════════════════════════════════════════════════════════
//  LiteProcessor — 双路径像素替换
//  v1.3-P0：memcpy 挪进锁内，防止并发重建时读到半新半旧的缓存
// ══════════════════════════════════════════════════════════════════════
@interface LiteCache : NSObject
@property (nonatomic, assign) CVPixelBufferRef buf;
@property (nonatomic, assign) uint64_t srcID;
@end
@implementation LiteCache
- (void)dealloc { if (_buf) CVPixelBufferRelease(_buf); }
@end

@interface LiteProcessor : NSObject
- (BOOL)transfer:(CVPixelBufferRef)src srcID:(uint64_t)srcID into:(CVPixelBufferRef)dst;
@end

@implementation LiteProcessor {
    VTPixelTransferSessionRef _sess;
    NSRecursiveLock *_lock;
    NSMutableDictionary<NSString *, LiteCache *> *_caches;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSRecursiveLock new];
        _caches = [NSMutableDictionary new];
        OSStatus s = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_sess);
        if (s != noErr || !_sess) { _sess = NULL; return self; }
        CFStringRef *pRT = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_RealTime");
        CFStringRef *pSM = (CFStringRef *)dlsym(RTLD_DEFAULT, "kVTPixelTransferPropertyKey_ScalingMode");
        if (pRT && *pRT) VTSessionSetProperty(_sess, *pRT, kCFBooleanTrue);
        if (pSM && *pSM) VTSessionSetProperty(_sess, *pSM, CFSTR("Trim"));
    }
    return self;
}

- (void)dealloc {
    if (_sess) { VTPixelTransferSessionInvalidate(_sess); CFRelease(_sess); }
}

static BOOL vmemcpy(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (CVPixelBufferGetPixelFormatType(src) != CVPixelBufferGetPixelFormatType(dst)) return NO;
    if (CVPixelBufferGetWidth(src)  != CVPixelBufferGetWidth(dst))  return NO;
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

- (BOOL)transfer:(CVPixelBufferRef)src srcID:(uint64_t)srcID into:(CVPixelBufferRef)dst {
    if (!src || !dst || !_sess) return NO;
    size_t dw = CVPixelBufferGetWidth(dst);
    size_t dh = CVPixelBufferGetHeight(dst);
    OSType fmt = CVPixelBufferGetPixelFormatType(dst);
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
        OSStatus s = VTPixelTransferSessionTransferImage(_sess, src, c.buf);
        if (s == noErr) c.srcID = srcID;
        else { [_lock unlock]; return NO; }
    }

    BOOL ok = vmemcpy(c.buf, dst);
    [_lock unlock];
    return ok;
}

@end

// ══════════════════════════════════════════════════════════════════════
//  LiteCore — mediaserverd 侧协调器
// ══════════════════════════════════════════════════════════════════════
@interface LiteCore : NSObject
+ (instancetype)shared;
- (BOOL)enabled;
- (void)replaceInPlace:(CMSampleBufferRef)sb;
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
        _lastCheck = 0;
        _enabledCache = NO;
        _lastToken = -1;
        _actionInited = NO;
        _coreLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
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
    if (needExit)   { [_dec exitAction]; vlog(@"action", @"EXIT"); }
}

- (void)replaceInPlace:(CMSampleBufferRef)sb {
    if (!sb) return;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (!fd || CMFormatDescriptionGetMediaType(fd) != kCMMediaType_Video) return;

    CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(sb);
    if (!dst) return;

    OSType fmt = CVPixelBufferGetPixelFormatType(dst);
    if (fmt == 0x2D387630 || fmt == 0x2D386630 ||
        fmt == 0x2D787630 || fmt == 0x2D786630 || fmt == 0x2D343230) return;

    uint64_t srcID = [_dec latestFrameID];
    if (srcID == 0) return;
    CVPixelBufferRef src = [_dec latestFrameRetained];
    if (!src) return;

    [_proc transfer:src srcID:srcID into:dst];
    CVPixelBufferRelease(src);
}

@end

// ══════════════════════════════════════════════════════════════════════
//  Hook 层
// ══════════════════════════════════════════════════════════════════════

static NSMutableDictionary<NSValue *, NSValue *> *gOrigIMP = nil;
static _Atomic int gInstalled = 0;

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

static IMP orig_imp_for(Class cls) {
    if (!gOrigIMP) return NULL;
    @synchronized(gOrigIMP) {
        NSValue *v = gOrigIMP[[NSValue valueWithPointer:(__bridge const void *)cls]];
        return v ? (IMP)[v pointerValue] : NULL;
    }
}

static IMP orig_imp_for_instance(id _self) {
    Class c = object_getClass(_self);
    while (c) {
        IMP f = orig_imp_for(c);
        if (f) return f;
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void vl_emit_body(id _self, SEL _cmd, CMSampleBufferRef sb) {
    @autoreleasepool {
        if (sb && [LiteCore.shared enabled]) {
            @try {
                [LiteCore.shared checkActionFromPlist];
                SEL mtSel = sel_registerName("mediaType");
                BOOL isVideo = YES;
                if ([_self respondsToSelector:mtSel]) {
                    uint32_t mt = ((uint32_t(*)(id,SEL))objc_msgSend)(_self, mtSel);
                    if (mt != 'vide') isVideo = NO;
                }
                if (isVideo) [LiteCore.shared replaceInPlace:sb];
            } @catch (NSException *e) { vlog(@"emit", @"exc: %@", e); }
        }
    }
    IMP orig = orig_imp_for_instance(_self);
    if (orig) ((void(*)(id,SEL,CMSampleBufferRef))orig)(_self, _cmd, sb);
}

static void vl_render_body(id _self, SEL _cmd, CMSampleBufferRef sb, id input) {
    @autoreleasepool {
        if (sb && [LiteCore.shared enabled]) {
            @try { [LiteCore.shared replaceInPlace:sb]; }
            @catch (NSException *e) { vlog(@"render", @"exc: %@", e); }
        }
    }
    IMP orig = orig_imp_for_instance(_self);
    if (orig) ((void(*)(id,SEL,CMSampleBufferRef,id))orig)(_self, _cmd, sb, input);
}

static BOOL hook_class_method(Class cls, SEL sel, IMP newImp, BOOL requireOwns) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (requireOwns && !class_owns_method(cls, sel)) return NO;
    IMP orig = method_getImplementation(m);
    if (!gOrigIMP) gOrigIMP = [NSMutableDictionary new];
    @synchronized(gOrigIMP) {
        gOrigIMP[[NSValue valueWithPointer:(__bridge const void *)cls]] =
            [NSValue valueWithPointer:(const void *)orig];
    }
    method_setImplementation(m, newImp);
    return YES;
}

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

static void install_hooks(void) {
    if (atomic_exchange(&gInstalled, 1)) return;
    int n1 = hook_all_subclasses("BWNodeOutput",
                @selector(emitSampleBuffer:), (IMP)vl_emit_body);
    int n2 = hook_all_subclasses("BWStillImageScalerNode",
                @selector(renderSampleBuffer:forInput:), (IMP)vl_render_body);
    int n3 = hook_all_subclasses("BWPhotoEncoderNode",
                @selector(renderSampleBuffer:forInput:), (IMP)vl_render_body);
    vlog(@"hook", @"emit=%d scaler=%d encoder=%d", n1, n2, n3);
}

// v1.3.1 修复：C99 不允许匿名参数
static void *install_thread(void *arg) {
    (void)arg;
    while (1) {
        if (objc_getClass("BWNodeOutput")) { install_hooks(); return NULL; }
        usleep(500 * 1000);
    }
    return NULL;
}

// ══════════════════════════════════════════════════════════════════════
//  UI 层（SpringBoard 侧）
// ══════════════════════════════════════════════════════════════════════

@interface VLWindow : UIWindow @end
@implementation VLWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface VLBall : NSObject <PHPickerViewControllerDelegate>
+ (instancetype)shared;
- (void)show;
- (void)toggle;
@end

@implementation VLBall {
    VLWindow *_win;
    UIButton *_ball;
    UIView *_panel;
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

- (void)toggle {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_win) {
            [self->_win removeFromSuperview];
            self->_win = nil; self->_ball = nil; self->_panel = nil;
        } else {
            [self createWindow];
        }
    });
}

- (void)createWindow {
    CGRect screen = [UIScreen mainScreen].bounds;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (scene) _win = [[VLWindow alloc] initWithWindowScene:scene];
    else _win = [[VLWindow alloc] initWithFrame:screen];
    _win.frame = screen;
    _win.windowLevel = UIWindowLevelAlert + 100;
    _win.backgroundColor = [UIColor clearColor];
    _win.rootViewController = [UIViewController new];
    _win.hidden = NO;

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
    }
    [_ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(ballDragged:)];
    [_ball addGestureRecognizer:pan];
    [_win addSubview:_ball];

    vlog(@"ui", @"ball shown");
}

- (void)ballTapped {
    if (_panel) { [self dismissPanel]; return; }
    [self showPanel];
}

- (void)ballDragged:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:_win];
    CGPoint c = CGPointMake(_ball.center.x + t.x, _ball.center.y + t.y);
    CGFloat hw = _ball.frame.size.width / 2;
    CGFloat hh = _ball.frame.size.height / 2;
    c.x = MAX(hw, MIN(_win.frame.size.width - hw, c.x));
    c.y = MAX(hh, MIN(_win.frame.size.height - hh, c.y));
    _ball.center = c;
    [g setTranslation:CGPointZero inView:_win];
}

- (void)showPanel {
    CGFloat w = 240;
    CGFloat pad = 10;
    CGFloat rowH = 38;
    CGFloat gap = 6;
    CGFloat h = pad + rowH + gap
              + rowH + gap
              + 16 + gap
              + rowH + gap
              + rowH + gap
              + rowH + gap
              + rowH + gap
              + 16 + gap
              + 3 * (rowH + gap)
              + pad;

    CGFloat px = _ball.frame.origin.x - w - 8;
    if (px < 5) px = CGRectGetMaxX(_ball.frame) + 8;
    if (px + w > _win.frame.size.width - 5) px = 5;
    CGFloat py = _ball.center.y - h / 2;
    if (py < 5) py = 5;
    if (py + h > _win.frame.size.height - 5) py = _win.frame.size.height - h - 5;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(px, py, w, h)];
    _panel.backgroundColor = [UIColor colorWithRed:0.24 green:0.25 blue:0.27 alpha:0.96];
    _panel.layer.cornerRadius = 12;
    _panel.layer.masksToBounds = YES;

    CGFloat y = pad;

    UIButton *pick = [self makeBtn:@"选择视频" y:y];
    [pick addTarget:self action:@selector(pickVideo) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:pick]; y += rowH + gap;

    BOOL en = vplist_enabled();
    UIButton *tog = [self makeBtn:(en ? @"禁用相机" : @"启用相机") y:y];
    [tog addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:tog]; y += rowH + gap;

    UILabel *l1 = [self makeLabel:@"动作" y:y];
    [_panel addSubview:l1]; y += 16 + gap;

    UIButton *bk = [self makeBtn:@"眨" y:y];
    [bk addTarget:self action:@selector(actionBlink) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:bk]; y += rowH + gap;

    UIButton *mh = [self makeBtn:@"嘴" y:y];
    [mh addTarget:self action:@selector(actionMouth) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:mh]; y += rowH + gap;

    UIButton *hd = [self makeBtn:@"头" y:y];
    [hd addTarget:self action:@selector(actionHead) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:hd]; y += rowH + gap;

    UIButton *ex = [self makeBtn:@"退出动作" y:y];
    ex.backgroundColor = [UIColor colorWithRed:0.55 green:0.30 blue:0.30 alpha:1];
    [ex addTarget:self action:@selector(actionExit) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:ex]; y += rowH + gap;

    UILabel *l2 = [self makeLabel:@"时间设置" y:y];
    [_panel addSubview:l2]; y += 16 + gap;

    UIButton *t1 = [self makeBtn:@"眨时间" y:y];
    [t1 addTarget:self action:@selector(timeBlink) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:t1]; y += rowH + gap;

    UIButton *t2 = [self makeBtn:@"嘴时间" y:y];
    [t2 addTarget:self action:@selector(timeMouth) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:t2]; y += rowH + gap;

    UIButton *t3 = [self makeBtn:@"头时间" y:y];
    [t3 addTarget:self action:@selector(timeHead) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:t3];

    [_win addSubview:_panel];
}

- (UILabel *)makeLabel:(NSString *)t y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 216, 14)];
    l.text = t;
    l.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    l.font = [UIFont systemFontOfSize:11];
    return l;
}

- (UIButton *)makeBtn:(NSString *)t y:(CGFloat)y {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(10, y, 220, 38);
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = [UIColor colorWithRed:0.42 green:0.43 blue:0.45 alpha:1];
    b.layer.cornerRadius = 8;
    return b;
}

- (void)dismissPanel {
    [_panel removeFromSuperview];
    _panel = nil;
}

- (void)toggleEnabled:(UIButton *)b {
    BOOL en = vplist_enabled();
    vplist_set_enabled(!en);
    [b setTitle:(!en ? @"禁用相机" : @"启用相机") forState:UIControlStateNormal];
}

- (void)pickVideo {
    PHPickerConfiguration *cfg = [PHPickerConfiguration new];
    cfg.selectionLimit = 1;
    cfg.filter = [PHPickerFilter videosFilter];
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self;
    UIViewController *root = _win.rootViewController;
    [root presentViewController:p animated:YES completion:nil];
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
    NSString *name = @"";
    NSString *usS = nil, *usE = nil, *sS = nil, *sE = nil;
    int64_t defS = 0, defE = 0;
    if (which == 1) {
        name = @"眨"; usS = kBlinkS_us; usE = kBlinkE_us; sS = kBlinkS_s; sE = kBlinkE_s;
        defS = kBlinkStartDefUs; defE = kBlinkEndDefUs;
    } else if (which == 2) {
        name = @"嘴"; usS = kMouthS_us; usE = kMouthE_us; sS = kMouthS_s; sE = kMouthE_s;
        defS = kMouthStartDefUs; defE = kMouthEndDefUs;
    } else {
        name = @"头"; usS = kHeadS_us; usE = kHeadE_us; sS = kHeadS_s; sE = kHeadE_s;
        defS = kHeadStartDefUs; defE = kHeadEndDefUs;
    }

    NSDictionary *pl = vplist_cached();
    double curS = vplist_get_us(pl, usS, sS, defS) / 1e6;
    double curE = vplist_get_us(pl, usE, sE, defE) / 1e6;

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"设置「%@」时间", name]
        message:@"单位：秒"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"起始";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.3f", curS];
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"结束";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
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
            d[usS] = @(us);
            d[sS]  = @((double)us / 1e6);
            d[usE] = @(ue);
            d[sE]  = @((double)ue / 1e6);
        });
        vlog(@"ui", @"time saved %@ [%.3f-%.3f]", name, s, e);
    }]];
    [_win.rootViewController presentViewController:a animated:YES completion:nil];
}

@end

// ══════════════════════════════════════════════════════════════════════
//  入口
// ══════════════════════════════════════════════════════════════════════
__attribute__((constructor))
static void vcamLite_init(void) {
    @autoreleasepool {
        NSString *proc = [NSProcessInfo processInfo].processName;

        if ([proc isEqualToString:@"mediaserverd"]) {
            vlog(@"init", @"loaded in mediaserverd");
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
            vlog(@"init", @"loaded in SpringBoard");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                [[VLBall shared] show];
            });
            return;
        }
    }
}
