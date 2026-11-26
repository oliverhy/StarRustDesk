#ifndef SESAME_SUNSHINE_COMPANION_H
#define SESAME_SUNSHINE_COMPANION_H

#include <arpa/inet.h>
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>

struct CompanionProfile {
    std::string host;
    uint16_t port{};
    std::array<uint8_t,32> pin{}, proof{};
    ~CompanionProfile();
};

bool parseCompanionProfile(const std::string &text, CompanionProfile &profile);
bool companionSameLan(in_addr local, in_addr host);
std::string pairCompanionProfile(const std::string &invitation);

class CompanionTls {
public:
    static std::unique_ptr<CompanionTls> connect(const CompanionProfile &profile, const char *&failure,
        uint16_t tunnelPort = 0);
    ~CompanionTls();
    CompanionTls(const CompanionTls &) = delete;
    CompanionTls &operator=(const CompanionTls &) = delete;
    bool read(void *out, size_t bytes);
    bool write(const void *in, size_t bytes);
    bool timeout(unsigned seconds);
    bool local(in_addr &address) const;
    int socketFd() const { return fd; }
    bool pending() const;
    int readSome(void *out, int bytes);
private:
    CompanionTls() = default;
    void *ctx{}, *ssl{};
    int fd{-1};
    unsigned timeoutSeconds{4};
    bool verified{};
};

class CompanionSession {
public:
    CompanionProfile profile;
    std::array<uint8_t,32> grant{};
    std::unique_ptr<CompanionTls> control;
    std::string nonce;
    // Written only on the authenticated WAN route, before exposing ready.
    uint16_t tunnelPort{};
    uint32_t requested{};
    bool relayRoute{};
    uint32_t authorizedVideoKbps{1400};
    const char *authorizeTunnel();
    bool startProxy();
    uint16_t rtspPort() const { return localRtsp; }
    ~CompanionSession();
private:
    void proxyLoop();
    uint16_t localRtsp{};
    int listener{-1};
    std::atomic<bool> stopping{false};
    std::thread worker;
};

std::shared_ptr<CompanionSession> acquireCompanionSession(const std::string &nonce);

#endif
