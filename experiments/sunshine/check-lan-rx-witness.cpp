#include "../../entry/src/main/cpp/sunshine/lan_picture_witness.h"
#include "../../entry/src/main/cpp/sunshine/lan_slot_bridge.h"
#include <cassert>
#include <initializer_list>

int main() {
    LanSlotBridge slot;
    static_assert(LanSlotBridge::deadlineUs==2000,"Never spend a frame's budget waiting");
    assert(!slot.begin(1000,false));assert(slot.begin(1000,true));assert(!slot.begin(999,true));
    assert(!slot.begin(40999,true));assert(!slot.begin(41000,false));assert(slot.begin(41000,true));
    assert(slot.tries==2 && slot.pushed==0);
    slot.finish(31,2118,false,false);
    assert(slot.rows[1].us==2118 && slot.rows[1].frame==31 && slot.pushed==0);
    assert(slot.begin(81000,true));slot.finish(32,1010,true,true);
    assert(slot.rows[2].idr && slot.rows[2].pushed && slot.pushed==1);
    LanSlotReturns returns;
    returns.available(90);returns.reject(17,100);returns.reject(18,104);
    returns.available(108);returns.available(112);
    assert(returns.rows[returns.rows[1].group].returnedUs==108 && returns.pending==2);
    returns.reject(19,120);assert(returns.rows[2].returnedUs==0 && returns.rows[2].group==2);
    for(unsigned i=3;i<LanSlotReturns::limit+3;++i)returns.reject(i,125);
    returns.available(131);assert(returns.overflow==3 && returns.rows[returns.rows[255].group].returnedUs==131);
    LanPictureWitness w;
    assert(!w.retry(2200));
    w.loss(1000,98);w.loss(1020,99);
    assert(!w.retry(1350)); // isolated loss or a dead link: no request
    for(auto t:{1360,1376,1392}) w.completeButWaiting(t);
    assert(!w.retry(1400)); // too few authenticated complete frames
    w.completeButWaiting(1408);
    assert(w.retry(1410));assert(!w.retry(1450)); // only one per incident
    w.submitting(1440,97,100000,false);assert(!w.unit); // queued older reference
    w.submitting(1450,101,101000,true);
    assert(!w.presented(1455,90000));assert(w.presented(1460,101000));
    assert(!w.presented(1449,101000));assert(!w.presented(1480,4000000));
    w.finish();w.loss(1900,201);
    for(auto t:{2050,2070,2090,2110})w.completeButWaiting(t);
    assert(!w.retry(2120)); // global cooldown across different losses
    w.finish();w.loss(8000,0xfffffffeU);
    for(auto t:{8180,8196,8212,8228})w.completeButWaiting(t);
    assert(!w.retry(8430)); // no live recent complete frame
    w.completeButWaiting(8440);assert(!w.retry(8441)); // stale group reset
    w.submitting(8460,1,555000,false);assert(w.presented(8470,555000)); // RFI wraparound
    assert(!w.retry(8471)); // successful handoff cancels requests even prior to display
    w.finish();w.completeButWaiting(9100);assert(w.source==2 && !w.knownFrame);
    w.submitting(9200,800,600000,true);assert(w.presented(9201,600000));
    w.finish();w.observedAtDecoder(9999,12);w.submitting(9999,12,700000,true);
    assert(w.source==3 && w.unit==w.first && w.presented(10003,700000));
    // A speculative loss alone, a silent link or a stale timer cannot repair.
    LanPictureWitness k;k.loss(1000,20);
    assert(!k.retryOnComplete(2400));
    for(auto t:{1020,1037,1054,1071})k.completeButWaiting(t);
    assert(!k.retryOnComplete(1071) && !k.retryOnComplete(1200));
    k.control(1071,false);k.completeButWaiting(1150);
    assert(!k.retryOnComplete(1150)); // original control still pending
    k.control(1155,true);
    for(auto t:{1170,1188,1205,1222,1239}){k.completeButWaiting(t);assert(!k.retryOnComplete(t));}
    k.completeButWaiting(1256);assert(k.retryOnComplete(1256));assert(!k.retryOnComplete(1256));
    k.control(1256,false);k.control(1257,true);
    for(auto t:{1320,1380,1440,1500,1550}){k.completeButWaiting(t);assert(!k.retryOnComplete(t));}
    k.completeButWaiting(1561);assert(k.retryOnComplete(1561));
    k.completeButWaiting(1610);assert(!k.retryOnComplete(1610)&&k.attempts==2&&k.asked==1256);
    k.submitting(1630,44,44000,true);assert(k.unitFrame==44 && !k.retryOnComplete(1630));
    k.finish();k.rejectedAtDecoder(1700,45);assert(k.source==4 && k.firstLoss==0);
    for(auto t:{1750,1770,1790,1810}){k.completeButWaiting(t);assert(!k.retryOnComplete(t));}
    k.submitting(1820,50,50000,true);assert(k.presented(1821,50000));
}
