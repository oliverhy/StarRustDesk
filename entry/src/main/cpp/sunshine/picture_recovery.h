#ifndef SESAME_SUNSHINE_PICTURE_RECOVERY_H
#define SESAME_SUNSHINE_PICTURE_RECOVERY_H
#include <cstdint>

// A recovery signal needs continuing authenticated video delivery and a
// previously working decoder pipeline. A quiet source or dead link is not
// evidence that another large keyframe will help.
uint32_t sesameDeliveredVideoPackets();

// The core already asks for an IDR on first recovery. Only retry if several
// complete, authenticated inter pictures are STILL arriving without a usable
// reference. Keep a global cooldown across separate loss events as well.
struct ConfirmedIdrWait {
    uint64_t span{}, previous{}; unsigned attempts{};
    constexpr bool poll(uint64_t now,uint64_t first,uint64_t last,unsigned complete,uint64_t rtt,
                        bool compactRelay=false){
        if (!first || last<first || now<last || now-last>(compactRelay?90U:110U) ||
            complete<(compactRelay?12U:4U) || !rtt || (compactRelay && rtt>250)) return false;
        if (span!=first){span=first;attempts=0;}
        const auto delay=rtt>=180 ? 600 : (3*rtt+60<220 ? 220 : 3*rtt+60);
        // The compact 1.8M route can barely carry a large IDR. Never request
        // one merely on loss or silence. One extra request per continuing
        // reference wait; successive incidents share an eight-second budget.
        if (attempts>=(compactRelay?1U:2U) || now-first<(compactRelay?800U:delay) ||
            (previous && (now<previous || now-previous<(compactRelay?8000U:800U)))) return false;
        ++attempts;previous=now;return true;
    }
};

struct PictureRecovery {
    static constexpr uint64_t stallMs = 2500, freshMs = 2600, cooldownMs = 5000;
    static constexpr uint32_t maxPerStall = 3;
    uint64_t lastUnitMs{}, lastPacketMs{}, lastRequestMs{};
    uint64_t units{};
    uint32_t packets{}, requests{};
    bool sawPicture{}, requested{}, hasPostPicturePackets{};

    constexpr bool observe(uint64_t now, uint64_t completeUnits, uint32_t videoPackets, bool controlAlive = true)
    {
        const bool packetProgress = videoPackets > packets;
        packets = videoPackets;
        if (completeUnits > units) {
            units = completeUnits;
            sawPicture = true;
            lastUnitMs = now;
            requests = 0;
            hasPostPicturePackets = false;
        } else if (packetProgress && sawPicture) {
            lastPacketMs = now;
            hasPostPicturePackets = true;
        }
        if (!controlAlive || !sawPicture || !hasPostPicturePackets || now - lastUnitMs < stallMs ||
            now - lastPacketMs > freshMs || requests >= maxPerStall ||
            (requested && now - lastRequestMs < cooldownMs)) return false;
        ++requests;
        requested = true;
        lastRequestMs = now;
        return true;
    }
};
#endif
