#ifndef SESAME_SUNSHINE_INPUT_LINK_H
#define SESAME_SUNSHINE_INPUT_LINK_H

#include "companion.h"
#include <chrono>
#include <deque>
#include <mutex>

// The UI can send only typed/pointer events on the already verified route.
// TLS is used by one background thread. No stream secrets enter ArkUI or JS.
class CompanionInput {
public:
    explicit CompanionInput(const CompanionSession &session)
        : profile(session.profile), grant(session.grant), nonce(session.nonce), port(session.tunnelPort) {}
    ~CompanionInput();
    void run();
    void close();
    bool push(int kind, int flag, int a, int b, const std::string &text);
    int status() const { return cancelled ? 0 : state.load(); }
    bool matches(const std::string &value) const { return value == nonce; }
    bool done() const { return finished.load(); }
private:
    using Clock = std::chrono::steady_clock;
    struct Event {
        int kind{}, flag{}, a{}, b{};
        std::string text;
        Clock::time_point queued{};
        ~Event();
    };
    bool emit(CompanionTls &link, uint32_t echo, const Event &event);
    void exchanges(CompanionTls &link);
    void wipe();
    CompanionProfile profile;
    std::array<uint8_t,32> grant;
    const std::string nonce;
    const uint16_t port;
    std::atomic<int> state{1}; // 1 connecting, 2 active, 3 rejected, 4 interrupted
    std::atomic<bool> cancelled{false}, finished{false};
    std::mutex mutex;
    std::deque<Event> queue;
    int fd{-1}; // accessed under mutex; only the worker owns/closes the socket
};

#endif
