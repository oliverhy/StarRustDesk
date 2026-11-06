#include "../entry/src/main/cpp/core/native_frame_bounds.h"
#include <cassert>
#include <climits>

int main() {
    assert(nativeFrameFits(1920, 1080, 1920 * 1080 * 4, 1920, 1080, 7680));
    assert(nativeFrameFits(1920, 1080, 1920 * 1080 * 4, 2048, 1200, 8192));
    assert(!nativeFrameFits(1920, 1080, 1920 * 1080 * 4, 1920, 1, 7680));
    assert(!nativeFrameFits(1920, 1080, 1920 * 1080 * 4, 1, 1080, 7680));
    assert(!nativeFrameFits(1920, 1080, 1920 * 1080 * 4, 1920, 1080, 100));
    assert(!nativeFrameFits(1920, 1080, 1920 * 1080 * 4 - 1, 1920, 1080, 7680));
    assert(!nativeFrameFits(INT_MAX, INT_MAX, INT_MAX, INT_MAX, INT_MAX, INT_MAX));
    assert(!nativeFrameFits(-1, 1, 4, 1, 1, 4));
    assert(nativeFrameSourceValid(1920, 1080, 1920 * 1080 * 4));
    assert(nativeFrameBufferValid(1876, 1055, 7680));
    assert(!nativeFrameBufferValid(1920, 1080, 100));
    assert(!nativeFrameSourceValid(INT_MAX, INT_MAX, INT_MAX));
}
