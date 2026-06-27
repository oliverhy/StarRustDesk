#include "napi/native_api.h"
#include "core/rustdesk_ffi.h"
#include "core/config.h"
#include "core/video_render.h"
#include "core/xcomponent_render.h"
#include "core/file_transfer.h"
#include "core/connection.h"
#include "core/service.h"
#include "core/audio_player.h"
#include <cstring>
#include <cstdio>
#include <string>
#include <fstream>
#include <sstream>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <atomic>
#include <cstdint>
#include <thread>
#include <mutex>
#include <vector>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskNapi"

// ===== Connection Management =====

static std::atomic<int> g_connectionStatus{0};
static std::atomic<int> g_lastConnectionResult{0};
static std::atomic<uint64_t> g_connectionGeneration{0};
static std::atomic<uint64_t> g_videoFrameCount{0};
static std::atomic<uint64_t> g_videoByteCount{0};
static std::mutex g_lastConnectionMessageMutex;
static std::string g_lastConnectionMessage;

static void SetLastConnectionMessage(const std::string& message) {
    std::lock_guard<std::mutex> lock(g_lastConnectionMessageMutex);
    g_lastConnectionMessage = message;
}

static std::string GetLastConnectionMessage() {
    std::lock_guard<std::mutex> lock(g_lastConnectionMessageMutex);
    return g_lastConnectionMessage;
}

static void OnRustVideoFrame(const unsigned char* data, int length, int width, int height) {
    if (data == nullptr || length <= 0) {
        return;
    }
    g_videoFrameCount.fetch_add(1);
    g_videoByteCount.fetch_add(static_cast<uint64_t>(length));
    VideoRender::instance().onFrameReceived(data, length, width, height);
}

static void OnRustEvent(const char* message) {
    if (message == nullptr) {
        return;
    }
    OH_LOG_INFO(LOG_APP, "rust_event: %{public}s", message);
    const std::string text(message);
    const std::string loginErrorPrefix = "login response: error=";
    if (text.rfind(loginErrorPrefix, 0) == 0) {
        SetLastConnectionMessage(text.substr(loginErrorPrefix.length()));
        g_lastConnectionResult.store(-17);
        g_connectionStatus.store(3);
    } else if (text.rfind("connection lost:", 0) == 0) {
        SetLastConnectionMessage("Peer connection closed");
        g_lastConnectionResult.store(-18);
        g_connectionStatus.store(3);
    } else if (text == "receive loop ended" && g_connectionStatus.load() == 2) {
        SetLastConnectionMessage("Peer connection closed");
        g_lastConnectionResult.store(-18);
        g_connectionStatus.store(3);
    }
}

static int OnRustAudioStart(int sampleRate, int channels) {
    return audio_player_start(sampleRate, channels);
}

static void OnRustAudioStop() {
    audio_player_stop();
}

static void OnRustAudioFrame(const unsigned char* data, int length) {
    audio_player_push_opus_frame(data, length);
}

static std::string ConnectionResultToMessage(int result) {
    switch (result) {
        case 0: return "";
        case -1: return "Unable to connect to rendezvous server";
        case -2: return "Failed to send rendezvous request";
        case -3: return "Rendezvous response has no peer address";
        case -4: return "Rendezvous response has no peer or relay address";
        case -5: return "Unexpected rendezvous response";
        case -6: return "Failed to parse rendezvous response";
        case -7: return "Rendezvous server did not respond";
        case -8: return "Remote ID does not exist";
        case -9: return "Remote device is offline";
        case -10: return "Server key mismatch";
        case -11: return "Server license overuse";
        case -13: return "Rendezvous server rejected the request";
        case -14: return "Direct peer connection failed";
        case -15: return "Relay connection failed";
        case -16: return "Peer secure handshake failed";
        case -17: return "Remote login failed";
        case -18: return "Peer connection closed";
        case -19: return "Connection was replaced";
        default: return "Connection failed (" + std::to_string(result) + ")";
    }
}

static napi_value Connect(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char peerId[64] = {0}, password[64] = {0};
    char rendezvousServer[256] = {0}, relayServer[256] = {0};
    size_t peerIdLen = 0, passwordLen = 0, rendezvousLen = 0, relayLen = 0;

    napi_get_value_string_utf8(env, args[0], peerId, sizeof(peerId), &peerIdLen);
    napi_get_value_string_utf8(env, args[1], password, sizeof(password), &passwordLen);
    if (argc >= 3)
        napi_get_value_string_utf8(env, args[2], rendezvousServer, sizeof(rendezvousServer), &rendezvousLen);
    if (argc >= 4)
        napi_get_value_string_utf8(env, args[3], relayServer, sizeof(relayServer), &relayLen);

    std::string peer = peerIdLen > 0 ? peerId : "";
    std::string pass = passwordLen > 0 ? password : "";
    std::string rendezvous = rendezvousLen > 0 ? rendezvousServer : "";
    std::string relay = relayLen > 0 ? relayServer : "";
    std::string serverKey = Config::instance().get("key");

    if (peer.empty()) {
        napi_value ret;
        napi_create_int32(env, -1, &ret);
        return ret;
    }

    uint64_t generation = g_connectionGeneration.fetch_add(1) + 1;
    g_connectionStatus.store(1);
    g_lastConnectionResult.store(0);
    SetLastConnectionMessage("");
    VideoRender::instance().resetSession();
    OH_LOG_INFO(LOG_APP, "Starting rust_connect peer=%{public}s server=%{public}s key=%{public}s",
                peer.c_str(), rendezvous.c_str(), serverKey.empty() ? "empty" : "set");
    std::thread([peer, pass, rendezvous, relay, serverKey, generation]() {
        int result = rust_connect(peer.c_str(), pass.c_str(), rendezvous.c_str(), relay.c_str(), serverKey.c_str());
        OH_LOG_INFO(LOG_APP, "rust_connect finished result=%{public}d", result);
        if (g_connectionGeneration.load() != generation) {
            OH_LOG_INFO(LOG_APP, "Ignore stale rust_connect result generation=%{public}llu", static_cast<unsigned long long>(generation));
            return;
        }
        g_lastConnectionResult.store(result);
        g_connectionStatus.store(result == 0 ? 2 : 3);
    }).detach();

    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value SetPerformancePreset(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char preset[32] = {0};
    size_t presetLen = 0;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, args[0], preset, sizeof(preset), &presetLen);
    }

    int result = rust_set_performance_preset(presetLen > 0 ? preset : "smooth");
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value Disconnect(napi_env env, napi_callback_info info) {
    g_connectionGeneration.fetch_add(1);
    g_connectionStatus.store(0);
    std::thread([]() {
        rust_disconnect();
        VideoRender::instance().resetSession();
    }).detach();
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

// ===== Input Events =====

static napi_value SendKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t keyCode = 0, action = 0;
    napi_get_value_int32(env, args[0], &keyCode);
    napi_get_value_int32(env, args[1], &action);
    int result = rust_send_key_event(keyCode, action);
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendKeyEvent key=%{public}d action=%{public}d result=%{public}d", keyCode, action, result);
    }
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value SendPhysicalKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t scanCode = 0, action = 0;
    napi_get_value_int32(env, args[0], &scanCode);
    napi_get_value_int32(env, args[1], &action);
    int result = rust_send_physical_key_event(scanCode, action);
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendPhysicalKeyEvent scan=%{public}d action=%{public}d result=%{public}d", scanCode, action, result);
    }
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value SendText(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t textLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &textLen);
    std::vector<char> textBuffer(textLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], textBuffer.data(), textBuffer.size(), &textLen);
    std::string text(textBuffer.data(), textLen);

    int result = rust_send_text(text.c_str());
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendText len=%{public}zu result=%{public}d", textLen, result);
    }
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value SendMouseEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double x = 0, y = 0;
    int32_t action = 0;
    napi_get_value_double(env, args[0], &x);
    napi_get_value_double(env, args[1], &y);
    napi_get_value_int32(env, args[2], &action);
    int result = rust_send_mouse_event(x, y, action);
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendMouseEvent x=%{public}.1f y=%{public}.1f action=%{public}d result=%{public}d", x, y, action, result);
    }
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value GetDisplayCount(napi_env env, napi_callback_info info) {
    napi_value ret;
    napi_create_int32(env, rust_get_display_count(), &ret);
    return ret;
}

static napi_value GetCurrentDisplay(napi_env env, napi_callback_info info) {
    napi_value ret;
    napi_create_int32(env, rust_get_current_display(), &ret);
    return ret;
}

static napi_value SwitchDisplay(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t display = 0;
    napi_get_value_int32(env, args[0], &display);
    int result = rust_switch_display(display);
    OH_LOG_INFO(LOG_APP, "SwitchDisplay display=%{public}d result=%{public}d", display, result);
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value RefreshVideo(napi_env env, napi_callback_info info) {
    int result = rust_refresh_video();
    OH_LOG_INFO(LOG_APP, "RefreshVideo result=%{public}d", result);
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

// ===== Service Control =====

extern "C" int start_service_cpp();
extern "C" void stop_service_cpp();

static napi_value StartService(napi_env env, napi_callback_info info) {
    extern int start_service_cpp();
    int result = start_service_cpp();
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value StopService(napi_env env, napi_callback_info info) {
    extern void stop_service_cpp();
    stop_service_cpp();
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value GetActiveSessions(napi_env env, napi_callback_info info) {
    auto sessions = Service::instance().getActiveSessions();
    napi_value arr;
    napi_create_array(env, &arr);
    uint32_t idx = 0;
    for (const auto& s : sessions) {
        napi_value obj;
        napi_create_object(env, &obj);
        napi_value peerIdVal;
        napi_create_string_utf8(env, s.peerId.c_str(), NAPI_AUTO_LENGTH, &peerIdVal);
        napi_set_named_property(env, obj, "peerId", peerIdVal);
        napi_value addrVal;
        napi_create_string_utf8(env, s.clientAddr.c_str(), NAPI_AUTO_LENGTH, &addrVal);
        napi_set_named_property(env, obj, "clientAddr", addrVal);
        napi_value timeVal;
        napi_create_int64(env, (int64_t)s.connectedAt, &timeVal);
        napi_set_named_property(env, obj, "connectedAt", timeVal);
        napi_set_element(env, arr, idx++, obj);
    }
    return arr;
}

// ===== Device Info =====

static napi_value GetDeviceId(napi_env env, napi_callback_info info) {
    std::string id = Service::instance().getDeviceId();
    napi_value ret;
    napi_create_string_utf8(env, id.c_str(), id.length(), &ret);
    return ret;
}

static napi_value GetDeviceName(napi_env env, napi_callback_info info) {
    char hostname[256] = {0};
    if (gethostname(hostname, sizeof(hostname)) != 0) {
        strcpy(hostname, "HarmonyOS Device");
    }
    napi_value ret;
    napi_create_string_utf8(env, hostname, NAPI_AUTO_LENGTH, &ret);
    return ret;
}

// ===== Connection Status =====

static napi_value GetConnectionStatus(napi_env env, napi_callback_info info) {
    int status = g_connectionStatus.load();
    if (status == 2 && rust_get_connection_status() == 0) {
        status = 3;
        g_connectionStatus.store(status);
        if (GetLastConnectionMessage().empty()) {
            SetLastConnectionMessage("Peer connection closed");
            g_lastConnectionResult.store(-18);
        }
    }
    napi_value ret;
    napi_create_int32(env, status, &ret);
    return ret;
}

static napi_value GetConnectionRoute(napi_env env, napi_callback_info info) {
    napi_value ret;
    napi_create_int32(env, rust_get_connection_route(), &ret);
    return ret;
}

static napi_value GetLastConnectionError(napi_env env, napi_callback_info info) {
    std::string message = GetLastConnectionMessage();
    if (!message.empty()) {
        napi_value ret;
        napi_create_string_utf8(env, message.c_str(), message.length(), &ret);
        return ret;
    }
    int result = g_lastConnectionResult.load();
    message = ConnectionResultToMessage(result);
    napi_value ret;
    napi_create_string_utf8(env, message.c_str(), message.length(), &ret);
    return ret;
}

// ===== Peer List =====

extern "C" char* rust_get_peer_list() {
    // Stub: Rust static lib doesn't export this yet.
    // In a full build, the Rust side would query the rendezvous server.
    static char empty[] = "[]";
    return empty;
}

static napi_value GetPeerList(napi_env env, napi_callback_info info) {
    napi_value ret;
    napi_create_array(env, &ret);

    const char* peerListJson = rust_get_peer_list();
    if (peerListJson != nullptr && strlen(peerListJson) > 2) {
        napi_value jsonStr;
        napi_create_string_utf8(env, peerListJson, NAPI_AUTO_LENGTH, &jsonStr);
        napi_value global;
        napi_get_global(env, &global);
        napi_value jsonGlobal;
        napi_get_named_property(env, global, "JSON", &jsonGlobal);
        napi_value parseFn;
        napi_get_named_property(env, jsonGlobal, "parse", &parseFn);
        napi_value parsed;
        napi_call_function(env, jsonGlobal, parseFn, 1, &jsonStr, &parsed);
        ret = parsed;
    }

    return ret;
}

// ===== File Transfer =====

static napi_value SendFile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char localPath[1024] = {0}, remotePath[1024] = {0};
    size_t localLen = 0, remoteLen = 0;
    napi_get_value_string_utf8(env, args[0], localPath, sizeof(localPath), &localLen);
    napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), &remoteLen);

    FileTransfer::instance().setSocketFd(Connection::instance().getSocketFd());
    int result = FileTransfer::instance().sendFile(localPath, remotePath);
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value ReceiveFile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char remotePath[1024] = {0}, localPath[1024] = {0};
    size_t remoteLen = 0, localLen = 0;
    napi_get_value_string_utf8(env, args[0], remotePath, sizeof(remotePath), &remoteLen);
    napi_get_value_string_utf8(env, args[1], localPath, sizeof(localPath), &localLen);

    FileTransfer::instance().setSocketFd(Connection::instance().getSocketFd());
    int result = FileTransfer::instance().receiveFile(remotePath, localPath);
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value GetFileTransferProgress(napi_env env, napi_callback_info info) {
    FileTransferProgress p = FileTransfer::instance().getProgress();
    napi_value obj;
    napi_create_object(env, &obj);

    napi_value statusVal;
    napi_create_int32(env, (int)p.status, &statusVal);
    napi_set_named_property(env, obj, "status", statusVal);

    napi_value fileNameVal;
    napi_create_string_utf8(env, p.fileName.c_str(), p.fileName.length(), &fileNameVal);
    napi_set_named_property(env, obj, "fileName", fileNameVal);

    napi_value totalVal;
    napi_create_int64(env, p.totalBytes, &totalVal);
    napi_set_named_property(env, obj, "totalBytes", totalVal);

    napi_value transferredVal;
    napi_create_int64(env, p.transferredBytes, &transferredVal);
    napi_set_named_property(env, obj, "transferredBytes", transferredVal);

    napi_value progressVal;
    napi_create_double(env, p.progress, &progressVal);
    napi_set_named_property(env, obj, "progress", progressVal);

    return obj;
}

static napi_value CancelFileTransfer(napi_env env, napi_callback_info info) {
    FileTransfer::instance().cancel();
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

// ===== Clipboard (delegated to ArkTS pasteboard) =====

static napi_value GetClipboardText(napi_env env, napi_callback_info info) {
    napi_value ret;
    napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &ret);
    return ret;
}

static napi_value SetClipboardText(napi_env env, napi_callback_info info) {
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value SendClipboardText(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t textLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &textLen);
    std::vector<char> textBuffer(textLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], textBuffer.data(), textBuffer.size(), &textLen);
    std::string text(textBuffer.data(), textLen);

    int result = rust_send_clipboard_text(text.c_str());
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendClipboardText len=%{public}zu result=%{public}d", textLen, result);
    }
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value TakeRemoteClipboardText(napi_env env, napi_callback_info info) {
    char* text = rust_take_remote_clipboard_text();
    napi_value ret;
    if (text == nullptr) {
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &ret);
        return ret;
    }
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &ret);
    rust_free_string(text);
    return ret;
}

// ===== Options (Config Persistence) =====

static napi_value SetOption(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t keyLen = 0, valueLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &keyLen);
    napi_get_value_string_utf8(env, args[1], nullptr, 0, &valueLen);
    std::vector<char> keyBuffer(keyLen + 1, '\0');
    std::vector<char> valueBuffer(valueLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], keyBuffer.data(), keyBuffer.size(), &keyLen);
    napi_get_value_string_utf8(env, args[1], valueBuffer.data(), valueBuffer.size(), &valueLen);
    std::string key(keyBuffer.data(), keyLen);
    std::string value(valueBuffer.data(), valueLen);
    Config::instance().set(key, value);
    Config::instance().save();
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value GetOption(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char key[128] = {0};
    size_t keyLen = 0;
    napi_get_value_string_utf8(env, args[0], key, sizeof(key), &keyLen);
    std::string value = Config::instance().get(key);
    napi_value ret;
    napi_create_string_utf8(env, value.c_str(), value.length(), &ret);
    return ret;
}

static std::string EscapeJsonString(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (char ch : value) {
        switch (ch) {
            case '\\': escaped += "\\\\"; break;
            case '"': escaped += "\\\""; break;
            case '\b': escaped += "\\b"; break;
            case '\f': escaped += "\\f"; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default:
                if (static_cast<unsigned char>(ch) < 0x20) {
                    char buf[7] = {0};
                    snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(ch));
                    escaped += buf;
                } else {
                    escaped += ch;
                }
                break;
        }
    }
    return escaped;
}

static napi_value GetAllOptions(napi_env env, napi_callback_info info) {
    auto all = Config::instance().getAll();
    std::string json = "{";
    bool first = true;
    for (const auto& pair : all) {
        if (!first) json += ",";
        first = false;
        json += "\"" + EscapeJsonString(pair.first) + "\":\"" + EscapeJsonString(pair.second) + "\"";
    }
    json += "}";
    napi_value ret;
    napi_create_string_utf8(env, json.c_str(), json.length(), &ret);
    return ret;
}

static napi_value TestIfValidServer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char server[256] = {0};
    size_t serverLen = 0;
    napi_get_value_string_utf8(env, args[0], server, sizeof(server), &serverLen);
    std::string result;
    if (serverLen == 0) { napi_value ret; napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &ret); return ret; }

    std::string hostname(server);
    int port = 21116;
    size_t colonPos = hostname.find(':');
    if (colonPos != std::string::npos) {
        port = std::stoi(hostname.substr(colonPos + 1));
        hostname = hostname.substr(0, colonPos);
    }

    struct hostent* host = gethostbyname(hostname.c_str());
    if (!host) { result = "DNS解析失败"; napi_value ret; napi_create_string_utf8(env, result.c_str(), result.length(), &ret); return ret; }

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) { result = "创建socket失败"; napi_value ret; napi_create_string_utf8(env, result.c_str(), result.length(), &ret); return ret; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    memcpy(&addr.sin_addr, host->h_addr, host->h_length);

    // Non-blocking connect with 5s timeout
    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    int connectRet = ::connect(sock, (struct sockaddr*)&addr, sizeof(addr));
    bool connected = false;

    if (connectRet == 0) {
        connected = true;
    } else if (connectRet < 0 && errno == EINPROGRESS) {
        fd_set fdset;
        FD_ZERO(&fdset);
        FD_SET(sock, &fdset);
        struct timeval tv;
        tv.tv_sec = 5;
        tv.tv_usec = 0;
        int selRet = select(sock + 1, nullptr, &fdset, nullptr, &tv);
        if (selRet > 0) {
            int soError = 0;
            socklen_t soLen = sizeof(soError);
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen);
            if (soError == 0) {
                // TCP connected - now verify with send+recv
                // Send a byte to trigger server response
                fcntl(sock, F_SETFL, flags); // back to blocking
                struct timeval respTv;
                respTv.tv_sec = 3;
                respTv.tv_usec = 0;
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &respTv, sizeof(respTv));

                char probe = 0x00;
                send(sock, &probe, 1, 0);

                // Try to recv - real server will respond or close
                char respBuf[8];
                int recvd = recv(sock, respBuf, sizeof(respBuf), 0);
                if (recvd > 0) {
                    connected = true; // Got real data back
                } else if (recvd == 0) {
                    connected = true; // Clean close = real server
                } else {
                    // errno == EAGAIN means timeout - likely fake connection
                    result = "服务器无响应";
                }
            } else {
                result = "连接被拒绝 (" + std::string(strerror(soError)) + ")";
            }
        } else if (selRet == 0) {
            result = "连接超时 (5秒)";
        } else {
            result = "select失败";
        }
    } else {
        result = "连接被拒绝 (" + std::string(strerror(errno)) + ")";
    }

    if (connected) result = "";

    fcntl(sock, F_SETFL, flags);
    close(sock);
    napi_value ret;
    napi_create_string_utf8(env, result.c_str(), result.length(), &ret);
    return ret;
}

static napi_value IsUsingPublicServer(napi_env env, napi_callback_info info) {
    std::string idServer = Config::instance().get("custom-rendezvous-server");
    napi_value ret;
    napi_get_boolean(env, idServer.empty(), &ret);
    return ret;
}

// ===== Video Rendering =====

static napi_value GetVideoFrame(napi_env env, napi_callback_info info) {
    uint8_t* data = nullptr;
    int length = 0, width = 0, height = 0;
    bool hasFrame = VideoRender::instance().getLatestFrame(data, length, width, height);
    napi_value obj;
    napi_create_object(env, &obj);
    napi_value hasFrameVal; napi_get_boolean(env, hasFrame, &hasFrameVal); napi_set_named_property(env, obj, "hasFrame", hasFrameVal);
    napi_value widthVal; napi_create_int32(env, width, &widthVal); napi_set_named_property(env, obj, "width", widthVal);
    napi_value heightVal; napi_create_int32(env, height, &heightVal); napi_set_named_property(env, obj, "height", heightVal);
    napi_value lengthVal; napi_create_int32(env, length, &lengthVal); napi_set_named_property(env, obj, "length", lengthVal);
    napi_value frameCountVal; napi_create_int64(env, static_cast<int64_t>(g_videoFrameCount.load()), &frameCountVal); napi_set_named_property(env, obj, "totalFrames", frameCountVal);
    napi_value byteCountVal; napi_create_int64(env, static_cast<int64_t>(g_videoByteCount.load()), &byteCountVal); napi_set_named_property(env, obj, "totalBytes", byteCountVal);
    return obj;
}

// ===== XComponent Surface =====

static napi_value SetSurfaceId(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char surfaceId[128] = {0};
    size_t surfaceIdLen = 0;
    napi_get_value_string_utf8(env, args[0], surfaceId, sizeof(surfaceId), &surfaceIdLen);

    std::string surface(surfaceId, surfaceIdLen);
    if (surface.empty()) {
        std::thread([]() {
            VideoRender::instance().setSurfaceId("");
        }).detach();
    } else {
        VideoRender::instance().setSurfaceId(surface);
    }

    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

// ===== Module Registration =====

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    Config::instance().load();
    rust_set_frame_callback(OnRustVideoFrame);
    rust_set_event_callback(OnRustEvent);
    rust_set_audio_callbacks(OnRustAudioStart, OnRustAudioStop, OnRustAudioFrame);

    napi_property_descriptor desc[] = {
        {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPerformancePreset", nullptr, SetPerformancePreset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disconnect", nullptr, Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendKeyEvent", nullptr, SendKeyEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendPhysicalKeyEvent", nullptr, SendPhysicalKeyEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendText", nullptr, SendText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseEvent", nullptr, SendMouseEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDisplayCount", nullptr, GetDisplayCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCurrentDisplay", nullptr, GetCurrentDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"switchDisplay", nullptr, SwitchDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"refreshVideo", nullptr, RefreshVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startService", nullptr, StartService, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopService", nullptr, StopService, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getActiveSessions", nullptr, GetActiveSessions, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPeerList", nullptr, GetPeerList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConnectionStatus", nullptr, GetConnectionStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConnectionRoute", nullptr, GetConnectionRoute, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLastConnectionError", nullptr, GetLastConnectionError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDeviceId", nullptr, GetDeviceId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDeviceName", nullptr, GetDeviceName, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendFile", nullptr, SendFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"receiveFile", nullptr, ReceiveFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getFileTransferProgress", nullptr, GetFileTransferProgress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelFileTransfer", nullptr, CancelFileTransfer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getClipboardText", nullptr, GetClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setClipboardText", nullptr, SetClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendClipboardText", nullptr, SendClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeRemoteClipboardText", nullptr, TakeRemoteClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setOption", nullptr, SetOption, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getOption", nullptr, GetOption, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAllOptions", nullptr, GetAllOptions, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testIfValidServer", nullptr, TestIfValidServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isUsingPublicServer", nullptr, IsUsingPublicServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVideoFrame", nullptr, GetVideoFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSurfaceId", nullptr, SetSurfaceId, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module rustdeskModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterRustDeskModule(void) {
    napi_module_register(&rustdeskModule);
}
