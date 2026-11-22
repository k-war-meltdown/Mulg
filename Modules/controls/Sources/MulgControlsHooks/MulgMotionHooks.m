//
//  MulgMotionHooks.m
//  controls module: answers the game's Core Motion requests from the virtual gyro
//  (PLAN.md §14.3). Extends upstream's only motion hook, the update-rate limit.
//
//  While emulation is on, CMMotionManager reports a gyroscope and device motion, delivers
//  samples at the interval the game asked for, and answers polling (gyroData, deviceMotion).
//  While it is off, every call passes through to Core Motion.
//
//  Samples are CMGyroData / CMDeviceMotion subclasses whose getters return the virtual values.
//

#import "MulgControlsHooks.h"
#include <TargetConditionals.h>
#include <math.h>
#include <stdint.h>
#import <objc/runtime.h>

#if TARGET_OS_IPHONE

#import <CoreMotion/CoreMotion.h>
#import <MulgEngineHooks.h>
#import <objc/runtime.h>
#include <math.h>

// MARK: Sample classes

@interface MulgGyroData : CMGyroData
@property (nonatomic) CMRotationRate mulgRate;
@property (nonatomic) NSTimeInterval mulgTimestamp;
@end

@implementation MulgGyroData
- (CMRotationRate)rotationRate { return self.mulgRate; }
- (NSTimeInterval)timestamp { return self.mulgTimestamp; }
@end

@interface MulgAttitude : CMAttitude
@property (nonatomic) CMQuaternion mulgQuaternion;
@end

@implementation MulgAttitude
- (CMQuaternion)quaternion { return self.mulgQuaternion; }

- (id)copyWithZone:(NSZone *)zone {
    MulgAttitude *copy = [[[self class] allocWithZone:zone] init];
    copy.mulgQuaternion = self.mulgQuaternion;
    return copy;
}

- (void)multiplyByInverseOfAttitude:(CMAttitude *)attitude {
    CMQuaternion a = self.mulgQuaternion, b = attitude.quaternion;
    double norm = b.x * b.x + b.y * b.y + b.z * b.z + b.w * b.w;
    if (!isfinite(norm) || norm <= 0) return;
    b = (CMQuaternion){ -b.x / norm, -b.y / norm, -b.z / norm, b.w / norm };
    self.mulgQuaternion = (CMQuaternion){
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
    };
}

- (CMRotationMatrix)rotationMatrix {
    CMQuaternion q = self.mulgQuaternion;
    CMRotationMatrix m;
    m.m11 = 1 - 2 * (q.y * q.y + q.z * q.z);
    m.m12 = 2 * (q.x * q.y + q.w * q.z);
    m.m13 = 2 * (q.x * q.z - q.w * q.y);
    m.m21 = 2 * (q.x * q.y - q.w * q.z);
    m.m22 = 1 - 2 * (q.x * q.x + q.z * q.z);
    m.m23 = 2 * (q.y * q.z + q.w * q.x);
    m.m31 = 2 * (q.x * q.z + q.w * q.y);
    m.m32 = 2 * (q.y * q.z - q.w * q.x);
    m.m33 = 1 - 2 * (q.x * q.x + q.y * q.y);
    return m;
}

- (double)roll {
    CMQuaternion q = self.mulgQuaternion;
    return atan2(2 * (q.w * q.y - q.x * q.z), 1 - 2 * (q.x * q.x + q.y * q.y));
}

- (double)pitch {
    CMQuaternion q = self.mulgQuaternion;
    double value = 2 * (q.w * q.x + q.y * q.z);
    return asin(fmax(-1, fmin(1, value)));
}

- (double)yaw {
    CMQuaternion q = self.mulgQuaternion;
    return atan2(2 * (q.w * q.z - q.x * q.y), 1 - 2 * (q.x * q.x + q.z * q.z));
}
@end

@interface MulgDeviceMotion : CMDeviceMotion
@property (nonatomic, strong) MulgAttitude *mulgAttitude;
@property (nonatomic) CMRotationRate mulgRate;
@property (nonatomic) CMAcceleration mulgGravity;
@property (nonatomic) NSTimeInterval mulgTimestamp;
@end

@implementation MulgDeviceMotion
- (CMAttitude *)attitude { return self.mulgAttitude; }
- (CMRotationRate)rotationRate { return self.mulgRate; }
- (CMAcceleration)gravity { return self.mulgGravity; }
- (CMAcceleration)userAcceleration { return (CMAcceleration){ 0, 0, 0 }; }
- (CMCalibratedMagneticField)magneticField {
    return (CMCalibratedMagneticField){ { 0, 0, 0 }, CMMagneticFieldCalibrationAccuracyUncalibrated };
}
- (double)heading { return -1; }
- (NSTimeInterval)timestamp { return self.mulgTimestamp; }
@end

static MulgGyroData *make_gyro(MulgMotionSample sample) {
    MulgGyroData *data = [[MulgGyroData alloc] init];
    data.mulgRate = (CMRotationRate){ sample.rateX, sample.rateY, sample.rateZ };
    data.mulgTimestamp = NSProcessInfo.processInfo.systemUptime;
    return data;
}

static MulgDeviceMotion *make_motion(MulgMotionSample sample) {
    MulgAttitude *attitude = [[MulgAttitude alloc] init];
    attitude.mulgQuaternion = (CMQuaternion){ sample.qx, sample.qy, sample.qz, sample.qw };
    MulgDeviceMotion *motion = [[MulgDeviceMotion alloc] init];
    motion.mulgAttitude = attitude;
    motion.mulgRate = (CMRotationRate){ sample.rateX, sample.rateY, sample.rateZ };
    motion.mulgGravity = (CMAcceleration){ sample.gravityX, sample.gravityY, sample.gravityZ };
    motion.mulgTimestamp = NSProcessInfo.processInfo.systemUptime;
    return motion;
}

#endif

// MARK: The integrator clock

/// One clock advances the integrator for all consumers, so two consumers never split the
/// same mouse movement between them.
static dispatch_source_t mulg_clock;
static int mulg_clock_users = 0;
static NSLock *mulg_clock_lock;
static uint64_t mulg_clock_generation; // guarded by mulg_clock_lock
static const double kClockInterval = 1.0 / 240.0;

static void clock_retain(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mulg_clock_lock = [NSLock new]; });
    [mulg_clock_lock lock];
    if (mulg_clock_users++ == 0) {
        uint64_t generation = ++mulg_clock_generation;
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        mulg_clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(mulg_clock, DISPATCH_TIME_NOW, (uint64_t)(kClockInterval * NSEC_PER_SEC),
                                  NSEC_PER_MSEC / 2);
        __block uint64_t last = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        dispatch_source_set_event_handler(mulg_clock, ^{
            // Cancellation does not drain an already queued event. An old clock
            // must not consume the replacement clock's pending mouse rotation.
            [mulg_clock_lock lock];
            if (mulg_clock_users > 0 && generation == mulg_clock_generation) {
                uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                mulg_motion_step((double)(now - last) / 1e9);
                last = now;
            }
            [mulg_clock_lock unlock];
        });
        dispatch_resume(mulg_clock);
    }
    [mulg_clock_lock unlock];
}

static void clock_release(void) {
    [mulg_clock_lock lock];
    if (mulg_clock_users > 0 && --mulg_clock_users == 0 && mulg_clock != nil) {
        ++mulg_clock_generation;
        dispatch_source_cancel(mulg_clock);
        mulg_clock = nil;
    }
    [mulg_clock_lock unlock];
}

// MARK: Per-manager delivery

// Per-manager state is stored atomically: timers are cancelled from cleanup and timer threads while the
// game reads isGyroActive / isDeviceMotionActive and starts or stops updates on its own thread.

static char kGyroTimerKey;
static char kMotionTimerKey;
static char kGyroActiveKey;
static char kMotionActiveKey;

/// One delivery timer, kept on its manager. Freeing it cancels the timer and releases the
/// clock, so a manager the game frees without stopping it stops too.
@interface MulgMotionTimer : NSObject
@property (nonatomic, strong) dispatch_source_t source;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) id sample;
@property (nonatomic) BOOL pending;
@property (nonatomic) BOOL cancelled;
@property (nonatomic, weak) id manager;
@property (nonatomic) void *activeKey;
@property (nonatomic) void *timerKey;
- (void)cancel;
@end

static NSHashTable<MulgMotionTimer *> *motion_timers;

@implementation MulgMotionTimer
- (void)cancel {
    [_lock lock];
    BOOL first = !_cancelled;
    _cancelled = YES;
    _sample = nil;
    [_lock unlock];
    if (first) {
        id manager = _manager;
        if (manager != nil) {
            @synchronized (manager) {
                if (objc_getAssociatedObject(manager, _timerKey) == self)
                    objc_setAssociatedObject(manager, _activeKey, nil, OBJC_ASSOCIATION_RETAIN);
            }
        }
        dispatch_source_cancel(_source); clock_release();
    }
}
- (void)dealloc { [self cancel]; }
@end

void mulg_motion_stop_delivery(void) {
    NSArray *timers;
    @synchronized ([MulgMotionTimer class]) { timers = motion_timers.allObjects; }
    for (MulgMotionTimer *timer in timers) [timer cancel];
}

static void stop_timer(id manager, void *key) {
    @synchronized (manager) {
        [((MulgMotionTimer *)objc_getAssociatedObject(manager, key)) cancel];
        objc_setAssociatedObject(manager, key, nil, OBJC_ASSOCIATION_RETAIN);
    }
}

/// Delivers samples to `handler` on `queue` every `interval` seconds (at least 1/240 s).
static void start_timer(id manager, void *key, NSTimeInterval interval,
                        NSOperationQueue *queue, id (^capture)(void), void (^deliver)(id)) {
    @synchronized (manager) {
        stop_timer(manager, key);
        clock_retain();
        // No interval set: 60 Hz. Faster than the clock gains nothing, so the clock rate is the floor.
        // Do not convert infinity or an oversized seconds value to integer nanoseconds.
        // Preserve finite long intervals up to dispatch_time's signed delta limit.
        NSTimeInterval period = isfinite(interval) && interval > 0 ? fmax(interval, kClockInterval) : 1.0 / 60.0;
        period = fmin(period, (double)(INT64_MAX / NSEC_PER_SEC));
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(period * NSEC_PER_SEC)),
                                  (uint64_t)(period * NSEC_PER_SEC), NSEC_PER_MSEC);
        MulgMotionTimer *owner = [[MulgMotionTimer alloc] init];
        owner.source = timer;
        owner.lock = [NSLock new];
        owner.manager = manager;
        owner.activeKey = key == &kGyroTimerKey ? &kGyroActiveKey : &kMotionActiveKey;
        owner.timerKey = key;
        __weak MulgMotionTimer *weakOwner = owner;
        dispatch_source_set_event_handler(timer, ^{
            MulgMotionTimer *owner = weakOwner;
            if (owner == nil || !mulg_motion_is_enabled()) return;
            id sample = capture(); // Snapshot on the timer, never when a stalled game queue resumes.
            [owner.lock lock];
            if (owner.cancelled) { [owner.lock unlock]; return; }
            owner.sample = sample;
            if (owner.pending) { [owner.lock unlock]; return; }
            owner.pending = YES;
            [owner.lock unlock];
            void (^operation)(void) = ^{
                MulgMotionTimer *owner = weakOwner;
                if (owner == nil) return;
                [owner.lock lock];
                id latest = owner.sample;
                BOOL valid = !owner.cancelled && mulg_motion_is_enabled();
                owner.sample = nil;
                [owner.lock unlock];
                if (valid) deliver(latest);
                [owner.lock lock]; owner.pending = NO; [owner.lock unlock];
            };
            if (queue != nil) {
                [queue addOperationWithBlock:operation];
            } else {
                operation();
            }
        });
        @synchronized ([MulgMotionTimer class]) {
            if (motion_timers == nil) motion_timers = [NSHashTable weakObjectsHashTable];
            [motion_timers addObject:owner];
        }
        objc_setAssociatedObject(manager, key, owner, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(manager, owner.activeKey, @YES, OBJC_ASSOCIATION_RETAIN);
        dispatch_resume(timer);
    }
}

// MARK: Replacements

#if TARGET_OS_IPHONE

typedef BOOL (*BoolGetter)(id, SEL);
typedef id (*ObjectGetter)(id, SEL);
typedef void (*Action)(id, SEL);
typedef void (*StartWithQueue)(id, SEL, NSOperationQueue *, id);
typedef void (*StartWithFrameQueue)(id, SEL, CMAttitudeReferenceFrame, NSOperationQueue *, id);
typedef void (*StartWithFrame)(id, SEL, CMAttitudeReferenceFrame);

static IMP previous_gyro_available, previous_motion_available, previous_gyro_active, previous_motion_active;
static IMP previous_start_gyro_queue, previous_start_gyro, previous_gyro_data, previous_stop_gyro;
static IMP previous_start_motion_queue, previous_start_motion_frame_queue, previous_start_motion;
static IMP previous_start_motion_frame, previous_device_motion, previous_stop_motion;
static IMP previous_reference_frames;
static IMP previous_reference_frame;

#define EMULATING() mulg_motion_is_enabled()

static CMAttitudeReferenceFrame mulg_reference_frames(id self, SEL selector) {
    return EMULATING() ? CMAttitudeReferenceFrameXArbitraryZVertical
        : ((CMAttitudeReferenceFrame (*)(id, SEL))previous_reference_frames)(self, selector);
}

static CMAttitudeReferenceFrame mulg_reference_frame(id self, SEL selector) {
    return EMULATING() ? CMAttitudeReferenceFrameXArbitraryZVertical
        : ((CMAttitudeReferenceFrame (*)(id, SEL))previous_reference_frame)(self, selector);
}

static BOOL mulg_gyro_available(CMMotionManager *self, SEL _cmd) {
    return EMULATING() ? YES : ((BoolGetter)previous_gyro_available)(self, _cmd);
}

static BOOL mulg_motion_available(CMMotionManager *self, SEL _cmd) {
    return EMULATING() ? YES : ((BoolGetter)previous_motion_available)(self, _cmd);
}

static BOOL mulg_gyro_active(CMMotionManager *self, SEL _cmd) {
    return EMULATING() ? objc_getAssociatedObject(self, &kGyroActiveKey) != nil
                       : ((BoolGetter)previous_gyro_active)(self, _cmd);
}

static BOOL mulg_motion_active(CMMotionManager *self, SEL _cmd) {
    return EMULATING() ? objc_getAssociatedObject(self, &kMotionActiveKey) != nil
                       : ((BoolGetter)previous_motion_active)(self, _cmd);
}

static void mulg_start_gyro_queue(CMMotionManager *self, SEL _cmd, NSOperationQueue *queue, CMGyroHandler handler) {
    if (!EMULATING()) {
        ((StartWithQueue)previous_start_gyro_queue)(self, _cmd, queue, handler);
        return;
    }
    objc_setAssociatedObject(self, &kGyroActiveKey, @YES, OBJC_ASSOCIATION_RETAIN);
    CMGyroHandler copy = [handler copy];
    start_timer(self, &kGyroTimerKey, self.gyroUpdateInterval, queue, ^id{
        return make_gyro(mulg_motion_latest());
    }, ^(id sample) {
        if (copy) copy(sample, nil);
    });
}

static void mulg_start_gyro(CMMotionManager *self, SEL _cmd) {
    if (!EMULATING()) {
        ((Action)previous_start_gyro)(self, _cmd);
        return;
    }
    // Pull mode: the clock keeps the integrator running; gyroData reads the latest sample.
    if (objc_getAssociatedObject(self, &kGyroActiveKey) == nil) {
        objc_setAssociatedObject(self, &kGyroActiveKey, @YES, OBJC_ASSOCIATION_RETAIN);
        start_timer(self, &kGyroTimerKey, 1.0, nil, ^id{ return nil; }, ^(id sample) {});
    }
}

static id mulg_gyro_data(CMMotionManager *self, SEL _cmd) {
    if (!EMULATING()) {
        return ((ObjectGetter)previous_gyro_data)(self, _cmd);
    }
    return objc_getAssociatedObject(self, &kGyroActiveKey) != nil ? make_gyro(mulg_motion_latest()) : nil;
}

static void mulg_stop_gyro(CMMotionManager *self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kGyroActiveKey) != nil) {
        objc_setAssociatedObject(self, &kGyroActiveKey, nil, OBJC_ASSOCIATION_RETAIN);
        stop_timer(self, &kGyroTimerKey);
        return;
    }
    ((Action)previous_stop_gyro)(self, _cmd);
}

static void start_motion(CMMotionManager *self, NSOperationQueue *queue, CMDeviceMotionHandler handler) {
    objc_setAssociatedObject(self, &kMotionActiveKey, @YES, OBJC_ASSOCIATION_RETAIN);
    if (handler == nil) {
        start_timer(self, &kMotionTimerKey, 1.0, nil, ^id{ return nil; }, ^(id sample) {});
        return;
    }
    CMDeviceMotionHandler copy = [handler copy];
    start_timer(self, &kMotionTimerKey, self.deviceMotionUpdateInterval, queue, ^id{
        return make_motion(mulg_motion_latest());
    }, ^(id sample) {
        copy(sample, nil);
    });
}

static void mulg_start_motion_queue(CMMotionManager *self, SEL _cmd, NSOperationQueue *queue,
                                    CMDeviceMotionHandler handler) {
    if (!EMULATING()) {
        ((StartWithQueue)previous_start_motion_queue)(self, _cmd, queue, handler);
        return;
    }
    start_motion(self, queue, handler);
}

static void mulg_start_motion_frame_queue(CMMotionManager *self, SEL _cmd, CMAttitudeReferenceFrame frame,
                                          NSOperationQueue *queue, CMDeviceMotionHandler handler) {
    if (!EMULATING()) {
        ((StartWithFrameQueue)previous_start_motion_frame_queue)(self, _cmd, frame, queue, handler);
        return;
    }
    start_motion(self, queue, handler);
}

static void mulg_start_motion(CMMotionManager *self, SEL _cmd) {
    if (!EMULATING()) {
        ((Action)previous_start_motion)(self, _cmd);
        return;
    }
    start_motion(self, nil, nil);
}

static void mulg_start_motion_frame(CMMotionManager *self, SEL _cmd, CMAttitudeReferenceFrame frame) {
    if (!EMULATING()) {
        ((StartWithFrame)previous_start_motion_frame)(self, _cmd, frame);
        return;
    }
    start_motion(self, nil, nil);
}

static id mulg_device_motion(CMMotionManager *self, SEL _cmd) {
    if (!EMULATING()) {
        return ((ObjectGetter)previous_device_motion)(self, _cmd);
    }
    return objc_getAssociatedObject(self, &kMotionActiveKey) != nil ? make_motion(mulg_motion_latest()) : nil;
}

static void mulg_stop_motion(CMMotionManager *self, SEL _cmd) {
    if (objc_getAssociatedObject(self, &kMotionActiveKey) != nil) {
        objc_setAssociatedObject(self, &kMotionActiveKey, nil, OBJC_ASSOCIATION_RETAIN);
        stop_timer(self, &kMotionTimerKey);
        return;
    }
    ((Action)previous_stop_motion)(self, _cmd);
}

// MARK: Installation

int mulg_motion_install_hooks(void) {
    static int installed = -1;
    if (installed >= 0) {
        return installed;
    }
    Class cls = [CMMotionManager class];
    struct { SEL selector; IMP replacement; IMP *previous; } hooks[] = {
        { @selector(attitudeReferenceFrame), (IMP)mulg_reference_frame, &previous_reference_frame },
        { @selector(isGyroAvailable), (IMP)mulg_gyro_available, &previous_gyro_available },
        { @selector(isDeviceMotionAvailable), (IMP)mulg_motion_available, &previous_motion_available },
        { @selector(isGyroActive), (IMP)mulg_gyro_active, &previous_gyro_active },
        { @selector(isDeviceMotionActive), (IMP)mulg_motion_active, &previous_motion_active },
        { @selector(startGyroUpdatesToQueue:withHandler:), (IMP)mulg_start_gyro_queue, &previous_start_gyro_queue },
        { @selector(startGyroUpdates), (IMP)mulg_start_gyro, &previous_start_gyro },
        { @selector(gyroData), (IMP)mulg_gyro_data, &previous_gyro_data },
        { @selector(stopGyroUpdates), (IMP)mulg_stop_gyro, &previous_stop_gyro },
        { @selector(startDeviceMotionUpdatesToQueue:withHandler:), (IMP)mulg_start_motion_queue,
          &previous_start_motion_queue },
        { @selector(startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:),
          (IMP)mulg_start_motion_frame_queue, &previous_start_motion_frame_queue },
        { @selector(startDeviceMotionUpdates), (IMP)mulg_start_motion, &previous_start_motion },
        { @selector(startDeviceMotionUpdatesUsingReferenceFrame:), (IMP)mulg_start_motion_frame,
          &previous_start_motion_frame },
        { @selector(deviceMotion), (IMP)mulg_device_motion, &previous_device_motion },
        { @selector(stopDeviceMotionUpdates), (IMP)mulg_stop_motion, &previous_stop_motion },
    };
    int count = 0;
    if (mulg_swizzle_checked_owned("controls", object_getClass(cls), @selector(availableAttitudeReferenceFrames),
            (IMP)mulg_reference_frames, &previous_reference_frames, @encode(CMAttitudeReferenceFrame), @[])
        == MulgSwizzleResultReplaced) count++;
    for (size_t index = 0; index < sizeof(hooks) / sizeof(hooks[0]); index++) {
        if (mulg_swizzle_instance_owned("controls", cls, hooks[index].selector, hooks[index].replacement, hooks[index].previous)
            == MulgSwizzleResultReplaced) {
            count += 1;
        }
    }
    installed = count;
    return count;
}

#else

int mulg_motion_install_hooks(void) {
    return 0;
}

#endif
