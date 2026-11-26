#include "ledger.h"
#include <hilog/log.h>
#include <sys/socket.h>
#include <time.h>
#include <cerrno>
#include <memory>
#include <new>

namespace {
// begin precedes LiStartConnection; end follows LiStopConnection (all core workers joined).
// Frame counters: only the core VideoRecv worker. Gap list: only the serialized decode callback.
std::unique_ptr<sr::Ledger> book;
struct SocketSample {int fd=-1;uint32_t base{},last{},buf{},peak{},samples{};bool initial{},closed{};} sock;
struct Errno {int saved=errno;~Errno(){errno=saved;}};
constexpr unsigned domain=0x5338;
constexpr char tag[]="SesameSecureClient";
void sample(int fd,bool first=false) {
    Errno restore;
    uint32_t w[9]{};socklen_t n=sizeof(w);
    if(getsockopt(fd,SOL_SOCKET,55,w,&n)==0 && n==sizeof(w) && w[1]){
        if(first){sock.base=w[8];sock.initial=true;}
        sock.last=w[8];sock.buf=w[1];sock.peak=std::max(sock.peak,w[0]);++sock.samples;
    }
}
}
extern "C" void sr_begin(int enabled) {
    book.reset();sock={};
    if(enabled){book.reset(new(std::nothrow) sr::Ledger{});}
}
extern "C" void sr_socket(int fd,int end) {
    if(!book)return;
    if(!end){sock.fd=fd;sample(fd,true);}
    else if(fd==sock.fd){auto before=sock.samples;sample(fd);sock.closed=sock.samples>before;sock.fd=-1;}
}
extern "C" void sr_read(int fd,uint32_t f) {
    if(!book)return;
    book->read(f);if((book->reads&255)==0 && fd==sock.fd)sample(fd);
}
extern "C" void sr_old(uint32_t f) {
    if(!book)return;
    auto r=book->at(f);if(!r)return;
    if(!(r->flags&SR_ABANDON)){sr::inc(r->old);return;}
    Errno restore;timespec t{};
    if(clock_gettime(CLOCK_MONOTONIC,&t)==0){book->old(f,uint32_t(uint64_t(t.tv_sec)*1000+t.tv_nsec/1000000));}
    else sr::inc(r->old);
}
extern "C" void sr_bad(uint32_t f){if(book)if(auto r=book->at(f))sr::inc(r->bad);}
extern "C" void sr_auth(uint32_t f,int queued){
    if(book)if(auto r=book->at(f)){sr::inc(r->auth);if(!queued)sr::inc(r->rejected);}
}
extern "C" void sr_mark(uint32_t f,unsigned flag){if(book)book->mark(f,flag);}
extern "C" void sr_abandon(uint32_t f,unsigned have,unsigned need,uint32_t clock){
    if(book){book->abandon(f,have,need,clock);if(sock.fd>=0)sample(sock.fd);}
}
extern "C" void sr_gap(uint32_t first,uint32_t n){if(book)book->gap(first,n);}
extern "C" void sr_end(void) {
    if(!book)return;
    Errno restore;
    for(uint32_t i=0;i<book->used;i++){
        const auto g=book->gaps[i];const auto &r=*book->at(g.first);
        unsigned wait=0,abandon=0,complete=0;
        for(unsigned k=0;k<g.count;k++){const auto bits=book->at(g.first+k)->flags;
            wait+=(bits&(SR_WAIT_IDR|SR_WAIT_RFI))!=0;abandon+=(bits&SR_ABANDON)!=0;complete+=(bits&SR_FEC_COMPLETE)!=0;}
        OH_LOG_Print(LOG_APP,LOG_INFO,domain,tag,
          "lan_core_head f=%{public}u n=%{public}u raw=%{public}u old=%{public}u bad=%{public}u auth=%{public}u reject=%{public}u flags=%{public}u need=%{public}u late=%{public}u lag=%{public}u waitn=%{public}u failn=%{public}u fulln=%{public}u",
          g.first,g.count,unsigned(r.raw),unsigned(r.old),unsigned(r.bad),unsigned(r.auth),unsigned(r.rejected),unsigned(r.flags),
          unsigned(r.deficit),unsigned(r.lateAfter),unsigned(r.lateMs),wait,abandon,complete);
    }
    const auto drops=sock.initial&&sock.closed&&sock.last>=sock.base ? int64_t(sock.last-sock.base) : int64_t(-1);
    OH_LOG_Print(LOG_APP,LOG_INFO,domain,tag,
      "lan_core_end reads=%{public}u gaps=%{public}u invalid=%{public}u unknown=%{public}u buf=%{public}u peak=%{public}u samples=%{public}u drops=%{public}lld",
      book->reads,book->used,book->invalidGap,book->invalidHint,sock.buf,sock.peak,sock.samples,(long long)drops);
    book.reset();
}
