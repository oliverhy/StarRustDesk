#pragma once
#include <cstdint>

// One incident from confirmed (not speculative) FEC loss to an output with a
// post-loss decoder PTS. The client serializes access; no contents or addresses.
struct LanPictureWitness {
    uint64_t first{},last{},unit{},targetPts{},previousRequest{},lastComplete{};
    uint32_t frame{},unitFrame{}; unsigned completes{},source{}; bool idr{},requested{},knownFrame{};
    uint64_t firstLoss{},firstWait{},queued{},accepted{},lastAccepted{},asked{};
    unsigned queues{},sends{},waitKind{},attempts{};
    void loss(uint64_t now,uint32_t n) {
        if (!first) {first=now;source=1;}
        if (unit) return;
        if (!firstLoss) firstLoss=now;
        if (knownFrame && frame==n) return; // RTP abandonment and confirmed core notification can refer to the same loss
        if (!knownFrame || (!unit && (n-frame)<0x80000000U)) frame=n;
        knownFrame=true;
        completes=0; lastComplete=0;
        last=now;
    }
    void submitting(uint64_t now,uint32_t n,uint64_t pts,bool key) {
        if (first && !unit && now>=first && (!knownFrame || (n!=frame && (n-frame)<0x80000000U))) {
            unit=now;unitFrame=n;targetPts=pts;idr=key;
        }
    }
    // These notifications originate AFTER a whole encrypted frame is authenticated
    // and reassembled by the pinned core. Its ordinary first repair stays in charge.
    void completeButWaiting(uint64_t now,unsigned kind=1) {
        if (!first) {first=last=now;source=2;} // core explicitly rejected a complete frame after startup
        if (unit || now<last) return;
        if (!firstWait) {firstWait=now;waitKind=kind;}
        completes=lastComplete && now>=lastComplete && now-lastComplete<=110 ? completes+1 : 1;
        lastComplete=now;
    }
    void observedAtDecoder(uint64_t now,uint32_t next) {
        if (!first) {loss(now,next-1);source=3;firstLoss=0;} // decoder gap alone cannot date network loss
    }
    void rejectedAtDecoder(uint64_t now,uint32_t n) {
        if (!first) {first=last=now;source=4;frame=n;knownFrame=true;}
    }
    void control(uint64_t now,bool sent) {
        if (!first || unit || now<first) return;
        if (sent) {if (!accepted) accepted=now; lastAccepted=now; ++sends;}
        else {if (!queued) queued=now; ++queues;}
    }
    bool retry(uint64_t now) {
        if (!first || unit || requested || now<last || now<first || now<lastComplete) return false;
        if (completes<4 || now-lastComplete>90 || now-first<200 || now-last<90 ||
            (previousRequest && (now<previousRequest || now-previousRequest<5000))) return false;
        requested=true;asked=previousRequest=now;++attempts;return true;
    }
    // Called only by the authenticated video depacketizer on a COMPLETE frame
    // it is about to discard for lack of an IDR. The native first request has
    // priority. Never run this from a timer, a speculative loss or an RFI wait.
    bool retryOnComplete(uint64_t now) {
        if (!first || unit || attempts>=2 || !lastComplete || now<lastComplete || now-lastComplete>5 ||
            completes<4 || now<first || now<last || now-last<65 ||
            now-first<(attempts?340u:100u) || (queued && !accepted)) return false;
        // Leave a pending native request time to be handed off. Coalescing
        // means that counts of intent and send need not be identical.
        auto quiet=attempts?260u:95u;
        auto controlAt=queued>lastAccepted?queued:lastAccepted;
        if (controlAt && (now<controlAt || now-controlAt<quiet)) return false;
        if (previousRequest && (now<previousRequest ||
            now-previousRequest<(attempts?300u:750u))) return false;
        if (!attempts) asked=now;
        previousRequest=now;++attempts;requested=true;return true;
    }
    bool presented(uint64_t now,uint64_t pts) const {
        return first && unit && now>=unit && pts>=targetPts && pts-targetPts<=2000000;
    }
    void finish() {auto p=previousRequest;*this={};previousRequest=p;}
};
