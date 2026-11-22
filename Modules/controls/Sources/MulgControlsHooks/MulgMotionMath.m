//
//  MulgMotionMath.m
//  controls module: the virtual gyro's integrator (PLAN.md §14.3).
//
//  Mouse movement arrives as rotations (radians) at irregular times; held keys and controller
//  motion arrive as steady rates. Each step turns the rotation collected since the last step
//  into a rate over that step, adds the steady rate, and integrates the attitude. When nothing
//  moves, the rate is exactly zero: no drift and no smoothing.
//
//  The resting attitude is an iPad held upright in landscape (interface orientation landscape
//  right), so gravity points along the device's -X axis, as on a real device held that way.
//

#import "MulgControlsHooks.h"
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>

typedef struct { double x, y, z, w; } Quaternion;

static os_unfair_lock mulg_motion_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic(int) mulg_motion_enabled = 0;
static double pending_x = 0, pending_y = 0, pending_z = 0;
static double steady_x = 0, steady_y = 0, steady_z = 0;
static Quaternion attitude = { 0, 0, 0, 1 };
static int attitude_initialised = 0;
static MulgMotionSample latest;

static Quaternion multiply(Quaternion a, Quaternion b) {
    return (Quaternion){
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

static Quaternion normalise(Quaternion q) {
    double length = hypot(hypot(q.x, q.y), hypot(q.z, q.w));
    if (!isfinite(length) || length < 1e-12) {
        return (Quaternion){ 0, 0, 0, 1 };
    }
    return (Quaternion){ q.x / length, q.y / length, q.z / length, q.w / length };
}

static Quaternion axis_angle(double x, double y, double z, double angle) {
    double half = angle / 2;
    double s = sin(half);
    return (Quaternion){ x * s, y * s, z * s, cos(half) };
}

/// Upright landscape: a quarter turn about X (flat → upright portrait), then a quarter turn
/// about the device's Z (portrait → landscape right).
static Quaternion resting_attitude(void) {
    Quaternion upright = axis_angle(1, 0, 0, M_PI_2);
    Quaternion landscape = axis_angle(0, 0, 1, M_PI_2);
    return normalise(multiply(upright, landscape));
}

/// Rotates world gravity (0, 0, -1) into the device frame: v' = q⁻¹ v q.
static void gravity_in_device_frame(Quaternion q, double *gx, double *gy, double *gz) {
    Quaternion conjugate = { -q.x, -q.y, -q.z, q.w };
    Quaternion world = { 0, 0, -1, 0 };
    Quaternion result = multiply(multiply(conjugate, world), q);
    *gx = result.x;
    *gy = result.y;
    *gz = result.z;
}

static MulgMotionSample make_sample(double rx, double ry, double rz, Quaternion q) {
    MulgMotionSample sample;
    sample.rateX = rx;
    sample.rateY = ry;
    sample.rateZ = rz;
    sample.qx = q.x;
    sample.qy = q.y;
    sample.qz = q.z;
    sample.qw = q.w;
    gravity_in_device_frame(q, &sample.gravityX, &sample.gravityY, &sample.gravityZ);
    return sample;
}

static void ensure_initialised_locked(void) {
    if (!attitude_initialised) {
        attitude = resting_attitude();
        latest = make_sample(0, 0, 0, attitude);
        attitude_initialised = 1;
    }
}

void mulg_motion_configure(BOOL enabled) {
    atomic_store(&mulg_motion_enabled, enabled ? 1 : 0);
    if (!enabled) {
        extern void mulg_motion_stop_delivery(void);
        mulg_motion_stop_delivery();
    }
}

BOOL mulg_motion_is_enabled(void) {
    return atomic_load(&mulg_motion_enabled) != 0;
}

void mulg_motion_add_rotation(double x, double y, double z) {
    if (!isfinite(x) || !isfinite(y) || !isfinite(z)) return;
    os_unfair_lock_lock(&mulg_motion_lock);
    double next_x = pending_x + x, next_y = pending_y + y, next_z = pending_z + z;
    if (isfinite(next_x) && isfinite(next_y) && isfinite(next_z)) {
        pending_x = next_x; pending_y = next_y; pending_z = next_z;
    }
    os_unfair_lock_unlock(&mulg_motion_lock);
}

void mulg_motion_set_steady_rate(double x, double y, double z) {
    os_unfair_lock_lock(&mulg_motion_lock);
    steady_x = isfinite(x) ? x : 0;
    steady_y = isfinite(y) ? y : 0;
    steady_z = isfinite(z) ? z : 0;
    os_unfair_lock_unlock(&mulg_motion_lock);
}

void mulg_motion_recenter(void) {
    os_unfair_lock_lock(&mulg_motion_lock);
    attitude = resting_attitude();
    attitude_initialised = 1;
    pending_x = pending_y = pending_z = 0;
    latest = make_sample(0, 0, 0, attitude);
    os_unfair_lock_unlock(&mulg_motion_lock);
}

MulgMotionSample mulg_motion_step(double dt) {
    os_unfair_lock_lock(&mulg_motion_lock);
    ensure_initialised_locked();
    double rx = steady_x, ry = steady_y, rz = steady_z;
    if (isfinite(dt) && dt > 1e-6) {
        rx += pending_x / dt;
        ry += pending_y / dt;
        rz += pending_z / dt;
        pending_x = pending_y = pending_z = 0;

        // Integrate: q ← q ⊗ exp(½ ω dt), with ω in the device frame.
        double speed = hypot(hypot(rx, ry), rz);
        double angle = speed * dt;
        if (!isfinite(speed) || !isfinite(angle)) {
            // Invalid tuning/sensor data must not poison every future attitude sample.
            rx = ry = rz = 0;
        } else if (speed > 1e-12) {
            Quaternion delta = axis_angle(rx / speed, ry / speed, rz / speed, angle);
            attitude = normalise(multiply(attitude, delta));
        }
    }
    latest = make_sample(rx, ry, rz, attitude);
    MulgMotionSample result = latest;
    os_unfair_lock_unlock(&mulg_motion_lock);
    return result;
}

MulgMotionSample mulg_motion_latest(void) {
    os_unfair_lock_lock(&mulg_motion_lock);
    ensure_initialised_locked();
    MulgMotionSample result = latest;
    os_unfair_lock_unlock(&mulg_motion_lock);
    return result;
}
