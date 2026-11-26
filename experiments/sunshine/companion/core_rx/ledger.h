#pragma once
#include "sesame_core_rx.h"
#include <algorithm>
#include <array>
#include <limits>

namespace sr {
constexpr uint32_t limit=65536, maxGaps=96;
struct Row {
    uint16_t raw{},old{},bad{},auth{},rejected{},deficit{},lateAfter{},lateMs{};
    uint8_t flags{};
    uint32_t abandoned{};
};
struct Gap {uint32_t first{},count{};};
inline void inc(uint16_t &n){if(n!=std::numeric_limits<uint16_t>::max())++n;}
struct Ledger {
    std::array<Row,limit> rows{};
    std::array<Gap,maxGaps> gaps{};
    uint32_t used{},invalidGap{},invalidHint{},reads{};
    Row *at(uint32_t f){return f && f<=limit ? &rows[f-1]:nullptr;}
    void read(uint32_t f){++reads;if(auto r=at(f))inc(r->raw);else ++invalidHint;}
    void mark(uint32_t f,unsigned flag){if(auto r=at(f))r->flags|=flag;}
    void abandon(uint32_t f,unsigned have,unsigned need,uint32_t clock) {
        if(auto r=at(f)){
            if(!(r->flags&SR_ABANDON))r->abandoned=clock;
            r->flags|=SR_ABANDON;
            if(need>have)r->deficit=std::max(r->deficit,static_cast<uint16_t>(std::min<unsigned>(65535,need-have)));
        }
    }
    void old(uint32_t f,uint32_t clock){
        if(auto r=at(f)){inc(r->old);if(r->flags&SR_ABANDON){
            const uint32_t elapsed=clock-r->abandoned;
            if(elapsed<120000){inc(r->lateAfter);r->lateMs=std::max(r->lateMs,static_cast<uint16_t>(std::min<unsigned>(65535,elapsed)));}
        }}
    }
    void gap(uint32_t f,uint32_t n){
        if(!f || !n || f>limit || n>2000 || n>limit-f+1 || used>=maxGaps){++invalidGap;return;}
        gaps[used++]={f,n};
    }
};
}
