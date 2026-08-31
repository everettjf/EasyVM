#include "CVirGLBridge.h"

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VIRGL_RENDERER_CALLBACKS_VERSION 4
#define VIRGL_RENDERER_USE_EGL 1
#define VIRGL_RENDERER_USE_SURFACELESS (1 << 3)
#define VIRGL_RENDERER_USE_GLES (1 << 4)

typedef void *virgl_renderer_gl_context;

struct virgl_renderer_gl_ctx_param {
    int version;
    bool shared;
    int major_ver;
    int minor_ver;
    int compat_ctx;
};

struct virgl_renderer_callbacks {
    int version;
    void (*write_fence)(void *, uint32_t);
    virgl_renderer_gl_context (*create_gl_context)(void *, int, struct virgl_renderer_gl_ctx_param *);
    void (*destroy_gl_context)(void *, virgl_renderer_gl_context);
    int (*make_current)(void *, int, virgl_renderer_gl_context);
    int (*get_drm_fd)(void *);
    void (*write_context_fence)(void *, uint32_t, uint32_t, uint64_t);
    int (*get_server_fd)(void *, uint32_t);
    void *(*get_egl_display)(void *);
};

struct virgl_renderer_resource_create_args {
    uint32_t handle;
    uint32_t target;
    uint32_t format;
    uint32_t bind;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t array_size;
    uint32_t last_level;
    uint32_t nr_samples;
    uint32_t flags;
};

struct virgl_renderer_resource_info {
    uint32_t handle;
    uint32_t virgl_format;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t flags;
    uint32_t tex_id;
    uint32_t stride;
    int drm_fourcc;
    int fd;
};

struct virgl_renderer_resource_info_ext {
    int version;
    struct virgl_renderer_resource_info base;
    bool has_dmabuf_export;
    int planes;
    uint64_t modifiers;
    void *d3d_tex2d;
};

struct virgl_box {
    uint32_t x;
    uint32_t y;
    uint32_t z;
    uint32_t w;
    uint32_t h;
    uint32_t d;
};

typedef int (*renderer_init_fn)(void *, int, struct virgl_renderer_callbacks *);
typedef void (*renderer_cleanup_fn)(void *);
typedef void (*renderer_poll_fn)(void);
typedef void (*get_cap_set_fn)(uint32_t, uint32_t *, uint32_t *);
typedef void (*fill_caps_fn)(uint32_t, uint32_t, void *);
typedef int (*resource_create_fn)(struct virgl_renderer_resource_create_args *, struct iovec *, uint32_t);
typedef void (*resource_unref_fn)(uint32_t);
typedef int (*resource_attach_iov_fn)(int, struct iovec *, int);
typedef void (*resource_detach_iov_fn)(int, struct iovec **, int *);
typedef int (*context_create_fn)(uint32_t, uint32_t, const char *);
typedef void (*context_destroy_fn)(uint32_t);
typedef void (*context_resource_fn)(int, int);
typedef int (*submit_fn)(void *, int, int);
typedef int (*create_fence_fn)(int, uint32_t);
typedef int (*transfer_fn)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                           struct virgl_box *, uint64_t, struct iovec *, int);
typedef int (*borrow_texture_fn)(int, struct virgl_renderer_resource_info_ext *);

static void *library;
static renderer_init_fn renderer_init;
static renderer_cleanup_fn renderer_cleanup;
static renderer_poll_fn renderer_poll;
static get_cap_set_fn get_cap_set;
static fill_caps_fn fill_caps;
static resource_create_fn resource_create;
static resource_unref_fn resource_unref;
static resource_attach_iov_fn resource_attach_iov;
static resource_detach_iov_fn resource_detach_iov;
static context_create_fn context_create;
static context_destroy_fn context_destroy;
static context_resource_fn context_attach_resource;
static context_resource_fn context_detach_resource;
static submit_fn submit_cmd;
static create_fence_fn create_fence;
static transfer_fn transfer_write;
static transfer_fn transfer_read;
static borrow_texture_fn borrow_texture_for_scanout;
static char last_error[512];
static int renderer_cookie;
static struct virgl_renderer_callbacks renderer_callbacks;

typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLContext;
typedef void *EGLSurface;
typedef int EGLBoolean;
typedef int EGLint;
typedef intptr_t EGLAttrib;
typedef void *EGLImage;

#define EGL_NONE 0x3038
#define EGL_DEFAULT_DISPLAY ((void *)0)
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
#define EGL_NO_SURFACE ((EGLSurface)0)
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_SURFACE_TYPE 0x3033
#define EGL_PBUFFER_BIT 0x0001
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_OPENGL_ES3_BIT 0x0040
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#define EGL_METAL_TEXTURE_ANGLE 0x34A7

#define GL_TEXTURE_2D 0x0DE1
#define GL_READ_FRAMEBUFFER 0x8CA8
#define GL_DRAW_FRAMEBUFFER 0x8CA9
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_NEAREST 0x2600

typedef EGLDisplay (*egl_get_platform_display_fn)(EGLint, void *, const EGLAttrib *);
typedef EGLBoolean (*egl_initialize_fn)(EGLDisplay, EGLint *, EGLint *);
typedef EGLBoolean (*egl_bind_api_fn)(EGLint);
typedef EGLBoolean (*egl_choose_config_fn)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
typedef EGLSurface (*egl_create_pbuffer_surface_fn)(EGLDisplay, EGLConfig, const EGLint *);
typedef EGLContext (*egl_create_context_fn)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
typedef EGLContext (*egl_get_current_context_fn)(void);
typedef EGLBoolean (*egl_destroy_context_fn)(EGLDisplay, EGLContext);
typedef EGLBoolean (*egl_make_current_fn)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
typedef EGLint (*egl_get_error_fn)(void);
typedef EGLImage (*egl_create_image_fn)(EGLDisplay, EGLContext, EGLint, void *, const EGLAttrib *);
typedef EGLBoolean (*egl_destroy_image_fn)(EGLDisplay, EGLImage);
typedef void (*gl_uint_fn)(int, unsigned int *);
typedef void (*gl_bind_fn)(unsigned int, unsigned int);
typedef void (*gl_framebuffer_texture_fn)(unsigned int, unsigned int, unsigned int, unsigned int, int);
typedef void (*gl_blit_framebuffer_fn)(int, int, int, int, int, int, int, int, unsigned int, unsigned int);
typedef void (*gl_image_target_fn)(unsigned int, void *);
typedef void (*gl_flush_fn)(void);
typedef void (*gl_finish_fn)(void);

static void *egl_library;
static EGLDisplay egl_display;
static EGLConfig egl_config;
static EGLSurface egl_surface;
static EGLContext egl_root_context;
static EGLContext last_created_context;
#define MAX_TRACKED_CONTEXTS 65536
static EGLContext guest_contexts[MAX_TRACKED_CONTEXTS];
static egl_get_platform_display_fn egl_get_platform_display;
static egl_initialize_fn egl_initialize;
static egl_bind_api_fn egl_bind_api;
static egl_choose_config_fn egl_choose_config;
static egl_create_pbuffer_surface_fn egl_create_pbuffer_surface;
static egl_create_context_fn egl_create_context;
static egl_get_current_context_fn egl_get_current_context;
static egl_destroy_context_fn egl_destroy_context;
static egl_make_current_fn egl_make_current;
static egl_get_error_fn egl_get_error;
static egl_create_image_fn egl_create_image;
static egl_destroy_image_fn egl_destroy_image;
static void *gles_library;
static gl_uint_fn gl_gen_textures;
static gl_uint_fn gl_delete_textures;
static gl_bind_fn gl_bind_texture;
static gl_uint_fn gl_gen_framebuffers;
static gl_uint_fn gl_delete_framebuffers;
static gl_bind_fn gl_bind_framebuffer;
static gl_framebuffer_texture_fn gl_framebuffer_texture_2d;
static gl_blit_framebuffer_fn gl_blit_framebuffer;
static gl_image_target_fn gl_image_target_texture_2d;
static gl_flush_fn gl_flush;
static gl_finish_fn gl_finish;

#define FENCE_RING_SIZE 1024
static uint32_t completed_fences[FENCE_RING_SIZE];
static uint32_t fence_read_index;
static uint32_t fence_write_index;

static void set_error(const char *message) {
    snprintf(last_error, sizeof(last_error), "%s", message ? message : "unknown error");
}

static void write_fence_callback(void *cookie, uint32_t fence_id) {
    (void)cookie;
    uint32_t next = (fence_write_index + 1) % FENCE_RING_SIZE;
    if (next == fence_read_index) {
        set_error("completed fence ring overflow");
        return;
    }
    completed_fences[fence_write_index] = fence_id;
    fence_write_index = next;
}

static int load_symbol(void **destination, const char *name) {
    *destination = dlsym(library, name);
    if (!*destination) {
        set_error(dlerror());
        return -1;
    }
    return 0;
}

static int load_egl_symbol(void **destination, const char *name) {
    *destination = dlsym(egl_library, name);
    if (!*destination) {
        set_error(dlerror());
        return -1;
    }
    return 0;
}

static int load_gles_symbol(void **destination, const char *name) {
    *destination = dlsym(gles_library, name);
    if (!*destination) {
        set_error(dlerror());
        return -1;
    }
    return 0;
}

static int initialize_angle(const char *virgl_path) {
    char egl_path[PATH_MAX];
    const char *slash = strrchr(virgl_path, '/');
    if (!slash || (size_t)(slash - virgl_path) + strlen("/libEGL.dylib") + 1 > sizeof(egl_path)) {
        set_error("virglrenderer path cannot be used to locate libEGL.dylib");
        return -1;
    }
    size_t directory_length = (size_t)(slash - virgl_path);
    memcpy(egl_path, virgl_path, directory_length);
    strcpy(egl_path + directory_length, "/libEGL.dylib");
    egl_library = dlopen(egl_path, RTLD_NOW | RTLD_GLOBAL);
    if (!egl_library) {
        set_error(dlerror());
        return -1;
    }
#define LOAD_EGL(field, symbol) if (load_egl_symbol((void **)&field, symbol) != 0) return -1
    LOAD_EGL(egl_get_platform_display, "eglGetPlatformDisplay");
    LOAD_EGL(egl_initialize, "eglInitialize");
    LOAD_EGL(egl_bind_api, "eglBindAPI");
    LOAD_EGL(egl_choose_config, "eglChooseConfig");
    LOAD_EGL(egl_create_pbuffer_surface, "eglCreatePbufferSurface");
    LOAD_EGL(egl_create_context, "eglCreateContext");
    LOAD_EGL(egl_get_current_context, "eglGetCurrentContext");
    LOAD_EGL(egl_destroy_context, "eglDestroyContext");
    LOAD_EGL(egl_make_current, "eglMakeCurrent");
    LOAD_EGL(egl_get_error, "eglGetError");
    LOAD_EGL(egl_create_image, "eglCreateImage");
    LOAD_EGL(egl_destroy_image, "eglDestroyImage");
#undef LOAD_EGL

    char gles_path[PATH_MAX];
    memcpy(gles_path, virgl_path, directory_length);
    strcpy(gles_path + directory_length, "/libGLESv2.dylib");
    gles_library = dlopen(gles_path, RTLD_NOW | RTLD_GLOBAL);
    if (!gles_library) {
        set_error(dlerror());
        return -1;
    }
#define LOAD_GLES(field, symbol) if (load_gles_symbol((void **)&field, symbol) != 0) return -1
    LOAD_GLES(gl_gen_textures, "glGenTextures");
    LOAD_GLES(gl_delete_textures, "glDeleteTextures");
    LOAD_GLES(gl_bind_texture, "glBindTexture");
    LOAD_GLES(gl_gen_framebuffers, "glGenFramebuffers");
    LOAD_GLES(gl_delete_framebuffers, "glDeleteFramebuffers");
    LOAD_GLES(gl_bind_framebuffer, "glBindFramebuffer");
    LOAD_GLES(gl_framebuffer_texture_2d, "glFramebufferTexture2D");
    LOAD_GLES(gl_blit_framebuffer, "glBlitFramebuffer");
    LOAD_GLES(gl_image_target_texture_2d, "glEGLImageTargetTexture2DOES");
    LOAD_GLES(gl_flush, "glFlush");
    LOAD_GLES(gl_finish, "glFinish");
#undef LOAD_GLES

    const EGLAttrib display_attributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE
    };
    egl_display = egl_get_platform_display(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY,
                                           display_attributes);
    EGLint major = 0, minor = 0;
    if (egl_display == EGL_NO_DISPLAY || !egl_initialize(egl_display, &major, &minor)) {
        snprintf(last_error, sizeof(last_error), "ANGLE Metal eglInitialize failed: 0x%x", egl_get_error());
        return -1;
    }
    if (!egl_bind_api(EGL_OPENGL_ES_API)) {
        snprintf(last_error, sizeof(last_error), "ANGLE eglBindAPI failed: 0x%x", egl_get_error());
        return -1;
    }
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT | EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLint config_count = 0;
    if (!egl_choose_config(egl_display, config_attributes, &egl_config, 1, &config_count)
        || config_count != 1) {
        snprintf(last_error, sizeof(last_error), "ANGLE eglChooseConfig failed: 0x%x", egl_get_error());
        return -1;
    }
    const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    egl_surface = egl_create_pbuffer_surface(egl_display, egl_config, surface_attributes);
    if (egl_surface == EGL_NO_SURFACE) {
        snprintf(last_error, sizeof(last_error), "ANGLE eglCreatePbufferSurface failed: 0x%x", egl_get_error());
        return -1;
    }
    fprintf(stderr, "[stage3] ANGLE Metal EGL %d.%d initialized\n", major, minor);
    return 0;
}

static virgl_renderer_gl_context create_gl_context_callback(
    void *cookie, int scanout_idx, struct virgl_renderer_gl_ctx_param *param
) {
    (void)cookie;
    (void)scanout_idx;
    EGLContext shared = param->shared ? egl_root_context : EGL_NO_CONTEXT;
    const EGLint attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, param->major_ver >= 3 ? 3 : 2,
        EGL_NONE
    };
    EGLContext context = egl_create_context(egl_display, egl_config, shared, attributes);
    last_created_context = context;
    if (context == EGL_NO_CONTEXT) {
        snprintf(last_error, sizeof(last_error), "ANGLE eglCreateContext failed: 0x%x", egl_get_error());
        fprintf(stderr, "[stage3] %s\n", last_error);
    } else if (egl_root_context == EGL_NO_CONTEXT) {
        egl_root_context = context;
    }
    fprintf(stderr, "[stage3] create GLES context requested=%d.%d shared=%d result=%p\n",
            param->major_ver, param->minor_ver, param->shared, context);
    return context;
}

static void destroy_gl_context_callback(void *cookie, virgl_renderer_gl_context context) {
    (void)cookie;
    if (context) {
        egl_destroy_context(egl_display, context);
        if (context == egl_root_context) egl_root_context = EGL_NO_CONTEXT;
    }
}

static int make_current_callback(void *cookie, int scanout_idx, virgl_renderer_gl_context context) {
    (void)cookie;
    (void)scanout_idx;
    EGLSurface surface = context ? egl_surface : EGL_NO_SURFACE;
    if (egl_make_current(egl_display, surface, surface, context)) return 0;
    fprintf(stderr, "[stage3] eglMakeCurrent failed: 0x%x context=%p\n", egl_get_error(), context);
    return -1;
}

static void *get_egl_display_callback(void *cookie) {
    (void)cookie;
    return egl_display;
}

int vzvg_renderer_load(const char *dylib_path) {
    if (library) return 0;
    if (initialize_angle(dylib_path) != 0) return -1;
    library = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        set_error(dlerror());
        return -1;
    }

#define LOAD(field, symbol) if (load_symbol((void **)&field, symbol) != 0) return -1
    LOAD(renderer_init, "virgl_renderer_init");
    LOAD(renderer_cleanup, "virgl_renderer_cleanup");
    LOAD(renderer_poll, "virgl_renderer_poll");
    LOAD(get_cap_set, "virgl_renderer_get_cap_set");
    LOAD(fill_caps, "virgl_renderer_fill_caps");
    LOAD(resource_create, "virgl_renderer_resource_create");
    LOAD(resource_unref, "virgl_renderer_resource_unref");
    LOAD(resource_attach_iov, "virgl_renderer_resource_attach_iov");
    LOAD(resource_detach_iov, "virgl_renderer_resource_detach_iov");
    LOAD(context_create, "virgl_renderer_context_create");
    LOAD(context_destroy, "virgl_renderer_context_destroy");
    LOAD(context_attach_resource, "virgl_renderer_ctx_attach_resource");
    LOAD(context_detach_resource, "virgl_renderer_ctx_detach_resource");
    LOAD(submit_cmd, "virgl_renderer_submit_cmd");
    LOAD(create_fence, "virgl_renderer_create_fence");
    LOAD(transfer_write, "virgl_renderer_transfer_write_iov");
    LOAD(transfer_read, "virgl_renderer_transfer_read_iov");
    LOAD(borrow_texture_for_scanout, "virgl_renderer_borrow_texture_for_scanout");
#undef LOAD
    return 0;
}

int vzvg_renderer_initialize(void) {
    if (!renderer_init) {
        set_error("virglrenderer is not loaded");
        return -1;
    }
    memset(&renderer_callbacks, 0, sizeof(renderer_callbacks));
    renderer_callbacks.version = VIRGL_RENDERER_CALLBACKS_VERSION;
    renderer_callbacks.write_fence = write_fence_callback;
    renderer_callbacks.create_gl_context = create_gl_context_callback;
    renderer_callbacks.destroy_gl_context = destroy_gl_context_callback;
    renderer_callbacks.make_current = make_current_callback;
    renderer_callbacks.get_egl_display = get_egl_display_callback;
    // The pinned macOS virglrenderer is intentionally built without its Linux
    // EGL winsys. Supplying no winsys flag makes it use the caller-provided
    // ANGLE/Metal context callbacks, which is the path used by QEMU Cocoa.
    int flags = 0;
    int result = renderer_init(&renderer_cookie, flags, &renderer_callbacks);
    if (result != 0) {
        snprintf(last_error, sizeof(last_error), "virgl_renderer_init returned %d", result);
    } else {
        // EGL contexts are thread-affine while current. Initialization occurs
        // on the main thread, but virtio queue work runs on the device queue.
        egl_make_current(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    return result;
}

void vzvg_renderer_cleanup(void) { if (renderer_cleanup) renderer_cleanup(&renderer_cookie); }
void vzvg_renderer_poll(void) { if (renderer_poll) renderer_poll(); }

void vzvg_renderer_get_cap_set(uint32_t set, uint32_t *max_version, uint32_t *max_size) {
    get_cap_set(set, max_version, max_size);
}
void vzvg_renderer_fill_caps(uint32_t set, uint32_t version, void *caps) {
    if (egl_root_context != EGL_NO_CONTEXT) {
        egl_make_current(egl_display, egl_surface, egl_surface, egl_root_context);
    }
    fill_caps(set, version, caps);
    if (egl_display != EGL_NO_DISPLAY) {
        egl_make_current(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
}

static void release_current_context(void) {
    if (egl_display != EGL_NO_DISPLAY) {
        egl_make_current(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
}

static int make_root_context_current(void) {
    if (egl_root_context == EGL_NO_CONTEXT) return -1;
    return egl_make_current(egl_display, egl_surface, egl_surface, egl_root_context) ? 0 : -1;
}

static int make_guest_context_current(uint32_t context_id) {
    if (context_id >= MAX_TRACKED_CONTEXTS || guest_contexts[context_id] == EGL_NO_CONTEXT) return -1;
    return egl_make_current(
        egl_display, egl_surface, egl_surface, guest_contexts[context_id]
    ) ? 0 : -1;
}

int vzvg_renderer_resource_create(const struct vzvg_resource_create_args *args) {
    if (make_root_context_current() != 0) return -1;
    int result = resource_create((struct virgl_renderer_resource_create_args *)args, NULL, 0);
    release_current_context();
    return result;
}
void vzvg_renderer_resource_unref(uint32_t resource_id) {
    if (make_root_context_current() != 0) return;
    resource_unref(resource_id);
    release_current_context();
}
int vzvg_renderer_resource_attach_iov(uint32_t resource_id, struct iovec *iov, int iov_count) {
    return resource_attach_iov((int)resource_id, iov, iov_count);
}
void vzvg_renderer_resource_detach_iov(uint32_t resource_id) {
    struct iovec *iov = NULL;
    int count = 0;
    resource_detach_iov((int)resource_id, &iov, &count);
}

int vzvg_renderer_context_create(uint32_t context_id, uint32_t name_length, const char *name) {
    last_created_context = EGL_NO_CONTEXT;
    int result = context_create(context_id, name_length, name);
    if (result == 0 && context_id < MAX_TRACKED_CONTEXTS) {
        guest_contexts[context_id] = last_created_context;
    }
    release_current_context();
    return result;
}
void vzvg_renderer_context_destroy(uint32_t context_id) {
    if (make_guest_context_current(context_id) != 0) return;
    context_destroy(context_id);
    if (context_id < MAX_TRACKED_CONTEXTS) guest_contexts[context_id] = EGL_NO_CONTEXT;
    release_current_context();
}
void vzvg_renderer_context_attach_resource(uint32_t context_id, uint32_t resource_id) {
    context_attach_resource((int)context_id, (int)resource_id);
}
void vzvg_renderer_context_detach_resource(uint32_t context_id, uint32_t resource_id) {
    context_detach_resource((int)context_id, (int)resource_id);
}
int vzvg_renderer_submit(void *commands, uint32_t context_id, uint32_t dword_count) {
    if (make_guest_context_current(context_id) != 0) return -1;
    int result = submit_cmd(commands, (int)context_id, (int)dword_count);
    // Scanout presentation happens from the shared root GL context. Submit the
    // producer context's pending work before switching contexts so the root
    // blit observes updates immediately instead of waiting for unrelated guest
    // activity (for example a later pointer-damage command) to flush them.
    if (result == 0) gl_finish();
    release_current_context();
    return result;
}
int vzvg_renderer_create_fence(uint32_t fence_id, uint32_t context_id) {
    int current_result = context_id == 0
        ? make_root_context_current()
        : make_guest_context_current(context_id);
    if (current_result != 0) return -1;
    int result = create_fence((int)fence_id, context_id);
    release_current_context();
    return result;
}
int vzvg_renderer_pop_completed_fence(uint32_t *fence_id) {
    if (fence_read_index == fence_write_index) return 0;
    *fence_id = completed_fences[fence_read_index];
    fence_read_index = (fence_read_index + 1) % FENCE_RING_SIZE;
    return 1;
}

int vzvg_renderer_borrow_scanout_texture(uint32_t resource_id,
                                         struct vzvg_scanout_texture_info *info) {
    if (!info || make_root_context_current() != 0) return -1;
    struct virgl_renderer_resource_info_ext native_info = {0};
    native_info.version = 0;
    int result = borrow_texture_for_scanout((int)resource_id, &native_info);
    if (result == 0) {
        info->texture_id = native_info.base.tex_id;
        info->format = native_info.base.virgl_format;
        info->width = native_info.base.width;
        info->height = native_info.base.height;
        info->stride = native_info.base.stride;
    }
    release_current_context();
    return result;
}

int vzvg_renderer_present_scanout(uint32_t resource_id,
                                  void *metal_texture,
                                  uint32_t destination_width,
                                  uint32_t destination_height) {
    if (!metal_texture || destination_width == 0 || destination_height == 0
        || make_root_context_current() != 0) return -1;

    struct virgl_renderer_resource_info_ext source = {0};
    source.version = 0;
    if (borrow_texture_for_scanout((int)resource_id, &source) != 0) {
        release_current_context();
        return -1;
    }

    EGLImage image = egl_create_image(
        egl_display, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, metal_texture, NULL
    );
    if (!image) {
        snprintf(last_error, sizeof(last_error), "eglCreateImage(Metal texture) failed: 0x%x", egl_get_error());
        release_current_context();
        return -1;
    }

    unsigned int destination_texture = 0;
    unsigned int read_framebuffer = 0;
    unsigned int draw_framebuffer = 0;
    gl_gen_textures(1, &destination_texture);
    gl_bind_texture(GL_TEXTURE_2D, destination_texture);
    gl_image_target_texture_2d(GL_TEXTURE_2D, image);

    gl_gen_framebuffers(1, &read_framebuffer);
    gl_gen_framebuffers(1, &draw_framebuffer);
    gl_bind_framebuffer(GL_READ_FRAMEBUFFER, read_framebuffer);
    gl_framebuffer_texture_2d(
        GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, source.base.tex_id, 0
    );
    gl_bind_framebuffer(GL_DRAW_FRAMEBUFFER, draw_framebuffer);
    gl_framebuffer_texture_2d(
        GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, destination_texture, 0
    );
    gl_blit_framebuffer(
        0, 0, (int)source.base.width, (int)source.base.height,
        0, 0, (int)destination_width, (int)destination_height,
        GL_COLOR_BUFFER_BIT, GL_NEAREST
    );
    // This is a correctness probe for ANGLE's cross-context Metal texture
    // visibility. Ensure both the guest producer and the root-context blit are
    // complete before AppKit presents the CAMetalDrawable. Once validated this
    // blocking synchronization can be replaced with shared GPU fences.
    gl_finish();

    gl_bind_framebuffer(GL_READ_FRAMEBUFFER, 0);
    gl_bind_framebuffer(GL_DRAW_FRAMEBUFFER, 0);
    gl_delete_framebuffers(1, &read_framebuffer);
    gl_delete_framebuffers(1, &draw_framebuffer);
    gl_delete_textures(1, &destination_texture);
    egl_destroy_image(egl_display, image);
    release_current_context();
    return 0;
}

int vzvg_renderer_transfer_write(uint32_t resource_id, uint32_t context_id,
                                 uint32_t level, uint32_t stride, uint32_t layer_stride,
                                 const struct vzvg_box *box, uint64_t offset,
                                 struct iovec *iov, int iov_count) {
    if ((context_id == 0 ? make_root_context_current() : make_guest_context_current(context_id)) != 0) return -1;
    int result = transfer_write(resource_id, context_id, level, stride, layer_stride,
                                (struct virgl_box *)box, offset, iov, iov_count);
    release_current_context();
    return result;
}
int vzvg_renderer_transfer_read(uint32_t resource_id, uint32_t context_id,
                                uint32_t level, uint32_t stride, uint32_t layer_stride,
                                const struct vzvg_box *box, uint64_t offset,
                                struct iovec *iov, int iov_count) {
    if ((context_id == 0 ? make_root_context_current() : make_guest_context_current(context_id)) != 0) return -1;
    int result = transfer_read(resource_id, context_id, level, stride, layer_stride,
                               (struct virgl_box *)box, offset, iov, iov_count);
    release_current_context();
    return result;
}

const char *vzvg_renderer_last_error(void) { return last_error; }
