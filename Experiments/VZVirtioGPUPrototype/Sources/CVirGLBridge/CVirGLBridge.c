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
typedef int (*create_context_fence_fn)(uint32_t, uint32_t, uint32_t, uint64_t);
typedef int (*transfer_fn)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                           struct virgl_box *, uint64_t, struct iovec *, int);
typedef int (*borrow_texture_fn)(int, struct virgl_renderer_resource_info_ext *);
typedef void (*force_context_zero_fn)(void);

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
static create_context_fence_fn create_context_fence;
static transfer_fn transfer_write;
static transfer_fn transfer_read;
static borrow_texture_fn borrow_texture_for_scanout;
static force_context_zero_fn force_context_zero;
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
typedef void *EGLSync;

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
#define EGL_SYNC_FENCE 0x30F9

#define GL_TEXTURE_2D 0x0DE1
#define GL_READ_FRAMEBUFFER 0x8CA8
#define GL_DRAW_FRAMEBUFFER 0x8CA9
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_NEAREST 0x2600
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_NO_ERROR 0
#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401

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
typedef EGLSync (*egl_create_sync_fn)(EGLDisplay, EGLint, const EGLAttrib *);
typedef EGLBoolean (*egl_destroy_sync_fn)(EGLDisplay, EGLSync);
typedef EGLBoolean (*egl_wait_sync_fn)(EGLDisplay, EGLSync, EGLint);
typedef void (*gl_uint_fn)(int, unsigned int *);
typedef void (*gl_bind_fn)(unsigned int, unsigned int);
typedef void (*gl_framebuffer_texture_fn)(unsigned int, unsigned int, unsigned int, unsigned int, int);
typedef void (*gl_blit_framebuffer_fn)(int, int, int, int, int, int, int, int, unsigned int, unsigned int);
typedef void (*gl_image_target_fn)(unsigned int, void *);
typedef void (*gl_flush_fn)(void);
typedef void (*gl_finish_fn)(void);
typedef unsigned int (*gl_get_error_fn)(void);
typedef unsigned int (*gl_check_framebuffer_status_fn)(unsigned int);
typedef void (*gl_read_pixels_fn)(int, int, int, int, unsigned int, unsigned int, void *);

static void *egl_library;
static EGLDisplay egl_display;
static EGLConfig egl_config;
static EGLSurface egl_surface;
static EGLContext egl_root_context;
#define MAX_TRACKED_CONTEXTS 65536
static EGLSync guest_context_syncs[MAX_TRACKED_CONTEXTS];
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
static egl_create_sync_fn egl_create_sync;
static egl_destroy_sync_fn egl_destroy_sync;
static egl_wait_sync_fn egl_wait_sync;
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
static gl_get_error_fn gl_get_error;
static gl_check_framebuffer_status_fn gl_check_framebuffer_status;
static gl_read_pixels_fn gl_read_pixels;
static bool diagnostics_enabled;
static uint64_t presentation_count;
static uint64_t scanout_signature;
static uint64_t scanout_signature_generation;

#define FENCE_RING_SIZE 1024
static uint32_t completed_fences[FENCE_RING_SIZE];
static uint32_t fence_read_index;
static uint32_t fence_write_index;

static void set_error(const char *message) {
    snprintf(last_error, sizeof(last_error), "%s", message ? message : "unknown error");
}

static void record_completed_fence(uint32_t fence_id) {
    uint32_t next = (fence_write_index + 1) % FENCE_RING_SIZE;
    if (next == fence_read_index) {
        set_error("completed fence ring overflow");
        return;
    }
    completed_fences[fence_write_index] = fence_id;
    fence_write_index = next;
}

static void write_fence_callback(void *cookie, uint32_t fence_id) {
    (void)cookie;
    record_completed_fence(fence_id);
}

static void write_context_fence_callback(void *cookie,
                                         uint32_t context_id,
                                         uint32_t ring_index,
                                         uint64_t fence_id) {
    (void)cookie;
    (void)context_id;
    (void)ring_index;
    // EZVM allocates host fence IDs in the non-zero uint32_t range before
    // passing them to virgl_renderer_context_create_fence. Completion
    // reports that same ID through the version-4 callback.
    if (fence_id == 0 || fence_id > UINT32_MAX) {
        set_error("invalid completed context fence id");
        return;
    }
    record_completed_fence((uint32_t)fence_id);
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
    LOAD_EGL(egl_create_sync, "eglCreateSync");
    LOAD_EGL(egl_destroy_sync, "eglDestroySync");
    LOAD_EGL(egl_wait_sync, "eglWaitSync");
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
    LOAD_GLES(gl_get_error, "glGetError");
    LOAD_GLES(gl_check_framebuffer_status, "glCheckFramebufferStatus");
    LOAD_GLES(gl_read_pixels, "glReadPixels");
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
    if (context == EGL_NO_CONTEXT) {
        snprintf(last_error, sizeof(last_error), "ANGLE eglCreateContext failed: 0x%x", egl_get_error());
        fprintf(stderr, "[stage3] %s\n", last_error);
    } else if (egl_root_context == EGL_NO_CONTEXT) {
        egl_root_context = context;
    }
    fprintf(stderr,
            "[stage3] create GLES context requested=%d.%d requestedShared=%d actualShared=%d result=%p\n",
            param->major_ver, param->minor_ver, param->shared,
            shared != EGL_NO_CONTEXT, context);
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
    LOAD(create_context_fence, "virgl_renderer_context_create_fence");
    LOAD(transfer_write, "virgl_renderer_transfer_write_iov");
    LOAD(transfer_read, "virgl_renderer_transfer_read_iov");
    LOAD(borrow_texture_for_scanout, "virgl_renderer_borrow_texture_for_scanout");
    LOAD(force_context_zero, "virgl_renderer_force_ctx_0");
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
    renderer_callbacks.write_context_fence = write_context_fence_callback;
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
    }
    return result;
}

void vzvg_renderer_cleanup(void) { if (renderer_cleanup) renderer_cleanup(&renderer_cookie); }
void vzvg_renderer_poll(void) { if (renderer_poll) renderer_poll(); }

void vzvg_renderer_get_cap_set(uint32_t set, uint32_t *max_version, uint32_t *max_size) {
    get_cap_set(set, max_version, max_size);
}
void vzvg_renderer_fill_caps(uint32_t set, uint32_t version, void *caps) {
    force_context_zero();
    fill_caps(set, version, caps);
}

int vzvg_renderer_resource_create(const struct vzvg_resource_create_args *args) {
    force_context_zero();
    return resource_create((struct virgl_renderer_resource_create_args *)args, NULL, 0);
}
void vzvg_renderer_resource_unref(uint32_t resource_id) {
    force_context_zero();
    resource_unref(resource_id);
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
    return context_create(context_id, name_length, name);
}
void vzvg_renderer_context_destroy(uint32_t context_id) {
    if (context_id < MAX_TRACKED_CONTEXTS && guest_context_syncs[context_id]) {
        egl_destroy_sync(egl_display, guest_context_syncs[context_id]);
        guest_context_syncs[context_id] = NULL;
    }
    context_destroy(context_id);
}
void vzvg_renderer_context_attach_resource(uint32_t context_id, uint32_t resource_id) {
    context_attach_resource((int)context_id, (int)resource_id);
}
void vzvg_renderer_context_detach_resource(uint32_t context_id, uint32_t resource_id) {
    context_detach_resource((int)context_id, (int)resource_id);
}
int vzvg_renderer_submit(void *commands, uint32_t context_id, uint32_t dword_count) {
    int result = submit_cmd(commands, (int)context_id, (int)dword_count);
    // Scanout presentation happens from the shared root GL context. Submit the
    // producer context's pending work before switching contexts so the root
    // blit observes updates immediately instead of waiting for unrelated guest
    // activity (for example a later pointer-damage command) to flush them.
    if (result == 0) {
        gl_flush();
        if (context_id < MAX_TRACKED_CONTEXTS) {
            EGLSync sync = egl_create_sync(egl_display, EGL_SYNC_FENCE, NULL);
            if (sync) {
                if (guest_context_syncs[context_id]) {
                    // A newer fence in the same GL command stream subsumes the
                    // earlier one, so it is safe to keep only the latest fence.
                    egl_destroy_sync(egl_display, guest_context_syncs[context_id]);
                }
                guest_context_syncs[context_id] = sync;
                gl_flush();
            }
        }
    }
    return result;
}
int vzvg_renderer_create_fence(uint32_t fence_id, uint32_t context_id) {
    // The legacy API always creates a ctx0 fence; use the v3 per-context API
    // for guest 3D contexts so the sync object is created and retired in the
    // same ANGLE command stream. The v4 callback reports its UInt64 cookie.
    int result;
    if (context_id == 0) {
        // The external ANGLE/Metal winsys does not reliably retire
        // virglrenderer's legacy ctx0 GLsync. ctx0 commands are synchronous
        // resource/control operations, not the hot rendering submission path:
        // finish their root-context work explicitly, then complete the host
        // fence locally. Guest 3D contexts remain fully asynchronous below.
        force_context_zero();
        gl_finish();
        record_completed_fence(fence_id);
        result = 0;
    } else {
        result = create_context_fence(context_id, 0, 0, fence_id);
    }
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
    if (!info) return -1;
    // Keep virglrenderer's internal current-context bookkeeping aligned with
    // the EGL root context. QEMU does the same before publishing a scanout;
    // omitting it works only until a guest 3D context becomes current.
    force_context_zero();
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
    return result;
}

int vzvg_renderer_present_scanout(uint32_t resource_id,
                                  void *metal_texture,
                                  uint32_t source_x,
                                  uint32_t source_y,
                                  uint32_t source_width,
                                  uint32_t source_height,
                                  uint32_t destination_width,
                                  uint32_t destination_height) {
    if (!metal_texture || source_width == 0 || source_height == 0 ||
        destination_width == 0 || destination_height == 0) return -1;

    // Switch through virglrenderer so its context bookkeeping and ANGLE's
    // actual current context remain identical, then enqueue GPU-side waits for
    // producer contexts. A CPU-side EGL_FOREVER wait can stall presentation
    // indefinitely when CAMetalLayer replaces its drawable during a resize.
    force_context_zero();
    for (uint32_t context_id = 0; context_id < MAX_TRACKED_CONTEXTS; context_id++) {
        EGLSync sync = guest_context_syncs[context_id];
        if (!sync) continue;
        if (!egl_wait_sync(egl_display, sync, 0)) {
            snprintf(last_error, sizeof(last_error),
                     "guest render fence wait failed: egl=0x%x context=%u",
                     egl_get_error(), context_id);
            egl_destroy_sync(egl_display, sync);
            guest_context_syncs[context_id] = NULL;
            return -1;
        }
        egl_destroy_sync(egl_display, sync);
        guest_context_syncs[context_id] = NULL;
    }

    struct virgl_renderer_resource_info_ext source = {0};
    source.version = 0;
    if (borrow_texture_for_scanout((int)resource_id, &source) != 0) {
        return -1;
    }
    if (source_x > source.base.width || source_y > source.base.height ||
        source_width > source.base.width - source_x ||
        source_height > source.base.height - source_y) {
        snprintf(last_error, sizeof(last_error),
                 "scanout rectangle out of bounds: resource=%u rect=%u,%u %ux%u texture=%ux%u",
                 resource_id, source_x, source_y, source_width, source_height,
                 source.base.width, source.base.height);
        return -1;
    }

    EGLImage image = egl_create_image(
        egl_display, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, metal_texture, NULL
    );
    if (!image) {
        snprintf(last_error, sizeof(last_error), "eglCreateImage(Metal texture) failed: 0x%x", egl_get_error());
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
    unsigned int read_status = gl_check_framebuffer_status(GL_READ_FRAMEBUFFER);
    if (read_status != GL_FRAMEBUFFER_COMPLETE) {
        snprintf(last_error, sizeof(last_error),
                 "source framebuffer incomplete: 0x%x resource=%u texture=%u format=%u size=%ux%u",
                 read_status, resource_id, source.base.tex_id, source.base.virgl_format,
                 source.base.width, source.base.height);
        goto cleanup;
    }
    presentation_count++;
    if (diagnostics_enabled && presentation_count % 60 == 1) {
        // Sample a stable 8x8 grid instead of reading the entire scanout. This
        // distinguishes runtime UI changes while limiting the synchronous
        // diagnostic readback to 64 pixels per second.
        uint64_t signature = UINT64_C(1469598103934665603);
        for (uint32_t row = 0; row < 8; row++) {
            for (uint32_t column = 0; column < 8; column++) {
                uint32_t sample_x = source_x + ((2 * column + 1) * source_width) / 16;
                uint32_t sample_y = source_y + ((2 * row + 1) * source_height) / 16;
                unsigned char pixel[4] = {0};
                gl_read_pixels((int)sample_x, (int)sample_y, 1, 1,
                               GL_RGBA, GL_UNSIGNED_BYTE, pixel);
                for (size_t component = 0; component < sizeof(pixel); component++) {
                    signature ^= pixel[component];
                    signature *= UINT64_C(1099511628211);
                }
            }
        }
        if (signature != scanout_signature) {
            scanout_signature = signature;
            scanout_signature_generation++;
        }
    }
    gl_bind_framebuffer(GL_DRAW_FRAMEBUFFER, draw_framebuffer);
    gl_framebuffer_texture_2d(
        GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, destination_texture, 0
    );
    unsigned int draw_status = gl_check_framebuffer_status(GL_DRAW_FRAMEBUFFER);
    if (draw_status != GL_FRAMEBUFFER_COMPLETE) {
        snprintf(last_error, sizeof(last_error),
                 "destination framebuffer incomplete: 0x%x size=%ux%u",
                 draw_status, destination_width, destination_height);
        goto cleanup;
    }
    while (gl_get_error() != GL_NO_ERROR) {}
    gl_blit_framebuffer(
        (int)source_x, (int)source_y,
        (int)(source_x + source_width), (int)(source_y + source_height),
        0, 0, (int)destination_width, (int)destination_height,
        GL_COLOR_BUFFER_BIT, GL_NEAREST
    );
    unsigned int blit_error = gl_get_error();
    if (blit_error != GL_NO_ERROR) {
        snprintf(last_error, sizeof(last_error),
                 "scanout blit failed: 0x%x resource=%u format=%u source=%ux%u destination=%ux%u",
                 blit_error, resource_id, source.base.virgl_format,
                 source.base.width, source.base.height, destination_width, destination_height);
        goto cleanup;
    }
    gl_flush();

    int result = 0;
    goto finish;

cleanup:
    result = -1;
finish:
    gl_bind_framebuffer(GL_READ_FRAMEBUFFER, 0);
    gl_bind_framebuffer(GL_DRAW_FRAMEBUFFER, 0);
    gl_delete_framebuffers(1, &read_framebuffer);
    gl_delete_framebuffers(1, &draw_framebuffer);
    gl_delete_textures(1, &destination_texture);
    egl_destroy_image(egl_display, image);
    return result;
}

void vzvg_renderer_set_diagnostics_enabled(int enabled) {
    diagnostics_enabled = enabled != 0;
}

uint64_t vzvg_renderer_scanout_signature(void) {
    return scanout_signature;
}

uint64_t vzvg_renderer_scanout_signature_generation(void) {
    return scanout_signature_generation;
}

int vzvg_renderer_transfer_write(uint32_t resource_id, uint32_t context_id,
                                 uint32_t level, uint32_t stride, uint32_t layer_stride,
                                 const struct vzvg_box *box, uint64_t offset,
                                 struct iovec *iov, int iov_count) {
    return transfer_write(resource_id, context_id, level, stride, layer_stride,
                          (struct virgl_box *)box, offset, iov, iov_count);
}
int vzvg_renderer_transfer_read(uint32_t resource_id, uint32_t context_id,
                                uint32_t level, uint32_t stride, uint32_t layer_stride,
                                const struct vzvg_box *box, uint64_t offset,
                                struct iovec *iov, int iov_count) {
    return transfer_read(resource_id, context_id, level, stride, layer_stride,
                         (struct virgl_box *)box, offset, iov, iov_count);
}

const char *vzvg_renderer_last_error(void) { return last_error; }
