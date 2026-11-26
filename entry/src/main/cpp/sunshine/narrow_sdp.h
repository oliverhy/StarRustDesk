#ifndef SESAME_SUNSHINE_NARROW_SDP_H
#define SESAME_SUNSHINE_NARROW_SDP_H
#include <cstddef>
#include <string_view>

// Only edit our locally generated offer, before the RTSP layer encrypts it.
// With the pinned core, change the minimum (not the percentage or security
// settings). Fail closed if a future serializer changes or duplicates it.
constexpr bool applyNarrowRepairFloor(char *sdp, std::size_t size)
{
    if (!sdp || !size || size > 64 * 1024) return false;
    constexpr std::string_view key = "a=x-nv-vqos[0].fec.minRequiredFecPackets:";
    const std::string_view text(sdp,size);
    std::size_t value = std::string_view::npos;
    for (std::size_t begin = 0; begin < size;) {
        const auto end = text.find('\n',begin);
        if (end == std::string_view::npos) return false;
        const auto line = text.substr(begin,end-begin);
        if (line.substr(0,key.size()) == key) {
            if (value != std::string_view::npos || line.substr(key.size()) != "2 \r") return false;
            value = begin+key.size();
        }
        begin = end+1;
    }
    if (value == std::string_view::npos) return false;
    sdp[value] = '1';
    return true;
}

#endif
