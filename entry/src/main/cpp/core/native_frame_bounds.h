#ifndef RUSTDESK_NATIVE_FRAME_BOUNDS_H
#define RUSTDESK_NATIVE_FRAME_BOUNDS_H

#include <cstddef>
#include <cstdint>
#include <limits>

// A requested surface size is not proof that the returned buffer already has
// that size: a window can briefly return a buffer from its previous geometry.
inline bool nativeFrameSourceValid(int width, int height, int length) {
    if (width <= 0 || height <= 0 || length <= 0) return false;
    const size_t w = static_cast<size_t>(width);
    const size_t h = static_cast<size_t>(height);
    if (w > std::numeric_limits<size_t>::max() / 4) return false;
    const size_t row = w * 4;
    if (row > static_cast<size_t>(std::numeric_limits<int>::max()) ||
        h > std::numeric_limits<size_t>::max() / row) return false;
    return static_cast<size_t>(length) >= row * h;
}

inline bool nativeFrameBufferValid(int bufferWidth, int bufferHeight, int strideBytes) {
    if (bufferWidth <= 0 || bufferHeight <= 0 || strideBytes <= 0) return false;
    const size_t width = static_cast<size_t>(bufferWidth);
    const size_t height = static_cast<size_t>(bufferHeight);
    const size_t stride = static_cast<size_t>(strideBytes);
    return width <= std::numeric_limits<size_t>::max() / 4 && stride >= width * 4 &&
        height <= std::numeric_limits<size_t>::max() / stride;
}

inline bool nativeFrameFits(int width, int height, int length,
                            int bufferWidth, int bufferHeight, int strideBytes) {
    return nativeFrameSourceValid(width, height, length) &&
        nativeFrameBufferValid(bufferWidth, bufferHeight, strideBytes) &&
        bufferWidth >= width && bufferHeight >= height;
}
#endif
