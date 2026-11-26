#ifndef SESAME_SUNSHINE_ADAPTIVE_QUALITY_H
#define SESAME_SUNSHINE_ADAPTIVE_QUALITY_H
#include <algorithm>
#include <cstdint>

constexpr bool fullHdWanFormat(uint32_t w,uint32_t h,uint32_t fps) {
    return w==1920 && h==1080 && (fps==30 || fps==60);
}
constexpr bool compactFullHd60(uint32_t w,uint32_t h,uint32_t fps,uint32_t mtu,uint32_t kbps) {
    return w==1920 && h==1080 && fps==60 && mtu==640 && kbps==500;
}
constexpr bool fullHdRecoveryPacket(uint32_t fps,uint32_t mtu,uint32_t videoKbps) {
    return mtu==1024 || (fps==60 && ((mtu==768 && videoKbps<=1400) || (mtu==640 && videoKbps==500)));
}

// No saturating probes are sent during play. Only an authorized setup peer
// can opt in to a restart with fresh locked-down media credentials.
struct AdaptiveQuality {
    static constexpr uint32_t minKbps = 500;
    static constexpr uint64_t downCooldownMs = 15'000, upCooldownMs = 30'000;
    uint32_t limit{}, current{}, referenceRtt{}, downVotes{}, upVotes{}, changes{};
    uint64_t lastChange{};
    bool costlyRelayRestart{}, holdProbeFallback{}, fullHdWan{};
    uint32_t pressure{}, severe{}, low60Pressure{};

    constexpr uint32_t sample(uint64_t now, uint32_t fps100, uint32_t targetFps,
                              uint64_t missing, bool stalledWithPackets, uint32_t rtt)
    {
        if (!current || !rtt || changes >= 4) {
            downVotes = upVotes = pressure = severe = low60Pressure = 0;
            return 0;
        }
        if (referenceRtt == 0 || rtt < referenceRtt) referenceRtt = rtt;
        const uint32_t flexibleRtt = std::max(referenceRtt + 25, referenceRtt * 3 / 2);
        const bool loss = missing >= 2 || stalledWithPackets;
        const bool late = rtt > flexibleRtt && fps100 > 0 && fps100 < targetFps * 75;
        const bool clean = missing == 0 && fps100 >= targetFps * 93 && rtt <= flexibleRtt;
        if (costlyRelayRestart || fullHdWan) {
            // A new SDP means stopping the encrypted stream. Don't exchange a
            // short burst of missing frames for several seconds of black video.
            // Alternating loss still builds pressure; a static scene is not loss.
            const bool bad = fullHdWan ? (stalledWithPackets || (missing>=2 &&
                (fps100 < targetFps*93 || missing>=std::max(4U,targetFps/6))) || (late && missing)) : (loss || late);
            const bool urgent = stalledWithPackets || (missing >= 2 && fps100 < targetFps * 55);
            pressure = bad ? std::min(24U, pressure + 3) : (pressure > 2 ? pressure - 2 : 0);
            severe = urgent ? std::min(3U, severe + 1) : 0;
            // Rebuilding a 60 fps stream to reclaim only 200–350 kbps costs
            // the entire RTSP/decoder startup. One radio interruption plus
            // a late loss report is not evidence of a sustained rate deficit.
            const bool modest60=fullHdWan && targetFps==60 && current<=1500;
            low60Pressure=modest60 && bad ? std::min(20U,low60Pressure+1) :
                (low60Pressure>2 ? low60Pressure-2 : 0);
            // The full-HD setting keeps its pixel dimensions. Consolidate
            // sustained severe loss in one cut; a 100 kbps speculative
            // increase is never worth another TLS/RTSP + decoder restart.
            const uint64_t cooldown=fullHdWan ? (changes ? 30'000U : 10'000U) : downCooldownMs;
            const bool eligible=(!fullHdWan && !changes) || (now>=lastChange && now-lastChange>=cooldown);
            if ((severe >= 3 || pressure >= 18) && current > minKbps && eligible &&
                (!modest60 || low60Pressure>=14)) {
                if (fullHdWan && severe>=3 && current>=2800)
                    return std::max(1400U,current/2/50*50);
                return std::max(minKbps, current * 3 / 4 / 50 * 50);
            }
            // No speculative mid-game upshift that would itself interrupt playback.
            // The next session measures the path again.
            return 0;
        }
        downVotes = (loss || late) ? std::min(3U, downVotes + 1) : 0;
        upVotes = clean ? std::min(24U, upVotes + 1) : 0;
        // A static screen need not produce the requested frame cadence.
        if (downVotes == 3 && current > minKbps && (changes == 0 || now - lastChange >= downCooldownMs)) {
            return std::max(minKbps, current * 3 / 4 / 50 * 50);
        }
        // An inconclusive 8 Mbps relay trial fell back to its safe wire budget.
        // A few clean seconds at a lower video rate do not reverse that result;
        // re-probe next connection instead of rebuilding for a 100 kbps gain.
        if (!holdProbeFallback && upVotes == 24 && current < limit && now - lastChange >= upCooldownMs) {
            return std::min(limit, current + std::max(100U, current / 8 / 50 * 50));
        }
        return 0;
    }

    constexpr void applied(uint32_t rate, uint64_t now)
    {
        if (current == 0) {
            limit = rate;
            if (fullHdWan) lastChange=now;
        } else {
            ++changes;
            lastChange = now;
        }
        current = rate;
        downVotes = upVotes = 0;
        pressure = severe = low60Pressure = 0;
    }
};
#endif
