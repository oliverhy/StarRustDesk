#ifndef SESAME_SUNSHINE_ROUTE_POLICY_H
#define SESAME_SUNSHINE_ROUTE_POLICY_H

namespace sesame_route {
enum class Stage { Local, InternetDirect, Relay };
enum class Result { NoNetwork, Unverified, SetupError, Cancelled, Ended };
enum class Next { PublicDirect, Relay, Stop };

constexpr Next transition(Stage from, Result result)
{
    if (result != Result::NoNetwork) return Next::Stop;
    switch (from) {
        case Stage::Local: return Next::PublicDirect;
        case Stage::InternetDirect: return Next::Relay;
        case Stage::Relay: return Next::Stop;
    }
    return Next::Stop;
}
}
#endif
