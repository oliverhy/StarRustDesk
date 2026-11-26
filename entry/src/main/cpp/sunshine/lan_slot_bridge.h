#pragma once
#include <cstdint>

// Only the pinned test receiver's serial decoder submission path calls this.
// Never store a frame or change ownership of an OH_AVBuffer.
struct LanSlotBridge {
    static constexpr unsigned deadlineUs=2000;
    struct Wait { uint64_t us=0;uint32_t frame=0;bool pushed=false,idr=false; };
    Wait rows[256]{};
    uint64_t lastUs=0;
    unsigned tries=0,pushed=0;
    bool begin(uint64_t now,bool eligible) {
        if (!eligible || (tries && (now<lastUs || now-lastUs<40000))) return false;
        lastUs=now;++tries;return true;
    }
    void finish(uint32_t frame,uint64_t us,bool accepted,bool idr) {
        if(accepted) ++pushed;
        if(tries && tries<=256) rows[tries-1]={us,frame,accepted,idr};
    }
};

// Lab-only, called under the same mutex that protects the decoder input slots.
// Several rejections can await one callback. Link them instead of iterating or
// logging on the callback thread. No slot, frame data or OH object is retained.
struct LanSlotReturns {
    struct Row { uint64_t rejectedUs=0, returnedUs=0; uint32_t frame=0, group=0; };
    static constexpr unsigned limit=256;
    Row rows[limit]{};
    unsigned used=0, pending=0, overflow=0;
    void reject(uint32_t frame,uint64_t us) {
        if(used==limit) { if(overflow!=UINT32_MAX) ++overflow;return; }
        rows[used++]={us,0,frame,pending};
    }
    void available(uint64_t us) {
        if(pending==used) return;
        rows[pending].returnedUs=us;
        pending=used;
    }
};
