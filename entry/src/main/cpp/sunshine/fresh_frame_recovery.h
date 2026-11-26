#ifndef SESAME_SUNSHINE_FRESH_FRAME_RECOVERY_H
#define SESAME_SUNSHINE_FRESH_FRAME_RECOVERY_H
#include <cstdint>

// Private Sunshine trial only. PTS comes from the authenticated stream,
// but has a different origin from the phone clock. The minimum observed
// difference gives a relative latency reference, not one-way latency.
struct FreshFrameRecovery {
    enum class Action { Pass, Refresh, Discard, Resume };
    struct Result { Action action; uint64_t extraMs; };
    static constexpr uint64_t silenceMs=350, staleMs=220, acceptMs=180, retryMs=1200, reanchorMs=1600;
    static constexpr uint32_t minSamples=8;
    int64_t bestOffset{};
    uint32_t samples{}, lastPts{}, stallPts{}, dropped{}, requests{};
    uint64_t began{}, lastRequest{};
    bool waiting{};

    constexpr Result observe(uint64_t now, uint32_t pts, bool captured, bool idr,
                             uint64_t gap, bool hadPicture)
    {
        // Narrow test leases are shorter than the 90 kHz RTP wrap period.
        // Do not learn from a synthetic first PTS, or a clock discontinuity.
        const bool anchored=samples>=minSamples;
        const int64_t offset=static_cast<int64_t>(now)-pts;
        const bool sane=pts && pts<=1'200'000 && (!anchored || offset+120>=bestOffset) &&
            (!lastPts || (static_cast<uint64_t>(pts)+24>=lastPts &&
             (waiting || static_cast<uint64_t>(pts)<=static_cast<uint64_t>(lastPts)+gap+2000)));
        const uint64_t extra=anchored && sane && offset>bestOffset
            ? static_cast<uint64_t>(offset-bestOffset) : 0;

        if (!waiting && hadPicture && anchored && sane && gap>=silenceMs && extra>=staleMs) {
            waiting=true;
            began=lastRequest=now;
            dropped=requests=1;
            stallPts=pts;
            lastPts=pts;
            return {Action::Refresh,extra};
        }

        if (sane && pts>lastPts) lastPts=pts;
        if (waiting) {
            if (sane && extra<=acceptMs && idr) return {Action::Resume,extra};
            // A changed network delay floor must not reject new independent
            // pictures forever. Both media time and wall time must advance;
            // a queued old IDR or an unchanged PTS is not a recovery picture.
            const bool advanced=sane && now-began>=reanchorMs &&
                static_cast<uint64_t>(pts)>=static_cast<uint64_t>(stallPts)+reanchorMs;
            if (advanced && idr) {
                samples=0;
                return {Action::Resume,extra};
            }
            ++dropped;
            // At most one backup request, and only once fresh traffic is
            // arriving. Do not keep injecting keyframes into a dead link.
            if (sane && (extra<=acceptMs || advanced) && requests<2 && now-lastRequest>=retryMs) {
                ++requests;
                lastRequest=now;
                return {Action::Refresh,extra};
            }
            return {Action::Discard,extra};
        }

        if (sane && captured) {
            if (!samples || offset<bestOffset) bestOffset=offset;
            if (samples<minSamples) ++samples;
        }
        return {Action::Pass,extra};
    }

    constexpr void submittedFresh() { waiting=false; }
};
#endif
