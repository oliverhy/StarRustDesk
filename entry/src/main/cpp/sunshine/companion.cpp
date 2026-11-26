#include "companion.h"
#include "bandwidth_limit.h"
#include "input_link.h"
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <algorithm>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <hilog/log.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace {
using Clock = std::chrono::steady_clock;

bool waitSocket(int fd, short events, Clock::time_point deadline)
{
    while (Clock::now() < deadline) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        pollfd wait{fd, events, 0};
        const int result = poll(&wait,1,static_cast<int>(std::max<int64_t>(1,left)));
        if (result < 0 && errno == EINTR) continue;
        return result > 0 && (wait.revents & events);
    }
    return false;
}

template<class Operation>
int sslUntil(SSL *ssl, int fd, Clock::time_point deadline, Operation operation)
{
    while (Clock::now() < deadline) {
        ERR_clear_error();
        errno = 0;
        const int n = operation();
        if (n > 0) return n;
        const int osError = errno;
        // SSL_get_error must run on this thread immediately after the operation.
        const int result = SSL_get_error(ssl,n);
        if (result == SSL_ERROR_ZERO_RETURN) return 0;
        if (result == SSL_ERROR_SYSCALL && osError == EINTR) continue;
        const short events = result == SSL_ERROR_WANT_READ ? POLLIN :
            result == SSL_ERROR_WANT_WRITE ? POLLOUT : 0;
        if (!events || !waitSocket(fd,events,deadline)) break;
    }
    return -1;
}

bool privateAddress(in_addr addr)
{
    const uint32_t a = ntohl(addr.s_addr);
    return ((a >> 24) == 10 || (a >> 16) == 0xc0a8 || (a >> 20) == 0xac1) &&
        (a & 255) != 0 && (a & 255) != 255;
}

bool decode32(const std::string &encoded, std::array<uint8_t,32> &out)
{
    if (encoded.size() != 64 || encoded.find_first_not_of("0123456789abcdef") != std::string::npos) return false;
    const auto digit = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
    for (size_t i = 0; i < out.size(); ++i) out[i] = (digit(encoded[2*i]) << 4) | digit(encoded[2*i+1]);
    return true;
}

std::string hex32(const std::array<uint8_t,32> &value)
{
    const char digit[] = "0123456789abcdef";
    std::string out;
    out.reserve(64);
    for (const auto n : value) { out += digit[n >> 4]; out += digit[n & 15]; }
    return out;
}

bool boundedConnect(int fd, const sockaddr_in &address)
{
    if (connect(fd, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
        if (errno != EINPROGRESS && errno != EINTR) return false;
        int error = 0;
        socklen_t len = sizeof(error);
        if (!waitSocket(fd,POLLOUT,Clock::now()+std::chrono::milliseconds(2200)) ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) != 0 ||
            error != 0) return false;
    }
    return true;
}

struct PinCheck {
    const std::array<uint8_t,32> *expected;
    bool matched;
};

int verifyPin(X509_STORE_CTX *verify, void *arg)
{
    auto *pin = static_cast<PinCheck *>(arg);
    X509 *cert = X509_STORE_CTX_get0_cert(verify);
    unsigned int size = 0;
    uint8_t digest[EVP_MAX_MD_SIZE]{};
    pin->matched = cert && X509_digest(cert, EVP_sha256(), digest, &size) == 1 && size == 32 &&
        CRYPTO_memcmp(pin->expected->data(), digest, 32) == 0 &&
        X509_cmp_current_time(X509_get0_notBefore(cert)) < 0 &&
        X509_cmp_current_time(X509_get0_notAfter(cert)) > 0;
    if (!pin->matched) {
        X509_STORE_CTX_set_error(verify, X509_V_ERR_CERT_REJECTED);
        return 0;
    }
    X509_STORE_CTX_set_error(verify, X509_V_OK);
    return 1;
}

bool validTimeout(int fd, unsigned seconds)
{
    timeval time{static_cast<time_t>(seconds), 0};
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, sizeof(time)) == 0 &&
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, sizeof(time)) == 0;
}
}

CompanionProfile::~CompanionProfile() { OPENSSL_cleanse(proof.data(),proof.size()); }

bool companionSameLan(in_addr local, in_addr host)
{
    const auto a = ntohl(local.s_addr), b = ntohl(host.s_addr);
    return privateAddress(local) && privateAddress(host) && a != b && a >> 8 == b >> 8;
}

bool parseCompanionProfile(const std::string &text, CompanionProfile &profile)
{
    if (text.size() > 160 || text.compare(0,4,"ss1-") != 0) return false;
    const auto a = text.find('-',4);
    const auto b = a == std::string::npos ? a : text.find('-',a+1);
    const auto c = b == std::string::npos ? b : text.find('-',b+1);
    if (a == std::string::npos || b == std::string::npos || c == std::string::npos) return false;
    profile.host = text.substr(4,a-4);
    in_addr addr{};
    unsigned int port = 0;
    const auto converted = std::from_chars(text.data()+a+1, text.data()+b, port);
    if (inet_pton(AF_INET,profile.host.c_str(),&addr) != 1 || !privateAddress(addr) ||
        converted.ec != std::errc{} || converted.ptr != text.data()+b || port < 1024 || port > 65535 ||
        !decode32(text.substr(b+1,c-b-1),profile.pin) || !decode32(text.substr(c+1),profile.proof)) return false;
    profile.port = static_cast<uint16_t>(port);
    return true;
}

std::unique_ptr<CompanionTls> CompanionTls::connect(const CompanionProfile &p, const char *&failure,
    uint16_t tunnelPort)
{
    failure = "companion_unreachable";
    auto channel = std::unique_ptr<CompanionTls>(new CompanionTls);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    if (tunnelPort) {
        if (tunnelPort < 1024) return {};
        address.sin_port = htons(tunnelPort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    } else {
        address.sin_port = htons(p.port);
        if (inet_pton(AF_INET,p.host.c_str(),&address.sin_addr) != 1 || !privateAddress(address.sin_addr)) return {};
    }
    channel->fd = socket(AF_INET,SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK,0);
    in_addr local{};
    if (channel->fd < 0 || !boundedConnect(channel->fd,address) || !channel->local(local) ||
        (tunnelPort ? local.s_addr != htonl(INADDR_LOOPBACK) : !companionSameLan(local,address.sin_addr)) ||
        !channel->timeout(tunnelPort ? 7 : 4)) return {};
    failure = "companion_identity_unconfirmed";
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    channel->ctx = ctx;
    if (!ctx || SSL_CTX_set_min_proto_version(ctx,TLS1_3_VERSION) != 1) return {};
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nullptr);
    PinCheck check{&p.pin,false};
    SSL_CTX_set_cert_verify_callback(ctx, verifyPin, &check);
    SSL *ssl = SSL_new(ctx);
    channel->ssl = ssl;
    if (!ssl || SSL_set_fd(ssl,channel->fd) != 1) return {};
    const bool okay = sslUntil(ssl,channel->fd,Clock::now()+std::chrono::seconds(channel->timeoutSeconds),
        [ssl]() { return SSL_connect(ssl); }) == 1 && check.matched && SSL_get_verify_result(ssl) == X509_V_OK;
    SSL_CTX_set_cert_verify_callback(ctx, nullptr, nullptr);
    if (!okay) return {};
    channel->verified = true;
    return channel;
}

CompanionTls::~CompanionTls()
{
    SSL_free(static_cast<SSL *>(ssl));
    SSL_CTX_free(static_cast<SSL_CTX *>(ctx));
    if (fd >= 0) close(fd);
}

bool CompanionTls::local(in_addr &address) const
{
    sockaddr_in local{};
    socklen_t len = sizeof(local);
    if (getsockname(fd,reinterpret_cast<sockaddr *>(&local),&len) != 0 || local.sin_family != AF_INET) return false;
    address = local.sin_addr;
    return true;
}

bool CompanionTls::timeout(unsigned seconds)
{
    if (!seconds || seconds > 60) return false;
    timeoutSeconds = seconds;
    return true;
}

bool CompanionTls::pending() const { return verified && SSL_pending(static_cast<SSL *>(ssl)) > 0; }
int CompanionTls::readSome(void *out, int bytes)
{
    if (!verified || bytes < 1) return -1;
    auto *session = static_cast<SSL *>(ssl);
    return sslUntil(session,fd,Clock::now()+std::chrono::seconds(timeoutSeconds),
        [session,out,bytes]() { return SSL_read(session,out,bytes); });
}

bool CompanionTls::read(void *out, size_t count)
{
    if (!verified) return false;
    auto *p = static_cast<uint8_t *>(out);
    auto *session = static_cast<SSL *>(ssl);
    const auto deadline = Clock::now()+std::chrono::seconds(timeoutSeconds);
    while (count) {
        const int chunk = static_cast<int>(std::min<size_t>(count,16384));
        const int n = sslUntil(session,fd,deadline,[session,p,chunk]() { return SSL_read(session,p,chunk); });
        if (n <= 0) return false;
        p += n; count -= n;
    }
    return true;
}

bool CompanionTls::write(const void *in, size_t count)
{
    if (!verified) return false;
    auto *p = static_cast<const uint8_t *>(in);
    auto *session = static_cast<SSL *>(ssl);
    const auto deadline = Clock::now()+std::chrono::seconds(timeoutSeconds);
    while (count) {
        const int chunk = static_cast<int>(std::min<size_t>(count,16384));
        const int n = sslUntil(session,fd,deadline,[session,p,chunk]() { return SSL_write(session,p,chunk); });
        if (n <= 0) return false;
        p += n; count -= n;
    }
    return !count;
}

std::string pairCompanionProfile(const std::string &invitation)
{
    CompanionProfile p;
    if (!parseCompanionProfile(invitation,p)) return "companion_invalid_invitation";
    const char *failure = nullptr;
    auto link = CompanionTls::connect(p,failure);
    if (!link) return failure;
    std::array<char,4> reply{};
    if (!link->write("PAI1",4) || !link->write(p.proof.data(),p.proof.size()) ||
        !link->read(reply.data(),reply.size()) || std::memcmp(reply.data(),"OKP1",4) != 0 ||
        !link->read(p.proof.data(),p.proof.size())) return "companion_invitation_rejected";
    return "ss1-" + p.host + "-" + std::to_string(p.port) + "-" + hex32(p.pin) + "-" + hex32(p.proof);
}

const char *CompanionSession::authorizeTunnel()
{
    if (tunnelPort < 1024 || control) return "companion_setup_not_authorized";
    const char *failure = nullptr;
    control = CompanionTls::connect(profile,failure,tunnelPort);
    if (!control) return failure;
    authorizedVideoKbps=std::min(requested,sesameRelayVideoCeiling(sesameBandwidthCurrent(),relayRoute));
    if (requested>=sesameStandardKbps && authorizedVideoKbps<requested) return "standard_video_budget_insufficient";
    const uint32_t rate = htonl(authorizedVideoKbps);
    char ack[4]{};
    if (!control->write("CTL2",4) || !control->write(profile.proof.data(),profile.proof.size()) ||
        !control->write(&rate,sizeof(rate)) || !control->read(ack,sizeof(ack)))
        return "companion_authorization_rejected";
    if (!std::memcmp(ack,"CAP2",4)) return "standard_video_budget_insufficient";
    if (std::memcmp(ack,"OKC2",4)!=0 || !control->read(grant.data(),grant.size())) return "companion_authorization_rejected";
    return nullptr;
}

bool CompanionSession::startProxy()
{
    listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t len = sizeof(addr);
    if (listener < 0 || bind(listener,reinterpret_cast<const sockaddr *>(&addr),sizeof(addr)) != 0 ||
        getsockname(listener,reinterpret_cast<sockaddr *>(&addr),&len) != 0 || listen(listener,2) != 0) return false;
    localRtsp = ntohs(addr.sin_port);
    worker = std::thread([this]() { proxyLoop(); });
    return localRtsp >= 1024;
}

void CompanionSession::proxyLoop()
{
    for (unsigned attempts=0; !stopping && attempts<160;) {
        pollfd wait{listener,POLLIN,0};
        if (poll(&wait,1,100) <= 0) continue;
        int client = accept4(listener,nullptr,nullptr,SOCK_CLOEXEC);
        if (client < 0) continue;
        ++attempts;
        // The core probes its loopback RTSP port with an empty connect/close.
        // Don't spend a remote TLS round trip on a request that doesn't exist.
        // Real bytes still go through the complete pinned TLS + lease check.
        char peek{};
        if (!validTimeout(client,3) || recv(client,&peek,1,MSG_PEEK)<=0 || stopping) {
            close(client); continue;
        }
        const char *failure = nullptr;
        auto tunnel = CompanionTls::connect(profile,failure,tunnelPort);
        std::array<char,4> reply{};
        std::array<unsigned char,36> hello{'R','T','S','1'};
        std::copy(grant.begin(),grant.end(),hello.begin()+4);
        const bool sent=tunnel && tunnel->write(hello.data(),hello.size());
        OPENSSL_cleanse(hello.data(),hello.size());
        if (sent && tunnel->read(reply.data(),reply.size()) &&
            std::memcmp(reply.data(),"OKR1",4) == 0) {
            using Clock=std::chrono::steady_clock;
            const auto end=Clock::now()+std::chrono::seconds(10);
            std::array<uint8_t,8192> buf{};
            size_t transferred = 0;
            bool okay=true;
            while (!stopping && okay && Clock::now()<end && transferred<512*1024) {
                pollfd streams[]{{client,POLLIN,0},{tunnel->socketFd(),POLLIN,0}};
                const bool ready=tunnel->pending();
                const int n=poll(streams,2,ready ? 0 : 100);
                if (n<0 && errno!=EINTR) break;
                if (streams[0].revents & (POLLIN | POLLHUP | POLLERR)) {
                    const ssize_t count=recv(client,buf.data(),buf.size(),0);
                    if (count<=0 || !tunnel->write(buf.data(),count)) break;
                    transferred+=count;
                }
                if (ready || (streams[1].revents & (POLLIN | POLLHUP | POLLERR))) {
                    const int count=tunnel->readSome(buf.data(),buf.size());
                    if (count<=0) break;
                    transferred+=count;
                    for (int p=0; p<count;) {
                        const auto sent=send(client,buf.data()+p,count-p,MSG_NOSIGNAL);
                        if (sent<=0) { okay=false; break; }
                        p+=sent;
                    }
                }
            }
        }
        close(client);
    }
}

CompanionSession::~CompanionSession()
{
    stopping = true;
    if (worker.joinable()) worker.join();
    if (listener >= 0) close(listener);
    localRtsp=0;
    OPENSSL_cleanse(grant.data(),grant.size());
}

CompanionInput::Event::~Event()
{
    if (!text.empty()) OPENSSL_cleanse(text.data(),text.size());
}

CompanionInput::~CompanionInput()
{
    close();
    OPENSSL_cleanse(grant.data(),grant.size());
}

void CompanionInput::close()
{
    cancelled=true;
    const std::lock_guard<std::mutex> lock(mutex);
    queue.clear();
    if (fd>=0) shutdown(fd,SHUT_RDWR);
}

void CompanionInput::wipe()
{
    const std::lock_guard<std::mutex> lock(mutex);
    OPENSSL_cleanse(grant.data(),grant.size());
    OPENSSL_cleanse(profile.proof.data(),profile.proof.size());
    fd=-1;
    queue.clear();
}

bool CompanionInput::push(int kind,int flag,int a,int b,const std::string &text)
{
    if (status()!=2 || kind<1 || kind>7 || flag<0 || flag>1 ||
        a<-4096 || a>65535 || b<-4096 || b>65535 || text.size()>256 ||
        (kind==6) != !text.empty()) return false;
    if (kind==1 && (a<0 || b<0)) return false;
    if (kind==2 && (a>4096 || b>4096)) return false;
    if (kind==6 && std::any_of(text.begin(),text.end(),[](char c) {
        return static_cast<unsigned char>(c)<32 || c==127;
    })) return false;
    const std::lock_guard<std::mutex> lock(mutex);
    if (status()!=2) return false;
    const auto now=Clock::now();
    if (!queue.empty() && kind==queue.back().kind && (kind==1 || kind==2)) {
        auto &e=queue.back();
        const bool fresh=now-e.queued<std::chrono::milliseconds(120);
        e.a=kind==2 && fresh ? std::clamp(e.a+a,-4096,4096) : a;
        e.b=kind==2 && fresh ? std::clamp(e.b+b,-4096,4096) : b;
        e.queued=now;
    } else if (queue.size()<24) {
        queue.push_back(Event{kind,flag,a,b,text,now});
    } else {
        if (kind!=1 && kind!=2) {
            // Never silently drop a key/button transition or replay a backlog.
            state=4;
            if (fd>=0) shutdown(fd,SHUT_RDWR);
        }
        return false;
    }
    return true;
}

bool CompanionInput::emit(CompanionTls &link,uint32_t echo,const Event &event)
{
    std::array<uint8_t,268> bytes{};
    std::memcpy(bytes.data(),&echo,4); // challenge bytes are already in wire order
    bytes[4]=static_cast<uint8_t>(event.kind);
    bytes[5]=static_cast<uint8_t>(event.flag);
    auto put16=[&](size_t offset,uint16_t v) {
        const auto encoded=htons(v);
        std::memcpy(bytes.data()+offset,&encoded,2);
    };
    put16(6,static_cast<uint16_t>(event.a));
    put16(8,static_cast<uint16_t>(event.b));
    put16(10,static_cast<uint16_t>(event.text.size()));
    if (!event.text.empty()) std::memcpy(bytes.data()+12,event.text.data(),event.text.size());
    const bool okay=!cancelled && link.write(bytes.data(),12+event.text.size());
    OPENSSL_cleanse(bytes.data(),bytes.size());
    return okay;
}

void CompanionInput::exchanges(CompanionTls &link)
{
    uint32_t echo=0;
    auto last=Clock::now();
    auto next_move=last;
    auto lastLoop=last;
    unsigned replies=0, peakTick=0, peakLoop=0;
    const char *reason="inactive";
    const auto ms=[](Clock::duration d) { return static_cast<unsigned>(
        std::chrono::duration_cast<std::chrono::milliseconds>(d).count()); };
    while (!cancelled && state!=4 && Clock::now()-last<std::chrono::milliseconds(920)) {
        const auto turn=Clock::now();
        peakLoop=std::max(peakLoop,ms(turn-lastLoop));
        lastLoop=turn;
        pollfd wait{link.socketFd(),POLLIN,0};
        const bool pending=link.pending();
        const int n=poll(&wait,1,pending?0:6);
        if (n<0 && errno!=EINTR) { reason="poll"; break; }
        if (pending || (wait.revents & (POLLIN|POLLHUP|POLLERR))) {
            uint32_t challenge=0;
            if (!link.read(&challenge,sizeof(challenge))) { reason="read"; break; }
            if (!challenge || challenge==echo) { reason="invalid_tick"; break; }
            echo=challenge;
            if (!emit(link,echo,Event{})) { reason="echo_write"; break; }
            const auto prior=last;
            last=Clock::now();
            peakTick=std::max(peakTick,ms(last-prior));
            ++replies;
            state=2;
        }
        if (!echo) continue;
        for (unsigned i=0;i<6 && !cancelled;++i) {
            Event event{};
            auto now=Clock::now();
            {
                const std::lock_guard<std::mutex> lock(mutex);
                if (queue.empty()) break;
                const auto &pendingEvent=queue.front();
                const bool motion=pendingEvent.kind<=2;
                if (motion && now-pendingEvent.queued>std::chrono::milliseconds(120)) {
                    queue.pop_front();
                    continue;
                }
                if (motion && now<next_move && queue.size()==1) break;
                event=pendingEvent;
                queue.pop_front();
            }
            if (now-event.queued>std::chrono::milliseconds(260)) { reason="queue_age"; state=4; break; }
            if (!emit(link,echo,event)) { reason="action_write"; state=4; break; }
            if (event.kind<=2) next_move=now+std::chrono::milliseconds(33);
        }
    }
    OH_LOG_Print(LOG_APP,LOG_INFO,0x5338,"SesameSecureClient",
        "input_lane_end phase=%{public}s replies=%{public}u last_reply_ms=%{public}u peak_tick_ms=%{public}u peak_loop_ms=%{public}u",
        cancelled ? "cancelled" : reason,replies,ms(Clock::now()-last),peakTick,peakLoop);
}

void CompanionInput::run()
{
    const char *error=nullptr;
    auto link=cancelled ? nullptr : CompanionTls::connect(profile,error,port);
    if (link && !cancelled) {
        // Each echo is only 12 bytes. Do not hold it behind a previous short
        // TLS record while waiting for a TCP ACK. No change to authentication.
        const int nodelay=1;
        setsockopt(link->socketFd(),IPPROTO_TCP,TCP_NODELAY,&nodelay,sizeof(nodelay));
        {
            const std::lock_guard<std::mutex> lock(mutex);
            fd=link->socketFd();
        }
        std::array<char,4> ack{};
        if (!cancelled && link->timeout(2) && link->write("INP1",4) &&
            link->write(grant.data(),grant.size()) && link->read(ack.data(),ack.size())) {
            if (std::memcmp(ack.data(),"OKI1",4)==0 && link->timeout(1)) exchanges(*link);
            else state=3;
        }
    }
    if (state!=3) state=4;
    wipe();
    link.reset();
    finished=true;
}
