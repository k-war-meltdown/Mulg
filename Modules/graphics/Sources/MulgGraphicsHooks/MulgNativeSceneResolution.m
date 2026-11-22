// Reversible engine-owned scene scaling. Deliberately separate from legacy forced output
// resolution: a full-size drawable is not proof of a full-size internal scene.
#import "MulgNativeSceneResolution.h"
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum { TypeVoid = 1, TypeFloat = 12, TypeClass = 18, TypeObject = 28, TypeGeneric = 21, MethodStatic = 0x10 };
static struct {
    void *(*domain)(void);
    void *(*attach)(void *);
    void **(*assemblies)(void *, size_t *);
    void *(*image)(void *);
    void *(*klass)(void *, const char *, const char *);
    void *(*method)(void *, const char *, int);
    void *(*parent)(void *);
    void *(*objectClass)(void *);
    void *(*invoke)(void *, void *, void **, void **);
    void *(*unbox)(void *);
    const void *(*returnType)(void *);
    const void *(*paramType)(void *, uint32_t);
    int (*type)(const void *);
    bool (*byRef)(const void *);
    uint32_t (*flags)(void *, uint32_t *);
    uint32_t (*paramCount)(void *);
    uint32_t (*retain)(void *, bool);
    void *(*target)(uint32_t);
    void (*release)(uint32_t);
} api;

typedef struct { void *get, *set; } ScalarAPI;
typedef struct { void *width, *height, *resize; } DynamicAPI;
typedef struct {
    ScalarAPI scale;
    DynamicAPI dynamic;
    void *domain;
    void *pipeline;
    BOOL builtin;
} Capability;
typedef struct {
    ScalarAPI scale;
    DynamicAPI dynamic;
    void *domain;
    uint32_t pipelineHandle;
    float scaleBefore, widthBefore, heightBefore;
    BOOL scaleOwned, dynamicOwned;
} Snapshot;
static Snapshot snapshot;
static BOOL apiReady;
static struct { void *domain, *getter; size_t count; DynamicAPI dynamic; } interfaces;
static MulgNativeSceneState state;
static BOOL requested, yielded, failed;
static unsigned int applications, restorations, overrides;
static NSString *reason = @"Not requested";

static BOOL close_value(float a, float b) { return isfinite(a) && isfinite(b) && fabsf(a - b) <= 0.0001f; }
static BOOL valid_scale(float x) { return isfinite(x) && x >= 0.01f && x <= 4.0f; }

static BOOL resolve_api(void) {
    if (apiReady) return YES;
#define LOAD(field, name) api.field = dlsym(RTLD_DEFAULT, name)
    LOAD(domain, "il2cpp_domain_get"); LOAD(attach, "il2cpp_thread_attach");
    LOAD(assemblies, "il2cpp_domain_get_assemblies"); LOAD(image, "il2cpp_assembly_get_image");
    LOAD(klass, "il2cpp_class_from_name"); LOAD(method, "il2cpp_class_get_method_from_name");
    LOAD(parent, "il2cpp_class_get_parent"); LOAD(objectClass, "il2cpp_object_get_class");
    LOAD(invoke, "il2cpp_runtime_invoke"); LOAD(unbox, "il2cpp_object_unbox");
    LOAD(returnType, "il2cpp_method_get_return_type"); LOAD(paramType, "il2cpp_method_get_param");
    LOAD(type, "il2cpp_type_get_type"); LOAD(flags, "il2cpp_method_get_flags");
    LOAD(byRef, "il2cpp_type_is_byref");
    LOAD(paramCount, "il2cpp_method_get_param_count"); LOAD(retain, "il2cpp_gchandle_new");
    LOAD(target, "il2cpp_gchandle_get_target"); LOAD(release, "il2cpp_gchandle_free");
#undef LOAD
    apiReady = api.domain && api.attach && api.assemblies && api.image && api.klass && api.method && api.parent
        && api.objectClass && api.invoke && api.unbox && api.returnType && api.paramType && api.type && api.byRef
        && api.flags && api.paramCount && api.retain && api.target && api.release;
    return apiReady;
}

static BOOL signature(void *method, BOOL isStatic, int result, unsigned int arguments) {
    if (!method || api.paramCount(method) != arguments) return NO;
    uint32_t implementation = 0;
    if (((api.flags(method, &implementation) & MethodStatic) != 0) != isStatic) return NO;
    const void *type = api.returnType(method);
    if (!type || api.byRef(type) || api.type(type) != result) return NO;
    for (unsigned int i = 0; i < arguments; i++) {
        type = api.paramType(method, i);
        if (!type || api.byRef(type) || api.type(type) != TypeFloat) return NO;
    }
    return YES;
}

static void *inherited_method(void *klass, const char *name, int count) {
    for (int depth = 0; klass && depth < 16; depth++, klass = api.parent(klass)) {
        void *method = api.method(klass, name, count);
        if (method) return method;
    }
    return NULL;
}

static BOOL read_float(void *method, void *object, float *value) {
    void *exception = NULL;
    void *boxed = api.invoke(method, object, NULL, &exception);
    void *data = boxed && !exception ? api.unbox(boxed) : NULL;
    if (!data) return NO;
    memcpy(value, data, sizeof *value);
    return valid_scale(*value);
}

static BOOL write_float(void *method, void *object, float value) {
    void *arguments[] = { &value }, *exception = NULL;
    api.invoke(method, object, arguments, &exception);
    return exception == NULL;
}

static BOOL read_dynamic(DynamicAPI dynamic, float *width, float *height) {
    return dynamic.resize && read_float(dynamic.width, NULL, width) && read_float(dynamic.height, NULL, height);
}

static BOOL write_dynamic(DynamicAPI dynamic, float width, float height) {
    void *arguments[] = { &width, &height }, *exception = NULL;
    api.invoke(dynamic.resize, NULL, arguments, &exception);
    return exception == NULL;
}

static MulgNativeSceneState discover(Capability *capability) {
    memset(capability, 0, sizeof *capability);
    if (!resolve_api()) { reason = @"No complete, typed engine API is available"; return MulgNativeSceneUnsupported; }
    void *domain = api.domain();
    if (!domain) { reason = @"Waiting for the engine domain"; return MulgNativeSceneWaiting; }
    size_t count = 0;
    void **assemblies = api.assemblies(domain, &count);
    if (!assemblies || !count) { reason = @"Waiting for engine assemblies"; return MulgNativeSceneWaiting; }
    if (count > 16384 || !api.attach(domain)) { reason = @"Invalid engine assembly state"; return MulgNativeSceneUnsupported; }
    capability->domain = domain;
    if (interfaces.domain != domain || interfaces.count != count) {
        memset(&interfaces, 0, sizeof interfaces);
        interfaces.domain = domain; interfaces.count = count;
        for (size_t i = 0; i < count; i++) {
            void *image = api.image(assemblies[i]);
            if (!image) continue;
            void *klass = api.klass(image, "UnityEngine.Rendering", "GraphicsSettings");
            void *getter = klass ? api.method(klass, "get_currentRenderPipeline", 0) : NULL;
            if (getter && api.paramCount(getter) == 0) {
                uint32_t impl = 0;
                const void *type = api.returnType(getter);
                int result = type ? api.type(type) : -1;
                if (type && !api.byRef(type) && (api.flags(getter, &impl) & MethodStatic)
                    && (result == TypeClass || result == TypeObject || result == TypeGeneric))
                    interfaces.getter = getter;
            }
            klass = api.klass(image, "UnityEngine", "ScalableBufferManager");
            if (klass) {
                DynamicAPI candidate = { api.method(klass, "get_widthScaleFactor", 0), api.method(klass, "get_heightScaleFactor", 0),
                    api.method(klass, "ResizeBuffers", 2) };
                if (signature(candidate.width, YES, TypeFloat, 0) && signature(candidate.height, YES, TypeFloat, 0)
                    && signature(candidate.resize, YES, TypeVoid, 2)) interfaces.dynamic = candidate;
            }
        }
    }
    capability->dynamic = interfaces.dynamic;
    if (!interfaces.getter) { reason = @"No verified active-renderer interface"; return MulgNativeSceneUnsupported; }
    void *exception = NULL;
    capability->pipeline = api.invoke(interfaces.getter, NULL, NULL, &exception);
    if (exception) { reason = @"The active-renderer query failed"; return MulgNativeSceneFailed; }
    if (capability->pipeline) {
        void *klass = api.objectClass(capability->pipeline);
        ScalarAPI candidate = { inherited_method(klass, "get_renderScale", 0), inherited_method(klass, "set_renderScale", 1) };
        if (!signature(candidate.get, NO, TypeFloat, 0) || !signature(candidate.set, NO, TypeVoid, 1)) {
            reason = @"The active renderer has no reversible, typed scene-scale property";
            return MulgNativeSceneUnsupported;
        }
        float value;
        if (!read_float(candidate.get, capability->pipeline, &value)) {
            reason = @"The renderer's scene scale could not be read"; return MulgNativeSceneFailed;
        }
        capability->scale = candidate;
    } else {
        capability->builtin = YES;
        if (!capability->dynamic.resize) { reason = @"The built-in renderer exposes no reversible scaling API"; return MulgNativeSceneUnsupported; }
    }
    float width, height;
    if (capability->dynamic.resize && !read_dynamic(capability->dynamic, &width, &height)) {
        reason = @"Dynamic-resolution factors could not be read"; return MulgNativeSceneFailed;
    }
    reason = capability->builtin ? @"Unity dynamic-resolution API available" : @"Unity renderer scene-scale API available";
    return MulgNativeSceneReady;
}

BOOL mulg_native_scene_owns_values(void) { return snapshot.scaleOwned || snapshot.dynamicOwned; }

static void release_snapshot(void) {
    if (snapshot.pipelineHandle) api.release(snapshot.pipelineHandle);
    memset(&snapshot, 0, sizeof snapshot);
}

/// Restore only values still owned by this feature. During immediate failure rollback,
/// restore a partial/clamped setter result too; no other engine call runs in between.
static BOOL restore(BOOL rollback) {
    if (mulg_native_scene_owns_values()) {
        void *domain = api.domain();
        if (!domain) return NO;
        // A different runtime domain has no ownership of the old domain's managed handles.
        if (domain != snapshot.domain) { memset(&snapshot, 0, sizeof snapshot); return YES; }
    }
    BOOL success = YES;
    // Read dynamic ownership before restoring the pipeline: the engine's pipeline setter
    // may itself resize the dynamic buffers, which is not an external game override.
    BOOL restoreDynamic = snapshot.dynamicOwned;
    if (restoreDynamic && !rollback) {
        float width = 0, height = 0;
        if (!read_dynamic(snapshot.dynamic, &width, &height)) { success = NO; restoreDynamic = NO; }
        else if (!close_value(width, 1) || !close_value(height, 1)) {
            // If the game replaced our scale, preserve its latest choice through any
            // side effects of restoring the pipeline's own scale below.
            snapshot.widthBefore = width; snapshot.heightBefore = height;
        }
    }
    if (snapshot.scaleOwned) {
        void *pipeline = api.target(snapshot.pipelineHandle);
        float current = 0;
        if (!pipeline || (!rollback && !read_float(snapshot.scale.get, pipeline, &current))) success = NO;
        else if (!rollback && !close_value(current, 1)) snapshot.scaleOwned = NO;
        else if (write_float(snapshot.scale.set, pipeline, snapshot.scaleBefore)
            && read_float(snapshot.scale.get, pipeline, &current) && close_value(current, snapshot.scaleBefore)) {
            snapshot.scaleOwned = NO; restorations++;
        } else success = NO;
    }
    if (restoreDynamic) {
        float width = 0, height = 0;
        if ((read_dynamic(snapshot.dynamic, &width, &height)
             && close_value(width, snapshot.widthBefore) && close_value(height, snapshot.heightBefore))
            || (write_dynamic(snapshot.dynamic, snapshot.widthBefore, snapshot.heightBefore)
            && read_dynamic(snapshot.dynamic, &width, &height)
            && close_value(width, snapshot.widthBefore) && close_value(height, snapshot.heightBefore))) {
            snapshot.dynamicOwned = NO; restorations++;
        } else success = NO;
    }
    if (!mulg_native_scene_owns_values()) release_snapshot();
    return success;
}

MulgNativeSceneState mulg_native_scene_probe(void) {
    Capability capability;
    return state = discover(&capability);
}

MulgNativeSceneState mulg_native_scene_update(BOOL enabled) {
    NSCAssert(NSThread.isMainThread, @"Scene resolution changes require the main thread");
    requested = enabled;
    if (!enabled) {
        BOOL hadValues = mulg_native_scene_owns_values();
        if (hadValues && !restore(failed)) {
            failed = YES;
            reason = @"Restoration pending: the engine rejected its previous value"; return state = MulgNativeSceneFailed;
        }
        yielded = failed = NO; overrides = 0;
        reason = hadValues ? @"Previous engine values restored" : @"Off";
        return state = MulgNativeSceneRestored;
    }
    if (failed) { reason = @"An engine setter failed; switch off to retry restoration"; return state = MulgNativeSceneFailed; }
    if (yielded) { reason = @"The game repeatedly chose its own scale; switch off and on to retry"; return state = MulgNativeSceneOverridden; }
    Capability capability;
    MulgNativeSceneState available = discover(&capability);
    if (available != MulgNativeSceneReady) {
        NSString *unavailableReason = reason;
        if (mulg_native_scene_owns_values() && !restore(NO)) {
            failed = YES;
            reason = @"The renderer changed and restoration is pending"; return state = MulgNativeSceneFailed;
        }
        reason = unavailableReason; return state = available;
    }
    if (mulg_native_scene_owns_values() && snapshot.domain != capability.domain) {
        if (!restore(NO)) { failed = YES; reason = @"Previous engine domain restoration is pending"; return state = MulgNativeSceneFailed; }
    }
    void *oldPipeline = snapshot.pipelineHandle ? api.target(snapshot.pipelineHandle) : NULL;
    if (mulg_native_scene_owns_values() && oldPipeline != capability.pipeline) {
        if (!restore(NO)) { failed = YES; reason = @"Previous renderer restoration is pending"; return state = MulgNativeSceneFailed; }
    }
    float scale = 1, width = 1, height = 1;
    if ((capability.scale.get && !read_float(capability.scale.get, capability.pipeline, &scale))
        || (capability.dynamic.resize && !read_dynamic(capability.dynamic, &width, &height))) {
        reason = @"Engine state changed before the request"; return state = MulgNativeSceneFailed;
    }
    if (mulg_native_scene_owns_values() && ((!close_value(scale, 1) && snapshot.scaleOwned)
        || ((!close_value(width, 1) || !close_value(height, 1)) && snapshot.dynamicOwned))) {
        // Retain the game's newest choice for the Off path, rather than restoring a stale preference.
        if (snapshot.scaleOwned && !close_value(scale, 1)) snapshot.scaleBefore = scale;
        if (snapshot.dynamicOwned && (!close_value(width, 1) || !close_value(height, 1))) {
            snapshot.widthBefore = width; snapshot.heightBefore = height;
        }
        if (++overrides >= 3) {
            yielded = YES;
            if (!restore(NO)) { failed = YES; reason = @"Restoration pending after a game override"; return state = MulgNativeSceneFailed; }
            reason = @"The game kept its own resolution policy"; return state = MulgNativeSceneOverridden;
        }
    }
    BOOL changeScale = capability.scale.set && !close_value(scale, 1);
    BOOL changeDynamic = capability.dynamic.resize && (!close_value(width, 1) || !close_value(height, 1));
    float widthBefore = width, heightBefore = height;
    if (changeScale || changeDynamic) snapshot.domain = capability.domain;
    if ((changeScale || changeDynamic) && !snapshot.pipelineHandle && capability.pipeline) {
        snapshot.pipelineHandle = api.retain(capability.pipeline, false);
        if (!snapshot.pipelineHandle) { reason = @"The renderer could not be retained safely"; return state = MulgNativeSceneFailed; }
    }
    BOOL success = YES;
    if (changeScale) {
        snapshot.scale = capability.scale;
        snapshot.scaleBefore = scale; snapshot.scaleOwned = YES;
        success = write_float(capability.scale.set, capability.pipeline, 1)
            && read_float(capability.scale.get, capability.pipeline, &scale) && close_value(scale, 1);
        if (capability.dynamic.resize) {
            BOOL readable = read_dynamic(capability.dynamic, &width, &height);
            if (!readable || !close_value(width, widthBefore) || !close_value(height, heightBefore)) {
                if (!snapshot.dynamicOwned) {
                    snapshot.widthBefore = widthBefore; snapshot.heightBefore = heightBefore;
                }
                snapshot.dynamic = capability.dynamic; snapshot.dynamicOwned = YES;
            }
            success = success && readable;
            changeDynamic = readable && (!close_value(width, 1) || !close_value(height, 1));
        }
    }
    if (success && changeDynamic) {
        snapshot.dynamic = capability.dynamic;
        if (!snapshot.dynamicOwned) {
            snapshot.widthBefore = widthBefore; snapshot.heightBefore = heightBefore;
        }
        snapshot.dynamicOwned = YES;
        success = write_dynamic(capability.dynamic, 1, 1) && read_dynamic(capability.dynamic, &width, &height)
            && close_value(width, 1) && close_value(height, 1);
    }
    if (!success) {
        failed = YES;
        BOOL rolledBack = restore(YES);
        reason = rolledBack ? @"Engine rejected the request; previous values restored" : @"Engine rejected the request; restoration pending";
        return state = MulgNativeSceneFailed;
    }
    if (!mulg_native_scene_owns_values()) release_snapshot();
    if (changeScale || changeDynamic) applications++;
    reason = @"Engine accepted full-output scaling; internal scene dimensions are not yet verified";
    return state = MulgNativeSceneApplied;
}

NSDictionary *mulg_native_scene_report(void) {
    return @{@"adapter": @"Unity typed scene-scale APIs", @"state": @(state), @"requested": @(requested),
        @"reason": reason, @"ownsEngineValues": @(mulg_native_scene_owns_values()), @"requestsAccepted": @(applications),
        @"valuesRestored": @(restorations), @"gameOverrides": @(overrides), @"nativeSceneVerified": @NO};
}
