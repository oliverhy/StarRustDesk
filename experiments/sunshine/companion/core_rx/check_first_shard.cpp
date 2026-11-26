#include "first_shard.h"
#include <cassert>
int main() {
    LanFirstShard s;
    s.accepted(1,6,false);s.confirmed(1,0,1,false);s.confirmed(2,3,0,false);
    assert(!s.pending() && !s.admittedAt);
    s.confirmed(10,12,1,false);s.confirmed(11,12,2,false);s.confirmed(11,10,1,false);
    s.confirmed(12,13,2,false);
    assert(s.pending() && s.lossAt==10 && s.reason==1 && s.firstLoss==12 && s.floor==13);
    s.accepted(9,15,false);s.accepted(12,12,false);s.accepted(12,13,false);assert(s.pending());
    s.accepted(12,14,true);s.accepted(13,15,false);
    assert(!s.pending() && s.admittedAt==12 && s.admitted==14 && s.parity);
    s.confirmed(14,12,1,false);s.confirmed(15,16,2,true);assert(!s.lostAgain);
    s.confirmed(16,14,1,false);assert(s.lostAgain);
    s={};s.confirmed(20,0xffffffffu,2,false);s.accepted(20,1,false);
    assert(s.lossAt==s.admittedAt && s.reason==2 && !s.parity && !s.lostAgain && s.floor==0xffffffffu);
}
