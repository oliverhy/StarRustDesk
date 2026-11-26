// Numeric traces only. Replay recorded "complete but awaiting IDR" timestamps
// through the exact phone policy. This is not a network or decoder test.
#include "../../entry/src/main/cpp/sunshine/picture_recovery.h"
#include <algorithm>
#include <iostream>
#include <vector>

int main() {
    unsigned id{},duration{},rtt{},n{};
    while (std::cin >> id >> duration >> rtt >> n) {
        if (!duration || duration>600000 || !rtt || rtt>30000 || n>40000) return 2;
        std::vector<unsigned> seen(n);
        for(auto &t:seen) if(!(std::cin>>t) || t>duration) return 2;
        if(!std::is_sorted(seen.begin(),seen.end())) return 2;
        unsigned earliest=duration,latest=0,phases=0,maxRequests=0;
        for(unsigned phase=0;phase<50;++phase){
            ConfirmedIdrWait policy;
            size_t j=0;uint64_t first=0,last=0;unsigned count=0,requests=0;
            for(unsigned t=phase;t<duration;t+=50){
                while(j<seen.size() && seen[j]<=t){
                    const uint64_t at=10000+seen[j++];
                    if(!first || at-last>180){first=at;count=0;}
                    last=at;++count;
                }
                if(policy.poll(10000+t,first,last,count,rtt)){
                    if(!requests){earliest=std::min(t,earliest);latest=std::max(t,latest);}
                    ++requests;
                }
            }
            phases+=requests!=0;maxRequests=std::max(maxRequests,requests);
        }
        std::cout<<"gap_ms="<<duration<<" wait_samples="<<n<<" poll_phases_with_retry="<<phases
                 <<" first_retry_min_ms="<<(phases?earliest:0)<<" first_retry_max_ms="<<latest
                 <<" max_requests_in_recorded_gap="<<maxRequests<<'\n';
    }
}
