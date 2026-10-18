#include "webp_shim.h"
#include <webp/encode.h>

int ff_webp_encode_rgba(
    const uint8_t *rgba,
    int32_t width,
    int32_t height,
    int32_t stride,
    float quality,
    uint8_t **out,
    size_t *out_size
) {
    if (rgba == NULL || out == NULL || out_size == NULL || width <= 0 || height <= 0) {
        return 0;
    }
    if (quality < 0.0f) quality = 0.0f;
    if (quality > 100.0f) quality = 100.0f;
    *out = NULL;
    *out_size = 0;
    size_t size = WebPEncodeRGBA(rgba, width, height, stride, quality, out);
    if (size == 0 || *out == NULL) {
        return 0;
    }
    *out_size = size;
    return 1;
}

void ff_webp_free(uint8_t *ptr) {
    WebPFree(ptr);
}
