#ifndef FILEFORMATTER_WEBP_SHIM_H
#define FILEFORMATTER_WEBP_SHIM_H

#include <stddef.h>
#include <stdint.h>

/// Encodes straight RGBA pixels as a WebP image.
/// Returns 1 on success. The caller must release `*out` with ff_webp_free.
int ff_webp_encode_rgba(
    const uint8_t *rgba,
    int32_t width,
    int32_t height,
    int32_t stride,
    float quality,
    uint8_t **out,
    size_t *out_size
);

void ff_webp_free(uint8_t *ptr);

#endif
