// USB-authorized experiment bridge. No compiled-in host or credential.
#include <napi/native_api.h>
#include <hilog/log.h>
#include <network/netmanager/net_connection.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <array>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include "route_policy.h"
#include "bandwidth_limit.h"
#include "picture_recovery.h"
#ifdef SESAME_SUNSHINE_COMPANION
#include <openssl/crypto.h>
#include "companion.h"
#include "input_link.h"
#ifdef SESAME_SUNSHINE_USB_LAN_CANDIDATE
#include "bench_lan_candidate.h"
#endif
#endif
#ifdef SESAME_SUNSHINE_COMPANION_WAN
#include <openssl/sha.h>
#endif

extern "C" int sesame_wan_phone_public(const uint8_t *secret, uint8_t *out);
extern "C" int sesame_valid_sunshine_endpoint(const char *endpoint, int direct);
extern "C" int sesame_direct_announce(int fd, const uint8_t *ticket, const char *observer);
extern "C" int sesame_mapping_announce(int fd, const uint8_t *ticket, const char *observer);
struct DirectPathReport {
    uint32_t tx, tx_errors, rx, source_filtered, non_handshake, candidate_rx, receive_network_errors, authenticated;
};
struct VideoPathSample {
    uint32_t stage, ms, packets, event_gap, peak_gap, previous_frame, frame, loop_peak;
};
extern "C" int sesame_auto_media_phone(int fd, const uint8_t *secret, const char *public_key,
    const char *endpoint, int direct, const char *context, void (*ready)(const char *), int (*cancelled)(),
    void (*report)(const DirectPathReport *), void (*video_report)(const VideoPathSample *),
    void (*bandwidth_report)(const BandwidthEstimate *), uint32_t (*media_epoch)(uint32_t), void (*frame_counts)(const char *));
#ifdef SESAME_SUNSHINE_COMPANION_WAN
extern "C" int sesame_companion_wan_phone(int fd, const uint8_t *root, const char *broker,
    const char *context, void (*stage)(const char *, int, uint16_t), int (*cancelled)(),
    void (*report)(const DirectPathReport *), void (*video_report)(const VideoPathSample *),
    void (*bandwidth_report)(const BandwidthEstimate *),
    uint32_t (*media_epoch)(uint32_t), void (*frame_report)(const char *));
#endif
napi_value sesameRunSecureClient(napi_env env, napi_callback_info info);
napi_value sesameSecureSnapshot(napi_env env, napi_callback_info info);
napi_value sesameSecureVideoRatio(napi_env env, napi_callback_info info);
napi_value sesameDisplays(napi_env env,napi_callback_info info);
napi_value sesameSelectDisplay(napi_env env,napi_callback_info info);
napi_value sesameCancelSecureClient(napi_env env, napi_callback_info info);

class Fd {
public:
    explicit Fd(int value = -1) : fd(value) {}
    ~Fd() { if (fd >= 0) close(fd); }
    int release() { int value = fd; fd = -1; return value; }
    int fd;
};

static bool cell(NetConn_NetHandle &selected, int &query)
{
    NetConn_NetHandleList all{};
    query = OH_NetConn_GetAllNets(&all);
    if (query || all.netHandleListSize < 0 || all.netHandleListSize > NETCONN_MAX_NET_SIZE) return false;
    for (int i = 0; i < all.netHandleListSize; ++i) {
        auto item = all.netHandles[i];
        NetConn_NetCapabilities c{};
        if (OH_NetConn_GetNetCapabilities(&item, &c) != 0 ||
            c.bearerTypesSize <= 0 || c.bearerTypesSize > NETCONN_MAX_BEARER_TYPE_SIZE) continue;
        bool cellular = false, other = false;
        for (int j = 0; j < c.bearerTypesSize; ++j) {
            if (c.bearerTypes[j] == NETCONN_BEARER_CELLULAR) cellular = true;
            else other = true;
        }
        bool internet = false;
        if (c.netCapsSize > 0 && c.netCapsSize <= NETCONN_MAX_CAP_SIZE) {
            for (int j = 0; j < c.netCapsSize; ++j) {
                if (c.netCaps[j] == NETCONN_NET_CAPABILITY_INTERNET) internet = true;
            }
        }
        if (cellular && !other && internet) { selected = item; return true; }
    }
    return false;
}

static std::string get_cellular_socket(Fd &udp)
{
    // Never fall back to the default network if a cellular binding isn't confirmed.
    NetConn_NetHandle net{};
    int query = 0;
    bool available = cell(net, query);
    for (int i = 0; i < 58 && !available && query == 0; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(190));
        available = cell(net, query);
    }
    if (!available) return "stage=no_active_cellular query_code=" + std::to_string(query);
    udp.fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp.fd < 0) return "stage=phone_socket_failed";
    int code = OH_NetConn_BindSocket(udp.fd, &net);
    if (code != 0) return "stage=cellular_bind_failed bind_code=" + std::to_string(code);
    sockaddr_in local{};
    local.sin_family = AF_INET;
    if (bind(udp.fd, reinterpret_cast<sockaddr *>(&local), sizeof(local)) != 0) return "stage=phone_bind_failed";
    return {};
}

struct Secret {
    std::array<uint8_t, 32> key{};
    ~Secret() { volatile uint8_t *p = key.data(); for (size_t i = 0; i < key.size(); ++i) p[i] = 0; }
};

static bool write_public_result(const std::string &name, const std::string &value)
{
    const std::string temp = name + ".tmp";
    Fd out(open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (out.fd < 0) return false;
    bool wrote = write(out.fd, value.data(), value.size()) == static_cast<ssize_t>(value.size());
    if (wrote && rename(temp.c_str(), name.c_str()) == 0) return true;
    unlink(temp.c_str());
    return false;
}

static bool string_arg(napi_env env, napi_value arg, std::string &out)
{
    std::array<char, 256> buffer{};
    size_t total = 0, size = 0;
    if (napi_get_value_string_utf8(env, arg, nullptr, 0, &total) != napi_ok || total >= buffer.size() ||
        napi_get_value_string_utf8(env, arg, buffer.data(), buffer.size(), &size) != napi_ok || total != size) return false;
    out.assign(buffer.data(), size);
    return true;
}

static bool valid_hex(const std::string &value, size_t length)
{
    return value.size() == length && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}

enum UiLink : int { Direct = 1, Fallback = 2, Relay = 3, DirectReady = 4, RelayReady = 5,
    Unreachable = 6, SetupFailed = 7, Stopped = 8, PeerUnverified = 9, LanChecking = 10, LanReady = 11,
    MeasuringBandwidth = 12 };
static std::atomic<int> ui_link{0};
static std::atomic<bool> ui_link_busy{false}, ui_link_cancelled{false};
static std::mutex bandwidth_mtx;
static BandwidthEstimate bandwidth_current;
static std::atomic<uint32_t> delivered_video_packets{0};
static std::atomic<uint32_t> requested_media_epoch{0}, active_media_epoch{0};

uint32_t sesameDeliveredVideoPackets() { return delivered_video_packets.load(); }
static uint32_t link_media_epoch(uint32_t acknowledged)
{
    active_media_epoch.store(acknowledged);
    return requested_media_epoch.load();
}

bool sesameRefreshLocalMediaEndpoints(bool companion)
{
    const auto status = ui_link.load();
    if ((status != LanReady && status != DirectReady && status != RelayReady) || ui_link_cancelled) return false;
    const auto before = requested_media_epoch.load();
    if (before >= (companion ? 16U : 4U) || before != active_media_epoch) return false;
    requested_media_epoch.store(before + 1);
    for (int attempt = 0; attempt < 60 && !ui_link_cancelled; ++attempt) {
        if (active_media_epoch == before + 1) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return false;
}

BandwidthEstimate sesameBandwidthCurrent()
{
    const std::lock_guard<std::mutex> lock(bandwidth_mtx);
    return bandwidth_current;
}

static void link_bandwidth_report(const BandwidthEstimate *sample)
{
    if (!sample || sample->state < 1 || sample->state > 5 || sample->probeCapKbps > 72000 ||
        sample->goodKbps > sample->probeCapKbps || sample->unstableKbps > sample->probeCapKbps) return;
    {
        const std::lock_guard<std::mutex> lock(bandwidth_mtx);
        bandwidth_current = *sample;
    }
    if (sample->state == 1) ui_link = MeasuringBandwidth;
    else OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe",
        "bandwidth_result state=%{public}u good_kbps=%{public}u unstable_kbps=%{public}u cap_kbps=%{public}u",
        sample->state, sample->goodKbps, sample->unstableKbps, sample->probeCapKbps);
}

static int link_cancelled() { return ui_link_cancelled.load() ? 1 : 0; }
static void link_direct_ready(const char *prefix)
{
    ui_link = DirectReady;
    write_public_result(std::string(prefix) + ".active", "direct\n");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_public_direct_authenticated=1");
}
static void link_relay_ready(const char *prefix)
{
    ui_link = RelayReady;
    write_public_result(std::string(prefix) + ".active", "relay\n");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_public_relay_authenticated=1");
}

static void link_direct_report(const DirectPathReport *s)
{
    if (!s) return;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe",
        "direct_path_diag tx=%{public}u tx_errors=%{public}u rx=%{public}u source_filtered=%{public}u "
        "non_handshake=%{public}u candidate_rx=%{public}u receive_network_errors=%{public}u authenticated=%{public}u",
        s->tx, s->tx_errors, s->rx, s->source_filtered, s->non_handshake, s->candidate_rx,
        s->receive_network_errors, s->authenticated);
}

static void link_video_report(const VideoPathSample *s)
{
    if (!s) return;
    if (s->stage == 3) delivered_video_packets.store(s->packets);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe",
        "video_path stage=%{public}u ms=%{public}u packets=%{public}u event_gap=%{public}u peak_gap=%{public}u "
        "previous_frame=%{public}u frame=%{public}u loop_peak=%{public}u", s->stage, s->ms, s->packets,
        s->event_gap, s->peak_gap, s->previous_frame, s->frame, s->loop_peak);
}

static void link_frame_report(const char *line)
{
#ifdef SESAME_SUNSHINE_NARROW_TRIAL
    if (!line || strnlen(line, 570) == 570 || std::strncmp(line, "rx_ledger", 9) != 0) return;
    // The isolated Rust bridge emits only bounded counts, not fingerprints or payload.
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "%{public}s", line);
#else
    (void)line;
#endif
}

static std::string read_fixture(const std::string &file)
{
    Fd in(open(file.c_str(), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC));
    struct stat info{};
    std::array<char,180> body{};
    if (in.fd < 0 || fstat(in.fd, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || info.st_size >= static_cast<ssize_t>(body.size())) return {};
    const auto n = read(in.fd, body.data(), body.size());
    if (n <= 1 || n != info.st_size || body[n-1] != '\n') return {};
    return std::string(body.data(), static_cast<size_t>(n-1));
}

static std::string await_fixture(const std::string &file, int limit_ms)
{
    using namespace std::chrono;
    const auto end = steady_clock::now() + milliseconds(limit_ms);
    while (!link_cancelled() && steady_clock::now() < end) {
        std::string value = read_fixture(file);
        if (!value.empty()) return value;
        std::this_thread::sleep_for(milliseconds(45));
    }
    return {};
}

static bool decode_ticket(const std::string &value, Secret &out)
{
    if (!valid_hex(value, 64)) return false;
    auto part = [](char c) -> unsigned { return c <= '9' ? c - '0' : 10 + c - 'a'; };
    for (size_t i = 0; i < out.key.size(); ++i)
        out.key[i] = static_cast<uint8_t>((part(value[2*i]) << 4) | part(value[2*i+1]));
    return true;
}

#ifdef SESAME_SUNSHINE_LAN_BENCH
static std::mutex lan_mtx;
static std::string lan_ready_nonce;

bool sesameLanAuthorized(const std::string &nonce)
{
    const std::lock_guard<std::mutex> lock(lan_mtx);
    return !lan_ready_nonce.empty() && lan_ready_nonce == nonce && ui_link == LanReady;
}

static bool same_private_lan(in_addr a, in_addr b)
{
    const auto x = ntohl(a.s_addr), y = ntohl(b.s_addr);
    const bool privateNet = (x >> 24) == 10 || (x >> 16) == 0xc0a8 || (x >> 20) == 0xac1;
    return privateNet && x != y && (x >> 8) == (y >> 8) &&
        (x & 255) > 0 && (x & 255) < 255 && (y & 255) > 0 && (y & 255) < 255;
}

enum class BindLan { Bound, NoRoute, Error };

static BindLan bind_lan_wifi(Fd &udp, in_addr addr, uint16_t &port)
{
    NetConn_NetHandleList all{};
    if (OH_NetConn_GetAllNets(&all) != 0 || all.netHandleListSize < 0 ||
        all.netHandleListSize > NETCONN_MAX_NET_SIZE) return BindLan::Error;
    bool probeError = false;
    for (int i = 0; i < all.netHandleListSize; ++i) {
        auto net = all.netHandles[i];
        NetConn_NetCapabilities caps{};
        if (OH_NetConn_GetNetCapabilities(&net, &caps) != 0) { probeError = true; continue; }
        if (caps.bearerTypesSize != 1 || caps.bearerTypes[0] != NETCONN_BEARER_WIFI) continue;
        Fd socketFd(socket(AF_INET, SOCK_DGRAM, 0));
        if (socketFd.fd < 0 || OH_NetConn_BindSocket(socketFd.fd, &net) != 0) {
            probeError = true; continue;
        }
        sockaddr_in local{};
        local.sin_family = AF_INET;
        local.sin_addr = addr;
        if (bind(socketFd.fd, reinterpret_cast<const sockaddr *>(&local), sizeof(local)) != 0) {
            if (errno != EADDRNOTAVAIL && errno != ENETUNREACH && errno != ENETDOWN) probeError = true;
            continue;
        }
        socklen_t len = sizeof(local);
        if (getsockname(socketFd.fd, reinterpret_cast<sockaddr *>(&local), &len) != 0) return BindLan::Error;
        port = ntohs(local.sin_port);
        if (port < 1024) return BindLan::Error;
        udp.fd = socketFd.release();
        return BindLan::Bound;
    }
    return probeError ? BindLan::Error : BindLan::NoRoute;
}

static bool bind_default_internet(Fd &udp, NetConn_NetHandle &net, bool lookup)
{
    if (lookup && OH_NetConn_GetDefaultNet(&net) != 0) return false;
    NetConn_NetCapabilities caps{};
    if (OH_NetConn_GetNetCapabilities(&net, &caps) != 0 || caps.netCapsSize <= 0 ||
        caps.netCapsSize > NETCONN_MAX_CAP_SIZE) return false;
    if (std::find(caps.netCaps, caps.netCaps + caps.netCapsSize, NETCONN_NET_CAPABILITY_INTERNET)
        == caps.netCaps + caps.netCapsSize) return false;
    udp.fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp.fd < 0 || OH_NetConn_BindSocket(udp.fd, &net) != 0) return false;
    sockaddr_in local{};
    local.sin_family = AF_INET;
    return bind(udp.fd, reinterpret_cast<const sockaddr *>(&local), sizeof(local)) == 0;
}

static void link_lan_ready(const char *context)
{
    const std::string prefix(context);
    {
        const std::lock_guard<std::mutex> lock(lan_mtx);
        lan_ready_nonce = prefix.substr(prefix.size() - 24);
    }
    ui_link = LanReady;
    write_public_result(prefix + ".active", "lan\n");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_wifi_lan_authenticated=1");
}

struct LanOutcome {
    sesame_route::Result result;
    int phase;
    const char *reason;
};

static LanOutcome lan_link(const std::string &prefix, const std::string &offer, bool automatic)
{
    using sesame_route::Result;
    if (automatic && offer == "none") return {Result::NoNetwork, Unreachable, "lan_no_eligible_candidate"};
    char ip[16]{}, remote[23]{}, pub[65]{};
    int consumed = 0;
    if (std::sscanf(offer.c_str(), "v1 %15[0-9.] %22[0-9.:] %64[0-9a-f]%n", ip, remote, pub, &consumed) != 3 ||
        consumed != static_cast<int>(offer.size()) || !valid_hex(pub, 64))
        return {Result::SetupError, SetupFailed, "lan_offer_invalid"};
    const std::string endpoint(remote);
    const auto sep = endpoint.find(':');
    in_addr local{}, dest{};
    if (sep == std::string::npos || inet_pton(AF_INET, ip, &local) != 1 ||
        inet_pton(AF_INET, endpoint.substr(0, sep).c_str(), &dest) != 1 || !same_private_lan(local, dest))
        return {Result::SetupError, SetupFailed, "lan_endpoint_invalid"};
    Fd udp;
    uint16_t port = 0;
    auto bound = bind_lan_wifi(udp, local, port);
    if (bound == BindLan::NoRoute) return {Result::NoNetwork, Unreachable, "lan_wifi_unavailable"};
    if (bound == BindLan::Error) return {Result::SetupError, SetupFailed, "lan_wifi_binding_failed"};
    if (link_cancelled()) return {Result::Cancelled, Stopped, "cancelled"};
    Secret device;
    std::array<uint8_t,32> key{};
    if (getrandom(device.key.data(), device.key.size(), 0) != static_cast<ssize_t>(device.key.size()) ||
        sesame_wan_phone_public(device.key.data(), key.data()) != 0)
        return {Result::SetupError, SetupFailed, "lan_session_key_unavailable"};
    constexpr char hex[] = "0123456789abcdef";
    std::string publicKey;
    for (auto n : key) { publicKey += hex[n >> 4]; publicKey += hex[n & 15]; }
    const char *pubSuffix = automatic ? ".lan-pub" : ".pub";
    const char *requestSuffix = automatic ? ".lan-request" : ".request";
    if (!write_public_result(prefix + pubSuffix, publicKey + " " + std::to_string(port) + "\n") ||
        !write_public_result(prefix + requestSuffix, "lan\n"))
        return {Result::SetupError, SetupFailed, "lan_handoff_failed"};
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_wifi_binding_verified=1");
    const int status = sesame_auto_media_phone(udp.release(), device.key.data(), pub, remote, 2,
        prefix.c_str(), link_lan_ready, link_cancelled, link_direct_report, link_video_report, link_bandwidth_report, link_media_epoch, nullptr);
    const bool authenticated = ui_link == LanReady;
    {
        const std::lock_guard<std::mutex> lock(lan_mtx);
        lan_ready_nonce.clear();
    }
    if (link_cancelled() || status == 4) return {Result::Cancelled, Stopped, "cancelled"};
    if (authenticated || status == 0) return {Result::Ended, Stopped, "lan_ended"};
    if (status == 6) return {Result::Unverified, PeerUnverified, "lan_peer_identity_unconfirmed"};
    if (status == 5) return {Result::NoNetwork, Unreachable, "lan_udp_unreachable"};
    return {Result::SetupError, SetupFailed, "lan_transport_failed"};
}
#endif

#ifdef SESAME_SUNSHINE_COMPANION
static std::mutex companion_mtx;
static std::shared_ptr<CompanionSession> current_companion;

std::shared_ptr<CompanionSession> acquireCompanionSession(const std::string &nonce)
{
    const std::lock_guard<std::mutex> guard(companion_mtx);
    const auto path = ui_link.load();
    if (!current_companion || current_companion->nonce != nonce ||
        (path != LanReady && !(current_companion->tunnelPort && (path == DirectReady || path == RelayReady)))) return {};
    return current_companion;
}

static void companion_lan_ready(const char *nonce)
{
    {
        const std::lock_guard<std::mutex> guard(lan_mtx);
        lan_ready_nonce = nonce;
    }
    ui_link = LanReady;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "companion_wifi_udp_authenticated=1");
}

static LanOutcome companion_lan(const std::shared_ptr<CompanionSession> &session)
{
    using R = sesame_route::Result;
    ui_link = LanChecking;
    // Do not try the stored private address on a cellular-only interface.
    NetConn_NetHandleList all{};
    if (OH_NetConn_GetAllNets(&all) != 0 || all.netHandleListSize < 0 ||
        all.netHandleListSize > NETCONN_MAX_NET_SIZE) return {R::SetupError,SetupFailed,"companion_wifi_query_failed"};
    bool wifi = false;
    for (int i = 0; i < all.netHandleListSize; ++i) {
        auto net = all.netHandles[i];
        NetConn_NetCapabilities caps{};
        if (OH_NetConn_GetNetCapabilities(&net,&caps) == 0 && caps.bearerTypesSize == 1 &&
            caps.bearerTypes[0] == NETCONN_BEARER_WIFI) wifi = true;
    }
    if (!wifi) return {R::NoNetwork,Unreachable,"companion_wifi_unavailable"};
    const char *failure=nullptr;
    session->control = CompanionTls::connect(session->profile,failure);
    if (!session->control)
        return std::strcmp(failure,"companion_identity_unconfirmed") == 0 ?
            LanOutcome{R::Unverified,PeerUnverified,failure} : LanOutcome{R::NoNetwork,Unreachable,failure};
    in_addr local{};
    Fd udp;
    uint16_t port=0;
    const auto bound = session->control->local(local) ? bind_lan_wifi(udp,local,port) : BindLan::Error;
    if (bound == BindLan::NoRoute) return {R::NoNetwork,Unreachable,"companion_wifi_unavailable"};
    if (bound != BindLan::Bound) return {R::SetupError,SetupFailed,"companion_wifi_bind_failed"};
    if (link_cancelled()) return {R::Cancelled,Stopped,"cancelled"};
    Secret device;
    std::array<uint8_t,32> pub{};
    if (getrandom(device.key.data(),device.key.size(),0)!=static_cast<ssize_t>(device.key.size()) ||
        sesame_wan_phone_public(device.key.data(),pub.data())!=0)
        return {R::SetupError,SetupFailed,"companion_key_failed"};
    auto &ctl=*session->control;
    char ack[4]{};
    std::array<uint8_t,32> host{};
    uint16_t hostPort=0, phonePort=htons(port);
    uint32_t kbps=htonl(session->requested);
    if (!ctl.write("CTL1",4) || !ctl.write(session->profile.proof.data(),session->profile.proof.size()) ||
        !ctl.write(pub.data(),pub.size()) || !ctl.write(&phonePort,sizeof(phonePort)) ||
        !ctl.write(&kbps,sizeof(kbps)) || !ctl.read(ack,sizeof(ack)) || std::memcmp(ack,"OKC1",4)!=0 ||
        !ctl.read(host.data(),host.size()) || !ctl.read(&hostPort,sizeof(hostPort)) ||
        !ctl.read(session->grant.data(),session->grant.size()))
        return {R::Unverified,PeerUnverified,"companion_authorization_rejected"};
    const auto addr = session->profile.host + ":" + std::to_string(ntohs(hostPort));
    if (ntohs(hostPort)<1024)
        return {R::SetupError,SetupFailed,"companion_media_route_invalid"};
    constexpr char hex[]="0123456789abcdef";
    std::string hostPublic;
    for (auto b:host) { hostPublic += hex[b>>4]; hostPublic += hex[b&15]; }
    {
        const std::lock_guard<std::mutex> guard(companion_mtx);
        current_companion = session;
    }
    OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,"SesameWanProbe","companion_wifi_control_authenticated=1");
    const auto status = sesame_auto_media_phone(udp.release(),device.key.data(),hostPublic.c_str(),addr.c_str(),2,
        session->nonce.c_str(),companion_lan_ready,link_cancelled,link_direct_report,link_video_report,link_bandwidth_report,
        link_media_epoch,link_frame_report);
    {
        const std::lock_guard<std::mutex> guard(companion_mtx);
        current_companion.reset();
    }
    {
        const std::lock_guard<std::mutex> guard(lan_mtx);
        lan_ready_nonce.clear();
    }
    if (link_cancelled() || status == 4) return {R::Cancelled,Stopped,"companion_session_ended"};
    if (status == 0) return {R::Ended,Stopped,"companion_session_ended"};
    if (status == 6) return {R::Unverified,PeerUnverified,"companion_peer_unverified"};
    if (status == 5) return {R::NoNetwork,Unreachable,"companion_media_unavailable"};
    return {R::SetupError,SetupFailed,"companion_media_failed"};
}

#ifdef SESAME_SUNSHINE_COMPANION_WAN
static void companion_public_stage(const char *nonce, int stage, uint16_t port)
{
    constexpr auto tag = "SesameWanProbe";
    if (link_cancelled()) return;
    if (stage == 1) {
        ui_link = Direct;
        OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,tag,"companion_wan_direct_attempt=1");
    } else if (stage == 2) {
        ui_link = Fallback;
        OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,tag,"companion_wan_direct_no_reply=1");
    } else if (stage == 3) {
        ui_link = Relay;
        OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,tag,"companion_wan_relay_attempt=1");
    } else if ((stage == 4 || stage == 5) && port >= 1024) {
        const std::lock_guard<std::mutex> guard(companion_mtx);
        if (!current_companion || current_companion->nonce != nonce) return;
        current_companion->tunnelPort = port;
        current_companion->relayRoute = stage == 5;
        ui_link = stage == 4 ? DirectReady : RelayReady;
        OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,tag, stage == 4 ?
            "companion_wan_direct_authenticated=1" : "companion_wan_relay_authenticated=1");
    }
}
#endif

static std::string companion_link(const std::string &packed, const std::string &nonce, uint32_t requested)
{
    auto finish = [](int stage, const char *status) {
        ui_link = link_cancelled() ? Stopped : stage;
        OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,"SesameWanProbe","companion_route_result=%{public}s",status);
        return std::string(status);
    };
    auto session = std::make_shared<CompanionSession>();
    session->nonce = nonce;
    session->requested = requested;
    if (!parseCompanionProfile(packed,session->profile)) return finish(SetupFailed,"companion_profile_invalid");
#ifdef SESAME_SUNSHINE_USB_LAN_CANDIDATE
    if (requested==20000 && session->profile.port==47837) {
        const auto candidate=benchLanCandidate();
        if (!candidate.empty()) {
            OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,"SesameWanProbe","companion_bench_lan_candidate saved_address_matches=%{public}d",
                         static_cast<int>(session->profile.host==candidate));
            session->profile.host=candidate; // session-only; the existing pin & proof remain mandatory
        }
    }
#endif
    const auto lan = companion_lan(session);
#ifdef SESAME_SUNSHINE_COMPANION_WAN
    if (!link_cancelled() && sesame_route::transition(sesame_route::Stage::Local,lan.result) == sesame_route::Next::PublicDirect) {
        // Drop the private candidate and its one-use lease before going public.
        session->control.reset();
        session->grant.fill(0);
        Fd udp;
        NetConn_NetHandle network{};
        if (!bind_default_internet(udp,network,true)) return finish(Unreachable,"companion_internet_unavailable");
        NetConn_NetCapabilities caps{};
        if (OH_NetConn_GetNetCapabilities(&network,&caps) == 0 && caps.bearerTypesSize == 1 &&
            caps.bearerTypes[0] == NETCONN_BEARER_CELLULAR)
            OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,"SesameWanProbe","companion_cellular_binding_verified=1");
        OH_LOG_Print(LOG_APP,LOG_INFO,0x5337,"SesameWanProbe","companion_lan_to_public=1");
        Secret pairRoot;
        if (SHA256(session->profile.proof.data(),session->profile.proof.size(),pairRoot.key.data()) == nullptr)
            return finish(SetupFailed,"companion_broker_authorization_failed");
        {
            const std::lock_guard<std::mutex> guard(companion_mtx);
            current_companion = session;
        }
        const auto status = sesame_companion_wan_phone(udp.release(),pairRoot.key.data(),SESAME_SUNSHINE_COMPANION_BROKER,
            nonce.c_str(),companion_public_stage,link_cancelled,link_direct_report,link_video_report,
            link_bandwidth_report,link_media_epoch,link_frame_report);
        {
            const std::lock_guard<std::mutex> guard(companion_mtx);
            current_companion.reset();
        }
        if (link_cancelled() || status == 0 || status == 4) return finish(Stopped,"companion_session_ended");
        if (status == 6) return finish(PeerUnverified,"companion_public_peer_unverified");
        if (status == 5) return finish(Unreachable,"companion_public_unreachable");
        return finish(SetupFailed,"companion_public_failed");
    }
#endif
    return finish(lan.phase,lan.reason);
}
#endif

static std::string auto_link(const std::string &prefix, uint32_t limit)
{
    auto finish = [&](int phase, const char *status) {
        const bool canceled = link_cancelled();
        std::string result = canceled ? "cancelled" : status;
        write_public_result(prefix + ".result", result + "\n");
        ui_link = canceled ? Stopped : phase;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_transport_result=%{public}s", result.c_str());
        return result;
    };
    bool automatic = false;
    NetConn_NetHandle defaultNetwork{};
#ifdef SESAME_SUNSHINE_LAN_BENCH
    struct stat statBuf{};
    const auto autoPath = prefix + ".auto";
    if (lstat(autoPath.c_str(), &statBuf) == 0) {
        const auto routeTicket = read_fixture(autoPath);
        if (unlink(autoPath.c_str()) != 0 || routeTicket != "v1")
            return finish(SetupFailed, "route_ticket_invalid");
        automatic = true;
    } else if (errno != ENOENT) {
        return finish(SetupFailed, "route_ticket_read_failed");
    }
    const auto lanPath = prefix + ".lan";
    const int lanStat = lstat(lanPath.c_str(), &statBuf);
    if (lanStat == 0) {
        const auto lan = read_fixture(lanPath);
        if (unlink(lanPath.c_str()) != 0) return finish(SetupFailed, "lan_ticket_not_consumed");
        ui_link = LanChecking;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_route_lan_attempt=1");
        const auto outcome = lan_link(prefix, lan, automatic);
        if (!automatic || link_cancelled() ||
            sesame_route::transition(sesame_route::Stage::Local, outcome.result) != sesame_route::Next::PublicDirect)
            return finish(outcome.phase, outcome.reason);
        ui_link = Direct;
        if (!write_public_result(prefix + ".wan-needed", "lan_unreachable\n"))
            return finish(SetupFailed, "route_handoff_failed");
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_route_lan_to_public=1");
    } else if (automatic || errno != ENOENT) {
        return finish(SetupFailed, "lan_ticket_missing_or_invalid");
    }
#endif
    // This test app never accepts a raw endpoint, route key, or WAN target from
    // the Web UI. The USB controller provisions a one-use sandboxed offer.
    std::string offer = automatic ? await_fixture(prefix + ".offer", 27000) : read_fixture(prefix + ".offer");
    if (link_cancelled()) return finish(Stopped, "cancelled");
    if (unlink((prefix + ".offer").c_str()) != 0) return finish(SetupFailed, "offer_not_consumed");
    Secret ticket, device;
    if (offer.size() < 140 || offer.size() > 152 || offer[64] != ' ' || offer[129] != ' ' ||
        !decode_ticket(offer.substr(0, 64), ticket) || !valid_hex(offer.substr(65,64),64))
        return finish(SetupFailed, "offer_missing_or_invalid");
    const std::string relay = offer.substr(65,64);
    const std::string observer = offer.substr(130);
    if (sesame_valid_sunshine_endpoint(observer.c_str(), 0) != 1)
        return finish(SetupFailed, "offer_endpoint_invalid");
    std::fill(offer.begin(), offer.end(), '\0');
    Fd udp;
#ifdef SESAME_SUNSHINE_LAN_BENCH
    if (automatic && !bind_default_internet(udp, defaultNetwork, true))
        return finish(Unreachable, "no_default_internet_network");
#endif
    if (!automatic && !get_cellular_socket(udp).empty()) return finish(SetupFailed, "cellular_binding_failed");
    if (link_cancelled()) return finish(Stopped, "cancelled");
    std::array<uint8_t,32> key{};
    if (getrandom(device.key.data(), device.key.size(), 0) != static_cast<ssize_t>(device.key.size()) ||
        sesame_wan_phone_public(device.key.data(), key.data()) != 0)
        return finish(SetupFailed, "session_key_unavailable");
    constexpr char hex[] = "0123456789abcdef";
    std::string pub;
    for (auto n : key) { pub += hex[n >> 4]; pub += hex[n & 15]; }
    if (!write_public_result(prefix + ".pub", pub + "\n") ||
        !write_public_result(prefix + ".request", std::to_string(limit) + "\n"))
        return finish(SetupFailed, "request_handoff_failed");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe",
        automatic ? "ui_default_internet_binding_verified=1" : "ui_cellular_binding_verified=1");
    ui_link = Direct;
    const bool advertised = sesame_direct_announce(udp.fd, ticket.key.data(), observer.c_str()) == 0;
    // Only the USB controller that provisions this one-use offer can enable
    // the bounded two-port mapping measurement on the same socket.
    const bool diag = read_fixture(prefix + ".natdiag") == "v1";
    unlink((prefix + ".natdiag").c_str());
    if (diag && advertised && !link_cancelled()) {
        int status = sesame_mapping_announce(udp.fd, ticket.key.data(), observer.c_str());
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "direct_mapping_probe_sent=%{public}d", status == 0 ? 1 : 0);
    }
    const std::string candidate = await_fixture(prefix + ".direct", 13000);
    unlink((prefix + ".direct").c_str());
    if (link_cancelled()) return finish(Stopped, "cancelled");
    if (candidate.empty()) return finish(SetupFailed, "direct_offer_unconfirmed");
    if (candidate != "unreachable") {
        const auto sep = candidate.find(' ');
        if (!advertised || sep == std::string::npos || sep > 22 || !valid_hex(candidate.substr(sep+1),64))
            return finish(SetupFailed, "direct_offer_invalid");
        const auto endpoint = candidate.substr(0, sep);
        const auto public_key = candidate.substr(sep+1);
        if (endpoint == observer || sesame_valid_sunshine_endpoint(endpoint.c_str(), 1) != 1)
            return finish(SetupFailed, "direct_offer_invalid");
        int status = sesame_auto_media_phone(udp.release(), device.key.data(), public_key.c_str(),
            endpoint.c_str(), 1, prefix.c_str(), link_direct_ready, link_cancelled, link_direct_report, link_video_report,
            link_bandwidth_report, link_media_epoch, nullptr);
        if (link_cancelled()) return finish(Stopped, "cancelled");
        if (status == 0) return finish(Stopped, "direct_ended");
        if (status == 6) return finish(PeerUnverified, "direct_peer_identity_unconfirmed");
        using sesame_route::Result;
        if (sesame_route::transition(sesame_route::Stage::InternetDirect,
                status == 5 ? Result::NoNetwork : Result::SetupError) != sesame_route::Next::Relay)
            return finish(SetupFailed, "direct_transport_failed");
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_direct_no_candidate_handshake=1");
    }
    // Only a network timeout/unreachable candidate opens this branch.
    if (udp.fd >= 0) close(udp.release());
    ui_link = Fallback;
    if (!write_public_result(prefix + ".timeout", "direct_timeout\n"))
        return finish(SetupFailed, "timeout_handoff_failed");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5337, "SesameWanProbe", "ui_direct_timeout_fallback=1");
    std::this_thread::sleep_for(std::chrono::milliseconds(920));
    ui_link = Relay;
    const auto gate = await_fixture(prefix + ".relay", 15000);
    unlink((prefix + ".relay").c_str());
    if (link_cancelled()) return finish(Stopped, "cancelled");
    if (gate != "ready") return finish(Unreachable, "relay_unreachable");
    Fd relay_udp;
#ifdef SESAME_SUNSHINE_LAN_BENCH
    if (automatic && !bind_default_internet(relay_udp, defaultNetwork, false))
        return finish(Unreachable, "relay_internet_network_lost");
#endif
    if (!automatic && !get_cellular_socket(relay_udp).empty()) return finish(SetupFailed, "relay_bind_failed");
    const int status = sesame_auto_media_phone(relay_udp.release(), device.key.data(), relay.c_str(), observer.c_str(),
        0, prefix.c_str(), link_relay_ready, link_cancelled, link_direct_report, link_video_report, link_bandwidth_report, link_media_epoch, nullptr);
    if (link_cancelled()) return finish(Stopped, "cancelled");
    if (status == 3) return finish(Unreachable, "relay_unreachable");
    return status == 0 ? finish(Stopped, "relay_ended") : finish(SetupFailed, "relay_transport_failed");
}

static napi_value start_ui_link(napi_env env, napi_callback_info info, bool companion)
{
    struct UiJob {
        napi_deferred deferred{}; napi_async_work async{}; std::string prefix, nonce, result;
        uint32_t limit{}; bool companion{};
        ~UiJob() {
            if (companion) {
                volatile char *secret = prefix.empty() ? nullptr : &prefix[0];
                for (size_t i=0; i<prefix.size(); ++i) secret[i]=0;
            }
        }
    };
    size_t argc = 3;
    napi_value args[3]{}, promise{}, label{};
    std::string files, nonce;
    auto job = std::make_unique<UiJob>();
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 3 ||
        !string_arg(env,args[0],files) || (!companion && files != "/data/storage/el2/base/files") ||
        !string_arg(env,args[1],nonce) || !valid_hex(nonce,24) ||
        napi_get_value_uint32(env,args[2],&job->limit) != napi_ok ||
        (companion ? !sesamePairedRate(job->limit) :
         (job->limit != 2000 && job->limit != 4000 && job->limit != 8000)) ||
        napi_create_promise(env,&job->deferred,&promise) != napi_ok) return nullptr;
    auto resolve = [&](const char *error) {
        napi_value value{};
        napi_create_string_utf8(env,error,NAPI_AUTO_LENGTH,&value);
        napi_resolve_deferred(env,job->deferred,value);
        return promise;
    };
    if (ui_link_busy.exchange(true)) return resolve("link_busy");
    ui_link_cancelled = false;
    delivered_video_packets = 0;
    requested_media_epoch = active_media_epoch = 0;
    {
        const std::lock_guard<std::mutex> lock(bandwidth_mtx);
        bandwidth_current = {};
    }
    ui_link = Direct;
    job->companion = companion;
    job->prefix = companion ? std::move(files) : files + "/.sesame-wan-" + nonce;
    job->nonce = nonce;
    napi_create_string_utf8(env,"sunshine_test_transport",NAPI_AUTO_LENGTH,&label);
    auto status = napi_create_async_work(env,nullptr,label,[](napi_env,void *value) {
        auto *work = static_cast<UiJob *>(value);
#ifdef SESAME_SUNSHINE_COMPANION
        if (work->companion) {
            work->result = companion_link(work->prefix,work->nonce,work->limit);
            return;
        }
#endif
        work->result = auto_link(work->prefix, work->limit);
    },[](napi_env env,napi_status,void *value) {
        std::unique_ptr<UiJob> work(static_cast<UiJob *>(value));
        ui_link_busy = false;
        napi_value result{};
        napi_create_string_utf8(env,work->result.c_str(),NAPI_AUTO_LENGTH,&result);
        napi_resolve_deferred(env,work->deferred,result);
        napi_delete_async_work(env,work->async);
    },job.get(),&job->async);
    if (status == napi_ok && napi_queue_async_work(env,job->async) == napi_ok) job.release();
    else {
        if (job->async) napi_delete_async_work(env,job->async);
        ui_link_busy = false;
        ui_link = SetupFailed;
        return resolve("link_worker_failed");
    }
    return promise;
}

static napi_value run_ui_link(napi_env env,napi_callback_info info) { return start_ui_link(env,info,false); }
static napi_value companion_available(napi_env env,napi_callback_info)
{
    napi_value value{};
#ifdef SESAME_SUNSHINE_COMPANION
    napi_get_boolean(env,true,&value);
#else
    napi_get_boolean(env,false,&value);
#endif
    return value;
}
static napi_value run_companion_link(napi_env env,napi_callback_info info)
{
#ifdef SESAME_SUNSHINE_COMPANION
    return start_ui_link(env,info,true);
#else
    return nullptr;
#endif
}
static napi_value new_companion_nonce(napi_env env,napi_callback_info)
{
    std::array<uint8_t,12> random{};
    std::array<char,24> chars{};
    napi_value value{};
    size_t len=0;
#ifdef SESAME_SUNSHINE_COMPANION
    if (getrandom(random.data(),random.size(),0)==static_cast<ssize_t>(random.size())) {
        constexpr char hex[]="0123456789abcdef";
        for (auto b:random) { chars[len++]=hex[b>>4]; chars[len++]=hex[b&15]; }
    }
#endif
    napi_create_string_utf8(env,chars.data(),len,&value);
    return value;
}
static napi_value pair_companion(napi_env env,napi_callback_info info)
{
#ifdef SESAME_SUNSHINE_COMPANION
    struct PairWork {
        napi_deferred deferred{}; napi_async_work async{}; std::string invitation,result;
        ~PairWork() {
            for (auto *s:{&invitation,&result}) {
                volatile char *p=s->empty()?nullptr:&(*s)[0];
                for (size_t i=0;i<s->size();++i) p[i]=0;
            }
        }
    };
    auto job=std::make_unique<PairWork>();
    napi_value arg{},promise{},name{};
    size_t argc=1;
    if (napi_get_cb_info(env,info,&argc,&arg,nullptr,nullptr)!=napi_ok || argc!=1 ||
        !string_arg(env,arg,job->invitation) || napi_create_promise(env,&job->deferred,&promise)!=napi_ok) return nullptr;
    napi_create_string_utf8(env,"sunshine_companion_pair",NAPI_AUTO_LENGTH,&name);
    if (napi_create_async_work(env,nullptr,name,[](napi_env,void *p) {
        auto *w=static_cast<PairWork *>(p);
        w->result=pairCompanionProfile(w->invitation);
    },[](napi_env env,napi_status,void *p) {
        std::unique_ptr<PairWork> w(static_cast<PairWork *>(p));
        napi_value value{};
        napi_create_string_utf8(env,w->result.c_str(),w->result.size(),&value);
        napi_resolve_deferred(env,w->deferred,value);
        napi_delete_async_work(env,w->async);
    },job.get(),&job->async)==napi_ok && napi_queue_async_work(env,job->async)==napi_ok) job.release();
    else {
        if (job->async) napi_delete_async_work(env,job->async);
        napi_value value{};
        napi_create_string_utf8(env,"companion_worker_failed",NAPI_AUTO_LENGTH,&value);
        napi_resolve_deferred(env,job->deferred,value);
    }
    return promise;
#else
    return nullptr;
#endif
}

static napi_value read_ui_link(napi_env env,napi_callback_info)
{
    napi_value n{};
    napi_create_int32(env,ui_link.load(),&n);
    return n;
}

#ifdef SESAME_SUNSHINE_COMPANION
static std::mutex input_mtx;
static std::shared_ptr<CompanionInput> current_input;
#endif

static napi_value input_open(napi_env env,napi_callback_info info)
{
    bool ready=false;
#ifdef SESAME_SUNSHINE_COMPANION
    std::string nonce;
    napi_value arg{};
    size_t count=1;
    if (napi_get_cb_info(env,info,&count,&arg,nullptr,nullptr)==napi_ok && count==1 &&
        string_arg(env,arg,nonce) && nonce.size()==24) {
        auto session=acquireCompanionSession(nonce);
        const std::lock_guard<std::mutex> lock(input_mtx);
        if (session && (!current_input || current_input->done()) &&
            std::any_of(session->grant.begin(),session->grant.end(),[](uint8_t n) { return n!=0; })) {
            auto input=std::make_shared<CompanionInput>(*session);
            current_input=input;
            try {
                std::thread([input]() { input->run(); }).detach();
                ready=true;
            } catch (...) {
                current_input.reset();
            }
        }
    }
#endif
    napi_value value{};
    napi_get_boolean(env,ready,&value);
    return value;
}

static napi_value input_state(napi_env env,napi_callback_info info)
{
    int state=0;
#ifdef SESAME_SUNSHINE_COMPANION
    std::string nonce;
    napi_value arg{};
    size_t count=1;
    if (napi_get_cb_info(env,info,&count,&arg,nullptr,nullptr)==napi_ok && count==1 && string_arg(env,arg,nonce)) {
        const std::lock_guard<std::mutex> lock(input_mtx);
        if (current_input && current_input->matches(nonce)) state=current_input->status();
    }
#endif
    napi_value value{};
    napi_create_int32(env,state,&value);
    return value;
}

static napi_value input_send(napi_env env,napi_callback_info info)
{
    bool queued=false;
#ifdef SESAME_SUNSHINE_COMPANION
    std::string nonce,text;
    std::array<napi_value,6> args{};
    size_t count=args.size();
    int32_t kind=0,flag=0,a=0,b=0;
    if (napi_get_cb_info(env,info,&count,args.data(),nullptr,nullptr)==napi_ok && count==args.size() &&
        string_arg(env,args[0],nonce) && string_arg(env,args[5],text) &&
        napi_get_value_int32(env,args[1],&kind)==napi_ok && napi_get_value_int32(env,args[2],&flag)==napi_ok &&
        napi_get_value_int32(env,args[3],&a)==napi_ok && napi_get_value_int32(env,args[4],&b)==napi_ok) {
        const std::lock_guard<std::mutex> lock(input_mtx);
        if (current_input && current_input->matches(nonce))
            queued=current_input->push(kind,flag,a,b,text);
    }
    if (!text.empty()) OPENSSL_cleanse(text.data(),text.size());
#endif
    napi_value value{};
    napi_get_boolean(env,queued,&value);
    return value;
}

static napi_value input_close(napi_env env,napi_callback_info)
{
#ifdef SESAME_SUNSHINE_COMPANION
    const std::lock_guard<std::mutex> lock(input_mtx);
    if (current_input) current_input->close();
#endif
    napi_value value{};
    napi_get_undefined(env,&value);
    return value;
}

static napi_value cancel_ui_link(napi_env env,napi_callback_info)
{
    if (ui_link_busy.load()) ui_link_cancelled = true;
    return input_close(env,nullptr);
}

static napi_value init(napi_env env, napi_value exports)
{
    napi_property_descriptor fields[] = {
        {"runSecureClient", nullptr, sesameRunSecureClient, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runUiLink", nullptr, run_ui_link, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readUiLink", nullptr, read_ui_link, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelUiLink", nullptr, cancel_ui_link, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"secureSnapshot", nullptr, sesameSecureSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"secureVideoRatio", nullptr, sesameSecureVideoRatio, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"displayCatalog", nullptr, sesameDisplays, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selectDisplay", nullptr, sesameSelectDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelSecureClient", nullptr, sesameCancelSecureClient, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"companionAvailable", nullptr, companion_available, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pairCompanion", nullptr, pair_companion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"newCompanionNonce", nullptr, new_companion_nonce, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runCompanionLink", nullptr, run_companion_link, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inputOpen", nullptr, input_open, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inputState", nullptr, input_state, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inputSend", nullptr, input_send, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inputClose", nullptr, input_close, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(fields) / sizeof(fields[0]), fields);
    return exports;
}

static napi_module module{1,0,nullptr,init,"sunshine_stream_exp",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterSunshineExperiment() { napi_module_register(&module); }
