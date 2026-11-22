//
//  MulgUnityRenderScale.m
//  graphics module: Unity render scale 1.0 (with graphics.forceRenderResolution, any Unity game with
//  IL2CPP's exports).
//
//  Unity's scriptable pipelines (URP and forks such as Bleach Soul Resonance's Pulsar) draw the scene at
//  a render scale x the screen and stretch it. Set to 1.0 through the engine itself, every size, ratio
//  and viewport the game derives from it stays consistent: Mulg never resizes a game's images itself
//  (that broke cameras and lighting, removed 2026-10-30). The scale is found as
//  the pipeline's renderScale property, a SetRenderScale(float) method or a float renderScale field;
//  Unity's ScalableBufferManager is also kept at 1.0. Main thread only: Unity's managed code runs there.
//

#import "MulgGraphicsHooks.h"
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <os/log.h>

typedef void *(*DomainGet)(void);
typedef void *(*ThreadAttach)(void *);
typedef void **(*DomainAssemblies)(void *, size_t *);
typedef void *(*AssemblyImage)(void *);
typedef void *(*ClassFromName)(void *, const char *, const char *);
typedef void *(*MethodFromName)(void *, const char *, int);
typedef void *(*ClassParent)(void *);
typedef void *(*ObjectClass)(void *);
typedef const char *(*ClassName)(void *);
typedef void *(*RuntimeInvoke)(void *, void *, void **, void **);
typedef void *(*ObjectUnbox)(void *);
typedef void *(*ClassIterate)(void *, void **);
typedef const char *(*MemberName)(void *);
typedef uint32_t (*ParamCount)(void *);
typedef int (*FieldFlags)(void *);
typedef void *(*FieldType)(void *);
typedef char *(*TypeName)(void *);
typedef void (*FieldAccess)(void *, void *, void *);

static struct {
    bool resolved, available;
    DomainGet domain_get;
    ThreadAttach thread_attach;
    DomainAssemblies assemblies;
    AssemblyImage image;
    ClassFromName class_from_name;
    MethodFromName method;
    ClassParent parent;
    ObjectClass object_class;
    ClassName class_name;
    RuntimeInvoke invoke;
    ObjectUnbox unbox;
    ClassIterate methods, fields;
    MemberName method_name, field_name;
    ParamCount param_count;
    FieldFlags field_flags;
    FieldType field_type;
    TypeName type_name;
    FieldAccess field_get, field_set;
    void (*free_memory)(void *);
} il2cpp;

enum { FieldStatic = 0x10 };

/// GraphicsSettings' getter for the active pipeline (quality override included), once found.
static void *pipeline_getter;
/// Unity's dynamic resolution (static): its scale factors and ResizeBuffers(float, float).
static void *buffer_width, *buffer_height, *buffer_resize;
static bool buffer_looked_up;
/// The pipeline class last seen and how its scale is reached (property, setter only, or field).
static void *scale_class, *get_scale, *set_scale, *scale_field;
/// The pipeline object a setter-only scale was set on (it cannot be read back, so it is set once).
static void *setter_applied_to;
static float game_scale = -1;
static bool replaced;
static int applied_count, buffer_resets;
static char pipeline_name[96], scale_path[32] = "none", scale_members[768];
/// Diagnostics: Camera.allCameras, and every float instance field of the pipeline whose name holds "scale".
static void *camera_all;
/// QualitySettings (graphics.unityHighestQuality): names, GetQualityLevel(), SetQualityLevel(int, bool).
static void *quality_names, *quality_get, *quality_set;
static bool quality_looked_up;
static int quality_game = -1, quality_sets, quality_level = -1, quality_highest = -1;
enum { ValueFieldCount = 8 };
static void *value_fields[ValueFieldCount];
static int value_count, diagnose_tick;
static char camera_report[640], scale_values[512], buffer_values[64];

static bool resolve_il2cpp(void) {
    if (il2cpp.resolved) return il2cpp.available;
#define LOAD(field, name) il2cpp.field = dlsym(RTLD_DEFAULT, name)
    LOAD(domain_get, "il2cpp_domain_get");
    LOAD(thread_attach, "il2cpp_thread_attach");
    LOAD(assemblies, "il2cpp_domain_get_assemblies");
    LOAD(image, "il2cpp_assembly_get_image");
    LOAD(class_from_name, "il2cpp_class_from_name");
    LOAD(method, "il2cpp_class_get_method_from_name");
    LOAD(parent, "il2cpp_class_get_parent");
    LOAD(object_class, "il2cpp_object_get_class");
    LOAD(class_name, "il2cpp_class_get_name");
    LOAD(invoke, "il2cpp_runtime_invoke");
    LOAD(unbox, "il2cpp_object_unbox");
    LOAD(methods, "il2cpp_class_get_methods");
    LOAD(fields, "il2cpp_class_get_fields");
    LOAD(method_name, "il2cpp_method_get_name");
    LOAD(field_name, "il2cpp_field_get_name");
    LOAD(param_count, "il2cpp_method_get_param_count");
    LOAD(field_flags, "il2cpp_field_get_flags");
    LOAD(field_type, "il2cpp_field_get_type");
    LOAD(type_name, "il2cpp_type_get_name");
    LOAD(field_get, "il2cpp_field_get_value");
    LOAD(field_set, "il2cpp_field_set_value");
    LOAD(free_memory, "il2cpp_free");
#undef LOAD
    il2cpp.available = il2cpp.domain_get && il2cpp.thread_attach && il2cpp.assemblies && il2cpp.image
        && il2cpp.class_from_name && il2cpp.method && il2cpp.parent && il2cpp.object_class && il2cpp.invoke;
    // UnityFramework loads after Mulg starts: keep asking until it has.
    il2cpp.resolved = il2cpp.available;
    return il2cpp.available;
}

/// A method on the class or its bases.
static void *find_method(void *klass, const char *name, int arguments) {
    for (int depth = 0; klass && depth < 16; depth++, klass = il2cpp.parent(klass)) {
        void *found = il2cpp.method(klass, name, arguments);
        if (found) return found;
    }
    return NULL;
}

static bool is_scale_field(const char *name) {
    const char *names[] = { "renderScale", "m_RenderScale", "_renderScale", "mRenderScale", "m_renderScale" };
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) if (name && !strcmp(name, names[i])) return true;
    return false;
}

/// Further float render scales on the pipeline (Pulsar's m_SceneRenderScale scales the 3D scene apart
/// from renderScale): every instance float named *RenderScale*, except editor scene-view and min/max
/// bounds. Each below 1.0 is raised to 1.0 and its game value kept for giving back.
enum { ExtraScaleCount = 4 };
static void *extra_fields[ExtraScaleCount];
static float extra_game[ExtraScaleCount];
static int extra_count, extra_raised;

static bool is_extra_scale(const char *name) {
    return name && strcasestr(name, "renderscale") && !strcasestr(name, "sceneview") && !strcasestr(name, "min")
        && !strcasestr(name, "max") && !is_scale_field(name);
}

/// Raises (or, switched off, gives back) the extra scales on this pipeline object.
static void apply_extra_scales(void *pipeline, bool enabled) {
    for (int i = 0; i < extra_count; i++) {
        float current = -1;
        il2cpp.field_get(pipeline, extra_fields[i], &current);
        if (!isfinite(current) || current <= 0) continue;
        if (enabled) {
            if (current >= 0.999f || current < 0.1f) continue;
            extra_game[i] = current;
            float one = 1.0f;
            il2cpp.field_set(pipeline, extra_fields[i], &one);
            replaced = true;
            if (extra_raised++ == 0)
                os_log(os_log_create("io.mulg", "graphics"), "Unity %{public}s %{public}s %.3f -> 1.0", pipeline_name,
                       il2cpp.field_name(extra_fields[i]) ?: "?", current);
        } else if (extra_game[i] > 0 && fabsf(current - 1.0f) < 0.001f) {
            il2cpp.field_set(pipeline, extra_fields[i], &extra_game[i]);
            extra_game[i] = -1;
        }
    }
}

static void append_member(const char *name, const char *kind) {
    if (!name || !strcasestr(name, "scale")) return;
    size_t used = strlen(scale_members);
    if (used + strlen(name) + 4 >= sizeof scale_members) return;
    snprintf(scale_members + used, sizeof scale_members - used, "%s%s%s", used ? ", " : "", name, kind);
}

/// The scale-named methods and fields of the class and its bases (for rendering.json), and a float
/// instance field named as a render scale, when the class has no property for it.
static void inspect_class(void *klass) {
    scale_members[0] = 0;
    scale_field = NULL;
    extra_count = 0;
    value_count = 0;
    for (int depth = 0; klass && depth < 8; depth++, klass = il2cpp.parent(klass)) {
        void *iterator = NULL, *member;
        if (il2cpp.methods && il2cpp.method_name)
            while ((member = il2cpp.methods(klass, &iterator))) append_member(il2cpp.method_name(member), "()");
        iterator = NULL;
        if (!il2cpp.fields || !il2cpp.field_name) continue;
        while ((member = il2cpp.fields(klass, &iterator))) {
            const char *name = il2cpp.field_name(member);
            append_member(name, "");
            bool main = !scale_field && is_scale_field(name);
            bool extra = extra_count < ExtraScaleCount && is_extra_scale(name);
            bool shown = value_count < ValueFieldCount && name && strcasestr(name, "scale");
            if ((!main && !extra && !shown) || !il2cpp.field_flags || !il2cpp.field_type || !il2cpp.type_name
                || !il2cpp.field_get || !il2cpp.field_set || (il2cpp.field_flags(member) & FieldStatic)) continue;
            char *type = il2cpp.type_name(il2cpp.field_type(member));
            if (shown && type && !strcmp(type, "System.Single")) value_fields[value_count++] = member;
            if ((main || extra) && type && !strcmp(type, "System.Single")) {
                if (main) scale_field = member;
                else { extra_fields[extra_count] = member; extra_game[extra_count] = -1; extra_count++; }
            }
            // IL2CPP allocated the name with its own allocator: the system free() aborts on it (1017 crash).
            if (type && il2cpp.free_memory) il2cpp.free_memory(type);
        }
    }
}

// MARK: Diagnostics (rendering.json): where a game's scene size comes from

static float call_float(void *method, void *object);


static void *call_object(void *method, void *object) {
    void *exception = NULL;
    void *result = method ? il2cpp.invoke(method, object, NULL, &exception) : NULL;
    return exception ? NULL : result;
}

static int call_int(void *method, void *object) {
    void *boxed = call_object(method, object);
    void *value = boxed ? (il2cpp.unbox ? il2cpp.unbox(boxed) : (char *)boxed + 2 * sizeof(void *)) : NULL;
    return value ? *(int32_t *)value : -1;
}

static void diagnose(void *pipeline) {
    // Camera sizes, render targets and dynamic resolution, for up to six cameras.
    void *array = call_object(camera_all, NULL);
    camera_report[0] = 0;
    if (array) {
        // Il2CppArray: object header, bounds, max_length, then the elements.
        size_t length = *(size_t *)((char *)array + 3 * sizeof(void *));
        void **items = (void **)((char *)array + 4 * sizeof(void *));
        for (size_t i = 0; i < length && i < 6; i++) {
            void *camera = items[i], *klass = camera ? il2cpp.object_class(camera) : NULL;
            if (!klass) continue;
            int pw = call_int(find_method(klass, "get_pixelWidth", 0), camera);
            int ph = call_int(find_method(klass, "get_pixelHeight", 0), camera);
            int sw = call_int(find_method(klass, "get_scaledPixelWidth", 0), camera);
            int sh = call_int(find_method(klass, "get_scaledPixelHeight", 0), camera);
            int dynamic = call_int(find_method(klass, "get_allowDynamicResolution", 0), camera) & 0xff;
            void *target = call_object(find_method(klass, "get_targetTexture", 0), camera);
            int tw = -1, th = -1;
            if (target) {
                void *texture = il2cpp.object_class(target);
                tw = call_int(find_method(texture, "get_width", 0), target);
                th = call_int(find_method(texture, "get_height", 0), target);
            }
            size_t used = strlen(camera_report);
            snprintf(camera_report + used, sizeof camera_report - used, "%scamera %zu: pixels %dx%d scaled %dx%d target %dx%d dynamic %d",
                     used ? "; " : "", i, pw, ph, sw, sh, tw, th, dynamic);
        }
    }
    scale_values[0] = 0;
    for (int i = 0; pipeline && i < value_count; i++) {
        float value = -1;
        il2cpp.field_get(pipeline, value_fields[i], &value);
        size_t used = strlen(scale_values);
        snprintf(scale_values + used, sizeof scale_values - used, "%s%s=%.4f", used ? ", " : "",
                 il2cpp.field_name(value_fields[i]) ?: "?", value);
    }
    if (buffer_width && buffer_height)
        snprintf(buffer_values, sizeof buffer_values, "%.4fx%.4f", call_float(buffer_width, NULL), call_float(buffer_height, NULL));
}

static void find_statics(void *domain) {
    size_t count = 0;
    void **assemblies = il2cpp.assemblies(domain, &count);
    for (size_t i = 0; assemblies && i < count; i++) {
        void *image = il2cpp.image(assemblies[i]);
        if (!image) continue;
        void *settings = pipeline_getter ? NULL : il2cpp.class_from_name(image, "UnityEngine.Rendering", "GraphicsSettings");
        if (settings) {
            void *getter = il2cpp.method(settings, "get_currentRenderPipeline", 0);
            pipeline_getter = getter ?: il2cpp.method(settings, "get_renderPipelineAsset", 0);
        }
        void *buffers = buffer_looked_up ? NULL : il2cpp.class_from_name(image, "UnityEngine", "ScalableBufferManager");
        if (buffers) {
            buffer_looked_up = true;
            buffer_width = il2cpp.method(buffers, "get_widthScaleFactor", 0);
            buffer_height = il2cpp.method(buffers, "get_heightScaleFactor", 0);
            buffer_resize = il2cpp.method(buffers, "ResizeBuffers", 2);
        }
        void *cameras = camera_all ? NULL : il2cpp.class_from_name(image, "UnityEngine", "Camera");
        if (cameras) camera_all = il2cpp.method(cameras, "get_allCameras", 0);
        void *quality = quality_looked_up ? NULL : il2cpp.class_from_name(image, "UnityEngine", "QualitySettings");
        if (quality) {
            quality_looked_up = true;
            quality_names = il2cpp.method(quality, "get_names", 0);
            quality_get = il2cpp.method(quality, "GetQualityLevel", 0);
            quality_set = il2cpp.method(quality, "SetQualityLevel", 2);
        }
        if (pipeline_getter && buffer_looked_up && camera_all && quality_looked_up) return;
    }
}

/// The value a getter returned (boxed float), or -1.
static float unboxed_float(void *boxed) {
    if (!boxed) return -1;
    void *value = il2cpp.unbox ? il2cpp.unbox(boxed) : (char *)boxed + 2 * sizeof(void *);
    return value ? *(float *)value : -1;
}

static float call_float(void *method, void *object) {
    void *exception = NULL;
    float value = unboxed_float(il2cpp.invoke(method, object, NULL, &exception));
    return exception ? -1 : value;
}

/// Unity's dynamic resolution, when the game lowered it (Unity keeps it until ResizeBuffers again).
static void reset_buffers(void) {
    if (!buffer_width || !buffer_height || !buffer_resize) return;
    float width = call_float(buffer_width, NULL), height = call_float(buffer_height, NULL);
    if (width <= 0 || height <= 0 || (width >= 0.999f && height >= 0.999f)) return;
    float one = 1.0f, also = 1.0f;
    void *arguments[] = { &one, &also }, *exception = NULL;
    il2cpp.invoke(buffer_resize, NULL, arguments, &exception);
    if (!exception && buffer_resets++ == 0)
        os_log(os_log_create("io.mulg", "graphics"), "Unity dynamic resolution %.3fx%.3f -> 1.0", width, height);
}

MulgUnityRenderScaleState mulg_graphics_unity_render_scale_apply(BOOL enabled) {
    if (!enabled && !replaced) return MulgUnityRenderScaleNone;
    if (!resolve_il2cpp()) return MulgUnityRenderScaleUnavailable;
    void *domain = il2cpp.domain_get();
    if (!domain) return MulgUnityRenderScaleWaiting;
    // Before IL2CPP loaded its assemblies there is nothing to find; attach only once it runs.
    if (!pipeline_getter || !buffer_looked_up || !camera_all) find_statics(domain);
    if (!pipeline_getter) return MulgUnityRenderScaleWaiting;
    il2cpp.thread_attach(domain);
    if (enabled) reset_buffers();
    void *exception = NULL;
    void *pipeline = il2cpp.invoke(pipeline_getter, NULL, NULL, &exception);
    // No pipeline asset: the built-in renderer draws at the screen size, which forced resolution sets.
    if (exception || !pipeline) return MulgUnityRenderScaleNone;
    void *klass = il2cpp.object_class(pipeline);
    if (klass != scale_class) {
        scale_class = klass;
        setter_applied_to = NULL;
        get_scale = find_method(klass, "get_renderScale", 0);
        set_scale = find_method(klass, "set_renderScale", 1);
        if (!get_scale || !set_scale) { get_scale = NULL; set_scale = find_method(klass, "SetRenderScale", 1); }
        inspect_class(klass);
        const char *name = il2cpp.class_name ? il2cpp.class_name(klass) : NULL;
        snprintf(pipeline_name, sizeof pipeline_name, "%s", name ?: "?");
        snprintf(scale_path, sizeof scale_path, "%s", get_scale ? "renderScale property"
                 : set_scale ? "SetRenderScale" : scale_field ? "renderScale field" : "none");
        os_log(os_log_create("io.mulg", "graphics"), "Unity pipeline %{public}s: scale through %{public}s; members: %{public}s",
               pipeline_name, scale_path, scale_members);
    }
    apply_extra_scales(pipeline, enabled);
    if (diagnose_tick++ % 5 == 0) diagnose(pipeline);
    float current = -1, wanted;
    if (get_scale) current = call_float(get_scale, pipeline);
    else if (scale_field) il2cpp.field_get(pipeline, scale_field, &current);
    else if (set_scale) {
        // Setter only: set once per pipeline object, never given back (its value cannot be read).
        if (!enabled || setter_applied_to == pipeline) return enabled ? MulgUnityRenderScaleApplied : MulgUnityRenderScaleNone;
        float one = 1.0f;
        void *arguments[] = { &one };
        il2cpp.invoke(set_scale, pipeline, arguments, &exception);
        if (exception) return MulgUnityRenderScaleNone;
        setter_applied_to = pipeline;
        if (applied_count++ == 0)
            os_log(os_log_create("io.mulg", "graphics"), "Unity render scale -> 1.0 (%{public}s.SetRenderScale)", pipeline_name);
        return MulgUnityRenderScaleApplied;
    }
    if (!isfinite(current) || current <= 0) return MulgUnityRenderScaleNone;
    if (enabled) {
        if (fabsf(current - 1.0f) < 0.001f) return MulgUnityRenderScaleApplied;
        // The game's own choice (also a later one from its options), given back when switched off.
        game_scale = current;
        wanted = 1.0f;
    } else {
        replaced = false;
        if (game_scale <= 0 || fabsf(current - 1.0f) >= 0.001f) return MulgUnityRenderScaleNone;
        wanted = game_scale;
    }
    if (get_scale) {
        void *arguments[] = { &wanted };
        il2cpp.invoke(set_scale, pipeline, arguments, &exception);
        if (exception) return MulgUnityRenderScaleNone;
    } else {
        il2cpp.field_set(pipeline, scale_field, &wanted);
    }
    if (enabled) {
        replaced = true;
        if (applied_count++ == 0)
            os_log(os_log_create("io.mulg", "graphics"), "Unity render scale %.3f -> 1.0 (%{public}s, %{public}s)",
                   current, pipeline_name, scale_path);
    }
    return enabled ? MulgUnityRenderScaleApplied : MulgUnityRenderScaleNone;
}

/// Unity's own highest quality level (the last of QualitySettings.names), through SetQualityLevel with its
/// expensive changes applied, like the game's own options do. A game that sets its level back three times
/// in a launch keeps its choice: setting it again each second would hitch every time. Switched off, the
/// game's own level comes back if Mulg's is still the one in use.
enum { QualityLimit = 3 };
void mulg_graphics_unity_quality_apply(BOOL enabled) {
    if (!resolve_il2cpp()) return;
    void *domain = il2cpp.domain_get();
    if (!domain) return;
    if (!quality_looked_up) find_statics(domain);
    if (!quality_names || !quality_get || !quality_set) return;
    il2cpp.thread_attach(domain);
    void *names = call_object(quality_names, NULL);
    if (!names) return;
    // Il2CppArray: object header, bounds, max_length, then the elements.
    int count = (int)*(size_t *)((char *)names + 3 * sizeof(void *));
    int current = call_int(quality_get, NULL);
    quality_level = current;
    quality_highest = count - 1;
    if (count <= 0 || current < 0) return;
    int wanted;
    if (enabled) {
        if (current == count - 1 || quality_sets >= QualityLimit) return;
        quality_game = current;
        wanted = count - 1;
    } else {
        if (quality_game < 0 || current != count - 1) return;
        wanted = quality_game;
        quality_game = -1;
    }
    bool expensive = true;
    void *arguments[] = { &wanted, &expensive }, *exception = NULL;
    il2cpp.invoke(quality_set, NULL, arguments, &exception);
    if (exception) return;
    quality_level = wanted;
    if (enabled && quality_sets++ == 0)
        os_log(os_log_create("io.mulg", "graphics"), "Unity quality level %d -> highest %d", current, wanted);
}

NSDictionary *mulg_graphics_unity_render_scale_report(void) {
    return @{
        @"unityRenderPipeline": @(pipeline_name),
        @"unityRenderScalePath": @(scale_path),
        @"unityRenderScaleMembers": @(scale_members),
        @"unityGameRenderScale": @(game_scale),
        @"unityRenderScaleApplied": @(applied_count),
        @"unityDynamicResolutionResets": @(buffer_resets),
        @"unityExtraScalesRaised": @(extra_raised),
        @"unityQualityLevel": @(quality_level),
        @"unityQualityHighest": @(quality_highest),
        @"unityQualitySets": @(quality_sets),
        @"unityCameras": @(camera_report),
        @"unityPipelineScaleValues": @(scale_values),
        @"unityDynamicResolution": @(buffer_values),
    };
}
