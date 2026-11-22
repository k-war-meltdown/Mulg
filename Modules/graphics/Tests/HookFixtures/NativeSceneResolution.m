#import <Foundation/Foundation.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdbool.h>

static void *fake_symbol(void *scope, const char *name);
#define dlsym fake_symbol
#include "MulgNativeSceneResolution.m"
#undef dlsym

typedef struct { float scale; } Pipeline;
static Pipeline first = {0.65f}, second = {0.8f};
static Pipeline *current = &first;
static float width = 0.55f, height = 0.7f, boxed;
static BOOL exportsReady, domainReady, rejectDynamic, invalidParameter, coupledScale;
static unsigned int writes;
static void *handles[8];
static int graphicsClass, buffersClass, pipelineClass, assembly;
static const int floatType = TypeFloat, voidType = TypeVoid, classType = TypeClass, intType = 8;
typedef struct { int id; const int *result; uint32_t count, flags; } FakeMethod;
static FakeMethod pipelineGetter = {1, &classType, 0, MethodStatic};
static FakeMethod getScale = {2, &floatType, 0, 0}, setScale = {3, &voidType, 1, 0};
static FakeMethod getWidth = {4, &floatType, 0, MethodStatic}, getHeight = {5, &floatType, 0, MethodStatic};
static FakeMethod setBuffers = {6, &voidType, 2, MethodStatic};

static void *domain(void) { return domainReady ? &assembly : NULL; }
static void *attach(void *value) { return value; }
static void **assemblies(void *value, size_t *count) {
    static void *items[] = { &assembly }; *count = 1; return items;
}
static void *image(void *value) { return value; }
static void *klass(void *value, const char *space, const char *name) {
    if (!strcmp(name, "GraphicsSettings")) return &graphicsClass;
    if (!strcmp(name, "ScalableBufferManager")) return &buffersClass;
    return NULL;
}
static void *parent(void *value) { return NULL; }
static void *object_class(void *value) { return value ? &pipelineClass : NULL; }
static void *method(void *value, const char *name, int count) {
    if (value == &graphicsClass && !strcmp(name, "get_currentRenderPipeline")) return &pipelineGetter;
    if (value == &pipelineClass && !strcmp(name, "get_renderScale")) return &getScale;
    if (value == &pipelineClass && !strcmp(name, "set_renderScale")) return &setScale;
    if (value == &buffersClass && !strcmp(name, "get_widthScaleFactor")) return &getWidth;
    if (value == &buffersClass && !strcmp(name, "get_heightScaleFactor")) return &getHeight;
    if (value == &buffersClass && !strcmp(name, "ResizeBuffers")) return &setBuffers;
    return NULL;
}
static void *invoke(void *value, void *object, void **args, void **exception) {
    switch (((FakeMethod *)value)->id) {
        case 1: return current;
        case 2: boxed = ((Pipeline *)object)->scale; return &boxed;
        case 3:
            ((Pipeline *)object)->scale = *(float *)args[0]; writes++;
            if (coupledScale) { width = 0.9f; height = 0.85f; }
            break;
        case 4: boxed = width; return &boxed;
        case 5: boxed = height; return &boxed;
        case 6:
            width = *(float *)args[0]; height = *(float *)args[1]; writes++;
            if (rejectDynamic && width == 1 && height == 1) width = 0.875f;
            break;
        default: assert(false);
    }
    return NULL;
}
static void *unbox(void *value) { return value; }
static const void *return_type(void *value) { return ((FakeMethod *)value)->result; }
static const void *param_type(void *value, uint32_t index) { return value == &setScale && invalidParameter ? &intType : &floatType; }
static int type(const void *value) { return *(const int *)value; }
static bool by_ref(const void *value) { return false; }
static uint32_t flags(void *value, uint32_t *impl) { *impl = 0; return ((FakeMethod *)value)->flags; }
static uint32_t count(void *value) { return ((FakeMethod *)value)->count; }
static uint32_t retain(void *value, bool pin) {
    for (uint32_t i = 1; i < 8; i++) if (!handles[i]) { handles[i] = value; return i; }
    return 0;
}
static void *target(uint32_t handle) { assert(handle < 8); return handles[handle]; }
static void release(uint32_t handle) { assert(handle > 0 && handle < 8 && handles[handle]); handles[handle] = NULL; }
static void *fake_symbol(void *scope, const char *name) {
    if (!exportsReady) return NULL;
#define MAP(symbol, function) if (!strcmp(name, symbol)) return (void *)function
    MAP("il2cpp_domain_get", domain); MAP("il2cpp_thread_attach", attach);
    MAP("il2cpp_domain_get_assemblies", assemblies); MAP("il2cpp_assembly_get_image", image);
    MAP("il2cpp_class_from_name", klass); MAP("il2cpp_class_get_method_from_name", method);
    MAP("il2cpp_class_get_parent", parent); MAP("il2cpp_object_get_class", object_class);
    MAP("il2cpp_runtime_invoke", invoke); MAP("il2cpp_object_unbox", unbox);
    MAP("il2cpp_method_get_return_type", return_type); MAP("il2cpp_method_get_param", param_type);
    MAP("il2cpp_type_get_type", type); MAP("il2cpp_type_is_byref", by_ref);
    MAP("il2cpp_method_get_flags", flags); MAP("il2cpp_method_get_param_count", count);
    MAP("il2cpp_gchandle_new", retain); MAP("il2cpp_gchandle_get_target", target); MAP("il2cpp_gchandle_free", release);
#undef MAP
    return NULL;
}

int main(void) { @autoreleasepool {
    assert(mulg_native_scene_probe() == MulgNativeSceneUnsupported && writes == 0);
    exportsReady = YES;
    assert(mulg_native_scene_probe() == MulgNativeSceneWaiting && writes == 0);
    domainReady = YES; invalidParameter = YES;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneUnsupported && writes == 0);
    invalidParameter = NO;
    assert(mulg_native_scene_probe() == MulgNativeSceneReady && writes == 0);
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied);
    assert(first.scale == 1 && width == 1 && height == 1 && writes == 2);
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied && writes == 2);
    assert(![mulg_native_scene_report()[@"nativeSceneVerified"] boolValue]);
    // Transfer the trial across a pipeline recreation, restoring the outgoing object first.
    current = &second;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied && first.scale == 0.65f && second.scale == 1);
    assert(mulg_native_scene_update(NO) == MulgNativeSceneRestored);
    assert(second.scale == 0.8f && width == 0.55f && height == 0.7f && !mulg_native_scene_owns_values());
    // A partial write must not leave one setting at 1.0 if the engine clamps the other.
    rejectDynamic = YES;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneFailed);
    assert(second.scale == 0.8f && width == 0.55f && height == 0.7f && !mulg_native_scene_owns_values());
    unsigned int before = writes;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneFailed && writes == before);
    assert(mulg_native_scene_update(NO) == MulgNativeSceneRestored);
    rejectDynamic = NO;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied);
    second.scale = 0.62f;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied);
    assert(mulg_native_scene_update(NO) == MulgNativeSceneRestored && second.scale == 0.62f);
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied);
    second.scale = 0.62f; assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied);
    second.scale = 0.61f; assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied);
    second.scale = 0.60f; assert(mulg_native_scene_update(YES) == MulgNativeSceneOverridden);
    assert(second.scale == 0.60f && width == 0.55f && height == 0.7f);
    assert(mulg_native_scene_update(NO) == MulgNativeSceneRestored);
    coupledScale = YES;
    width = 1; height = 1;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied && width == 1 && height == 1);
    width = 0.92f; height = 0.89f; // A later engine choice must survive the pipeline setter's side effects.
    assert(mulg_native_scene_update(NO) == MulgNativeSceneRestored);
    assert(second.scale == 0.60f && width == 0.92f && height == 0.89f);
    coupledScale = NO; width = 0.55f; height = 0.7f;
    // Built-in Unity can expose a reversible dynamic-resolution API with no SRP asset.
    current = NULL;
    assert(mulg_native_scene_update(YES) == MulgNativeSceneApplied && width == 1 && height == 1);
    assert(mulg_native_scene_update(NO) == MulgNativeSceneRestored && width == 0.55f && height == 0.7f);
    for (unsigned int i = 1; i < 8; i++) assert(!handles[i]);
    puts("PASS: typed capability checks, reversible scene and dynamic scale, rollback, pipeline replacement, bounded ownership");
    return 0;
} }
