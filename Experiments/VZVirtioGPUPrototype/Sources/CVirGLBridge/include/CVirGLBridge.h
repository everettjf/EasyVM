#ifndef C_VIRGL_BRIDGE_H
#define C_VIRGL_BRIDGE_H

#include <stdint.h>
#include <sys/uio.h>

#ifdef __cplusplus
extern "C" {
#endif

struct vzvg_resource_create_args {
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

struct vzvg_box {
    uint32_t x;
    uint32_t y;
    uint32_t z;
    uint32_t w;
    uint32_t h;
    uint32_t d;
};

struct vzvg_scanout_texture_info {
    uint32_t texture_id;
    uint32_t format;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
};

int vzvg_renderer_load(const char *dylib_path);
int vzvg_renderer_initialize(void);
void vzvg_renderer_cleanup(void);
void vzvg_renderer_poll(void);

void vzvg_renderer_get_cap_set(uint32_t set, uint32_t *max_version, uint32_t *max_size);
void vzvg_renderer_fill_caps(uint32_t set, uint32_t version, void *caps);

int vzvg_renderer_resource_create(const struct vzvg_resource_create_args *args);
void vzvg_renderer_resource_unref(uint32_t resource_id);
int vzvg_renderer_resource_attach_iov(uint32_t resource_id, struct iovec *iov, int iov_count);
void vzvg_renderer_resource_detach_iov(uint32_t resource_id);

int vzvg_renderer_context_create(uint32_t context_id, uint32_t name_length, const char *name);
void vzvg_renderer_context_destroy(uint32_t context_id);
void vzvg_renderer_context_attach_resource(uint32_t context_id, uint32_t resource_id);
void vzvg_renderer_context_detach_resource(uint32_t context_id, uint32_t resource_id);

int vzvg_renderer_submit(void *commands, uint32_t context_id, uint32_t dword_count);
int vzvg_renderer_create_fence(uint32_t fence_id, uint32_t context_id);
int vzvg_renderer_pop_completed_fence(uint32_t *fence_id);
int vzvg_renderer_borrow_scanout_texture(uint32_t resource_id,
                                         struct vzvg_scanout_texture_info *info);
int vzvg_renderer_present_scanout(uint32_t resource_id,
                                  void *metal_texture,
                                  uint32_t source_x,
                                  uint32_t source_y,
                                  uint32_t source_width,
                                  uint32_t source_height,
                                  uint32_t destination_width,
                                  uint32_t destination_height);
void vzvg_renderer_set_diagnostics_enabled(int enabled);
uint64_t vzvg_renderer_scanout_signature(void);
uint64_t vzvg_renderer_scanout_signature_generation(void);

int vzvg_renderer_transfer_write(uint32_t resource_id,
                                 uint32_t context_id,
                                 uint32_t level,
                                 uint32_t stride,
                                 uint32_t layer_stride,
                                 const struct vzvg_box *box,
                                 uint64_t offset,
                                 struct iovec *iov,
                                 int iov_count);
int vzvg_renderer_transfer_read(uint32_t resource_id,
                                uint32_t context_id,
                                uint32_t level,
                                uint32_t stride,
                                uint32_t layer_stride,
                                const struct vzvg_box *box,
                                uint64_t offset,
                                struct iovec *iov,
                                int iov_count);

const char *vzvg_renderer_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
