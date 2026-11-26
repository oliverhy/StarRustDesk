#ifndef SESAME_SUNSHINE_BANDWIDTH_LIMIT_H
#define SESAME_SUNSHINE_BANDWIDTH_LIMIT_H

#include <cstdint>

struct BandwidthEstimate {
    uint32_t state{0}, goodKbps{0}, unstableKbps{0}, probeCapKbps{0};
};
static_assert(sizeof(BandwidthEstimate) == 4 * sizeof(uint32_t));

BandwidthEstimate sesameBandwidthCurrent();
constexpr uint32_t sesameStandardKbps=20000, sesameStandardProbeKbps=30000;
constexpr bool sesamePairedRate(uint32_t kbps) {
    return kbps>=2000 && kbps<=50000 && kbps%1000==0;
}
// Our paired, pinned Sunshine helper advertises its unmodified 20% FEC
// semantics. This codec budget is a video target, not Moonlight's inclusive
// SDPed A/V budget. At these rates stereo is HQ (2 * 256 kbps).
constexpr uint32_t sesameStandardSdpKbps(uint32_t video) {
    return (video+512+500)*5/4; // paired video steps are whole Mbps, exact here
}
static_assert(sesameStandardSdpKbps(20000)==26265);

// Mirror the host's conservative plan. The cap is a measurement ceiling,
// never a video rate; do not elevate based on a missing/inconclusive probe.
constexpr uint32_t sesameRelayVideoCeiling(BandwidthEstimate e, bool relay)
{
    if (!(e.probeCapKbps==sesameStandardProbeKbps || (relay && e.probeCapKbps==8000)) ||
        e.goodKbps<3600 || e.goodKbps>e.probeCapKbps ||
        !(e.state==2 || (e.state==3 && e.unstableKbps>e.goodKbps && e.unstableKbps<=e.probeCapKbps))) return 1400;
    const auto wire=(e.goodKbps*95/100)/100*100;
    const auto av=wire*8/10;
    return ((e.probeCapKbps==sesameStandardProbeKbps ? av-1012 : av)/50)*50;
}

constexpr uint32_t sesameBandwidthVideoLimit(BandwidthEstimate e, uint32_t policyCap)
{
    constexpr uint32_t minimum = 500;
    if (e.goodKbps != 0 && e.goodKbps <= e.probeCapKbps && e.probeCapKbps <= 72000) {
        const auto planned = (e.goodKbps * 8 / 10) / 50 * 50;
        if (planned < minimum) return minimum;
        return planned < policyCap ? planned : policyCap;
    }
    // If the first valid train already failed, ask for the minimum. A
    // missing sample never invents a network limit or raises a route cap.
    if (e.state == 3 && e.unstableKbps != 0) return minimum;
    return policyCap;
}
#endif
