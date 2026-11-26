#include "ledger.h"
#include <cassert>
#include <memory>
int main(){
    auto t=std::make_unique<sr::Ledger>(); t->read(0);t->read(65537);assert(t->invalidHint==2);
    t->read(7);t->mark(7,SR_FEC_COMPLETE);t->old(7,1000);
    assert(t->at(7)->old==1 && !t->at(7)->lateAfter);
    t->abandon(17,18,22,0xfffffff0U);t->abandon(17,0,0,0xfffffff7U);
    t->old(17,0x03U);assert(t->at(17)->lateAfter==1 && t->at(17)->lateMs==19 && t->at(17)->deficit==4);
    t->mark(18,SR_FEC_COMPLETE);t->mark(18,SR_WAIT_RFI);assert(t->at(18)->flags==(SR_FEC_COMPLETE|SR_WAIT_RFI));
    t->gap(65536,2);t->gap(0,2);t->gap(1,2001);assert(!t->used && t->invalidGap==3);
    for(unsigned i=1;i<=sr::maxGaps+1;i++)t->gap(i,1);
    assert(t->used==sr::maxGaps && t->invalidGap==4);
}
