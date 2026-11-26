#include "../../entry/src/main/cpp/sunshine/route_policy.h"
#include "../../entry/src/main/cpp/sunshine/bandwidth_limit.h"
#include "../../entry/src/main/cpp/sunshine/picture_recovery.h"
#include "../../entry/src/main/cpp/sunshine/fresh_frame_recovery.h"
#include "../../entry/src/main/cpp/sunshine/adaptive_quality.h"

using namespace sesame_route;
static_assert(transition(Stage::Local, Result::NoNetwork) == Next::PublicDirect);
static_assert(transition(Stage::InternetDirect, Result::NoNetwork) == Next::Relay);
static_assert(transition(Stage::Relay, Result::NoNetwork) == Next::Stop);

constexpr bool final_for_every_stage(Result signal)
{
    return transition(Stage::Local, signal) == Next::Stop &&
           transition(Stage::InternetDirect, signal) == Next::Stop &&
           transition(Stage::Relay, signal) == Next::Stop;
}
static_assert(final_for_every_stage(Result::Unverified));
static_assert(final_for_every_stage(Result::SetupError));
static_assert(final_for_every_stage(Result::Cancelled));
static_assert(final_for_every_stage(Result::Ended));
static_assert(sesameBandwidthVideoLimit({2, 1760, 0, 1800}, 1400) == 1400);
static_assert(sesameBandwidthVideoLimit({3, 1200, 1350, 1800}, 1400) == 950);
static_assert(sesameBandwidthVideoLimit({3, 0, 450, 1800}, 1400) == 500);
static_assert(sesameBandwidthVideoLimit({4, 0, 0, 1800}, 1400) == 1400);
static_assert(sesameBandwidthVideoLimit({2, 44000, 0, 48000}, 50000) == 35200);
static_assert(sesameRelayVideoCeiling({2,7800,0,8000},true)==5900);
static_assert(sesameRelayVideoCeiling({3,3800,6000,8000},true)==2850);
static_assert(sesameRelayVideoCeiling({4,3800,0,8000},true)==1400);
static_assert(sesameRelayVideoCeiling({2,1724,0,1800},true)==1400);
static_assert(sesameRelayVideoCeiling({2,7800,0,8000},false)==1400);

constexpr bool onlyRecoversVerifiedStalledVideo()
{
    PictureRecovery r;
    return !r.observe(1000, 0, 15) && !r.observe(2000, 10, 40) &&
           !r.observe(5200, 10, 40) && !r.observe(5700, 10, 54, false) && r.observe(6000, 10, 70) &&
           !r.observe(7000, 10, 80) && r.observe(11000, 10, 95) &&
           r.observe(16000, 10, 120) && !r.observe(21000, 10, 150) &&
           !r.observe(22000, 11, 160) && !r.observe(24000, 11, 185) &&
           r.observe(25000, 11, 195);
}
constexpr bool retriesOnlyOngoingCompleteFrames() {
    ConfirmedIdrWait r;
    return !r.poll(1200,1000,1200,8,42) && !r.poll(1250,1000,1250,1,42) &&
        !r.poll(1400,1000,1200,7,42) && !r.poll(1420,1000,1420,7,0) &&
        r.poll(1430,1000,1420,9,42) && !r.poll(1500,1000,1500,10,42) &&
        !r.poll(2000,1700,2000,7,42) && r.poll(2250,1700,2250,15,42) &&
        r.poll(3100,1700,3100,29,42) && !r.poll(4100,1700,4100,49,42);
}
static_assert(retriesOnlyOngoingCompleteFrames());
constexpr bool compactRetryWaitsForLiveReferenceEvidence() {
    ConfirmedIdrWait r;
    return !r.poll(1750,1000,1750,30,45,true) && !r.poll(1900,1000,1700,30,45,true) &&
        !r.poll(1950,1000,1940,11,45,true) && !r.poll(1950,1000,1940,25,350,true) &&
        r.poll(1950,1000,1940,25,45,true) && !r.poll(9950,1000,9950,300,45,true) &&
        r.poll(10900,10000,10890,25,45,true) &&
        !r.poll(13000,12000,13000,25,45,true);
}
static_assert(compactRetryWaitsForLiveReferenceEvidence());
static_assert(onlyRecoversVerifiedStalledVideo());

constexpr bool keepsOnlyFreshKeyframeAfterGap()
{
    using A=FreshFrameRecovery::Action;
    FreshFrameRecovery f;
    for (uint64_t i=1;i<=12;++i)
        if (f.observe(50+i*16,i*16,true,false,16,true).action!=A::Pass) return false;
    if (f.observe(800,750,true,false,558,true).action!=A::Pass) return false; // quiet desktop
    if (f.observe(823,760,true,false,23,true).action!=A::Pass) return false; // normal jitter
    if (f.observe(2700,775,true,false,1877,true).action!=A::Refresh) return false;
    if (f.observe(2711,790,true,true,11,true).action!=A::Discard) return false; // stale IDR
    if (f.observe(2719,2669,true,false,8,true).action!=A::Discard) return false; // missing reference
    auto result=f.observe(2750,2670,true,true,31,true);
    if (result.action!=A::Resume || result.extraMs!=30 || f.dropped!=3 || f.requests!=1) return false;
    f.submittedFresh();
    return f.observe(2761,2701,true,false,11,true).action==A::Pass;
}
static_assert(keepsOnlyFreshKeyframeAfterGap());

constexpr bool recoveryRequestsAreBoundedAndTimestampsValidated()
{
    using A=FreshFrameRecovery::Action;
    FreshFrameRecovery f;
    for (uint64_t i=1;i<=10;++i) f.observe(80+i*17,i*17,true,false,17,true);
    if (f.observe(1800,201,true,false,1550,true).action!=A::Refresh) return false;
    // Unknown and stale timestamps cannot open the gate; they cannot
    // repeatedly generate new IDR requests while the link is still late.
    if (f.observe(2200,0,false,true,400,true).action!=A::Discard ||
        f.observe(3100,460,true,true,900,true).action!=A::Discard ||
        f.observe(3310,3240,true,false,210,true).action!=A::Refresh ||
        f.observe(4600,4500,true,false,1290,true).action!=A::Discard) return false;
    return f.requests==2 && f.waiting;
}
static_assert(recoveryRequestsAreBoundedAndTimestampsValidated());

constexpr bool recoveryToleratesChangedDelayFloorWithoutReplayingOldFrames()
{
    using A=FreshFrameRecovery::Action;
    FreshFrameRecovery f;
    for (uint32_t i=1;i<=12;++i) f.observe(50+i*33,i*33,true,false,33,true);
    if (f.observe(1800,720,true,false,1354,true).action!=A::Refresh) return false;
    if (f.observe(3500,750,true,true,1700,true).action!=A::Discard) return false;
    if (f.observe(3600,2600,true,false,100,true).action!=A::Refresh) return false;
    if (f.observe(3633,2633,true,true,33,true).action!=A::Resume) return false;
    f.submittedFresh();
    return !f.waiting && !f.samples && f.requests==2;
}
static_assert(recoveryToleratesChangedDelayFloorWithoutReplayingOldFrames());

constexpr bool qualityVotesAreHystereticAndCapped()
{
    AdaptiveQuality q;
    q.applied(1400, 0);
    for (uint64_t t=1000; t<=8000; t+=1000) if (q.sample(t, 0, 30, 0, false, 37)) return false;
    if (q.sample(9000, 2700, 30, 4, false, 42) || q.sample(10000, 2700, 30, 6, false, 43)) return false;
    if (q.sample(11000, 1800, 30, 7, false, 43) != 1050) return false;
    q.applied(1050, 12000);
    for (uint64_t t=13000; t<42000; t+=1000) if (q.sample(t, 3000, 30, 0, false, 37)) return false;
    if (q.sample(42000, 3000, 30, 0, false, 37) != 1150) return false;
    q.applied(1350, 43000);
    for (uint64_t t=44000; t<73000; t+=1000) if (q.sample(t, 3000, 30, 0, false, 37)) return false;
    return q.sample(73000, 3000, 30, 0, false, 37) == 1400;
}
static_assert(qualityVotesAreHystereticAndCapped());
constexpr bool costlyRelayKeepsShortBurstsButRespondsToPressure() {
    AdaptiveQuality q;
    q.costlyRelayRestart=true; q.applied(5900,0);
    for (int i=0;i<3;++i) if(q.sample(1000+i*1000,2400,30,6,false,43)) return false;
    for (int i=0;i<12;++i) if(q.sample(4000+i*1000,0,30,0,false,43)) return false;
    for (int i=0;i<5;++i) if(q.sample(16000+i*1000,2550,30,3,false,43)) return false;
    if(q.sample(21000,2550,30,3,false,43)!=4400) return false;
    q.applied(4400,22000);
    for (int i=0;i<60;++i) if(q.sample(23000+i*1000,3000,30,0,false,43)) return false;
    for (int i=0;i<2;++i) if(q.sample(83000+i*1000,100,30,25,true,43)) return false;
    return q.sample(85000,100,30,25,true,43)==3300;
}
static_assert(costlyRelayKeepsShortBurstsButRespondsToPressure());
constexpr bool fullHdWanKeepsPixelsAndAvoidsTinyRestarts() {
    AdaptiveQuality q; q.fullHdWan=true; q.applied(4600,1000);
    // An idle scene and occasional loss at full speed are not sustained pressure.
    for (uint64_t t=2000;t<=11000;t+=1000) if(q.sample(t,0,30,0,false,44)) return false;
    for (uint64_t t=12000;t<=23000;t+=1000) if(q.sample(t,2990,30,2,false,44)) return false;
    if(q.sample(24000,450,30,15,true,60) || q.sample(25000,450,30,15,true,60)) return false;
    if(q.sample(26000,450,30,15,true,60)!=2300) return false;
    q.applied(2300,27000);
    for(uint64_t t=28000;t<57000;t+=1000) if(q.sample(t,450,30,15,true,60)) return false;
    if(q.sample(57000,450,30,15,true,60)!=1700) return false;
    q.applied(1700,58000);
    for(uint64_t t=59000;t<=130000;t+=1000) if(q.sample(t,3000,30,0,false,44)) return false;
    return true;
}
static_assert(fullHdWanKeepsPixelsAndAvoidsTinyRestarts());
constexpr bool modestFullHd60DoesNotRestartOnBriefLoss() {
    AdaptiveQuality q; q.fullHdWan=true;q.applied(950,0);
    for (unsigned i=0;i<6;++i) if(q.sample(15000+i*1000,800,60,12,true,50)) return false;
    for (unsigned i=0;i<4;++i) if(q.sample(22000+i*1000,6000,60,0,false,48)) return false;
    for (unsigned i=0;i<13;++i) if(q.sample(27000+i*1000,2700,60,15,true,51)) return false;
    return q.sample(40000,2700,60,15,true,51)==700;
}
static_assert(modestFullHd60DoesNotRestartOnBriefLoss());
static_assert(fullHdWanFormat(1920,1080,60) && fullHdWanFormat(1920,1080,30));
static_assert(!fullHdWanFormat(1920,1080,120) && !fullHdWanFormat(1280,720,60));
static_assert(fullHdRecoveryPacket(60,768,800) && fullHdRecoveryPacket(60,1024,1850));
static_assert(!fullHdRecoveryPacket(30,768,800) && !fullHdRecoveryPacket(60,768,1850));
static_assert(compactFullHd60(1920,1080,60,640,500) && fullHdRecoveryPacket(60,640,500));
static_assert(!compactFullHd60(1280,720,60,640,500) && !compactFullHd60(1920,1080,30,640,500));
static_assert(!compactFullHd60(1920,1080,60,624,500) && !compactFullHd60(1920,1080,60,640,550));
constexpr bool cautiousProbeFallback(){
    AdaptiveQuality guarded,normal;
    guarded.holdProbeFallback=true;
    guarded.applied(1400,0);normal.applied(1400,0);
    guarded.applied(1050,16000);normal.applied(1050,16000);
    for(unsigned i=0;i<23;++i){
        if(guarded.sample(50000+i*1000,3000,30,0,false,40) ||
           normal.sample(50000+i*1000,3000,30,0,false,40)) return false;
    }
    if(guarded.sample(73000,3000,30,0,false,40) || !normal.sample(73000,3000,30,0,false,40)) return false;
    for(unsigned i=0;i<2;++i) if(guarded.sample(74000+i*1000,700,30,12,true,40)) return false;
    return guarded.sample(76000,700,30,12,true,40)==750;
}
static_assert(cautiousProbeFallback());
