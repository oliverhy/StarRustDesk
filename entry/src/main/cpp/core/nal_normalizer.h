#ifndef RUSTDESK_NAL_NORMALIZER_H
#define RUSTDESK_NAL_NORMALIZER_H

#include <cstddef>
#include <cstdint>
#include <vector>

// Accept Annex B, a complete sequence of 4-byte-length-prefixed NALs, or a
// single bare NAL. Never trust a 32-bit length or allocate from it unchecked.
inline std::vector<uint8_t> normalizeAnnexBNals(const uint8_t* data, int length, size_t maximum) {
    if (!data || length <= 0 || static_cast<size_t>(length) > maximum) return {};
    const size_t n = static_cast<size_t>(length);
    if ((n >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1) ||
        (n >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1))
        return std::vector<uint8_t>(data, data + n);
    if (maximum < 4) return {};
    const auto read32 = [](const uint8_t* p) -> uint32_t {
        return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
            (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
    };
    if (n > 4 && read32(data) > 0 && static_cast<size_t>(read32(data)) <= n - 4) {
        std::vector<uint8_t> output;
        output.reserve(n);
        size_t offset = 0;
        while (offset < n) {
            if (n - offset < 4) return {};
            const size_t size = read32(data + offset);
            offset += 4;
            if (size == 0 || size > n - offset || output.size() > maximum - 4 ||
                size > maximum - 4 - output.size()) return {};
            output.insert(output.end(), {0, 0, 0, 1});
            output.insert(output.end(), data + offset, data + offset + size);
            offset += size;
        }
        return output;
    }
    if (maximum < 4 || n > maximum - 4) return {};
    std::vector<uint8_t> output {0, 0, 0, 1};
    output.insert(output.end(), data, data + n);
    return output;
}
#endif
