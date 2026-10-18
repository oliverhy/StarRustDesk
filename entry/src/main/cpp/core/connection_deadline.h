#pragma once
#include <cstdint>

// A fresh login budget starts once the peer transport is ready. Incoming packets
// and duplicate challenges never extend it, and the whole attempt stays bounded.
namespace ConnectionDeadline {
enum class Expired { None, Transport, Login, Total };
constexpr int64_t TRANSPORT_MS = 30000;
constexpr int64_t LOGIN_MS = 30000;
constexpr int64_t TOTAL_MS = 60000;

inline Expired evaluate(int64_t started, int64_t loginStarted, int64_t now) {
    if (started <= 0) return Expired::None;
    if (now - started >= TOTAL_MS) return Expired::Total;
    if (loginStarted > 0) {
        return now - loginStarted >= LOGIN_MS ? Expired::Login : Expired::None;
    }
    return now - started >= TRANSPORT_MS ? Expired::Transport : Expired::None;
}
}
