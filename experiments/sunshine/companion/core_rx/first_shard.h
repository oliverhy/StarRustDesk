#pragma once
#include <cstdint>

// Debug-only; serialized by the current picture witness. Never consulted by
// playback, the FEC queue or the control channel. Milliseconds on the Li clock.
struct LanFirstShard {
    uint64_t lossAt{}, admittedAt{};
    uint32_t firstLoss{}, floor{}, admitted{};
    unsigned reason{}, parity{}, lostAgain{};
    static bool newer(uint32_t n,uint32_t ref) {return n!=ref && uint32_t(n-ref)<0x80000000U;}
    void confirmed(uint64_t now,uint32_t n,unsigned why,bool nativeAlready) {
        if (!n || !now || (why!=1 && why!=2)) return;
        if (!lossAt) {lossAt=now;firstLoss=floor=n;reason=why;return;}
        if (now<lossAt) return;
        if (!admittedAt) {if(newer(n,floor))floor=n;}
        else if (!nativeAlready && (n==admitted || newer(n,admitted))) lostAgain=1;
    }
    bool pending() const {return lossAt && !admittedAt;}
    void accepted(uint64_t now,uint32_t n,bool isParity) {
        if (pending() && n && now>=lossAt && newer(n,floor)) {
            admittedAt=now;admitted=n;parity=isParity;
        }
    }
};
