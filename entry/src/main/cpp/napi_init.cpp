#include "napi/native_api.h"
#include "core/rustdesk_ffi.h"
#include "core/config.h"
#include "core/diagnostic_log.h"
#include "crypto/aead.h"
#include "core/video_render.h"
#include "core/xcomponent_render.h"
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
#include <condition_variable>
#include <vector>
#include <deque>
#include <chrono>
#include <algorithm>
#include <cstdlib>
#include <dlfcn.h>
#include <hilog/log.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <multimodalinput/oh_input_manager.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskNapi"

// ===== Connection Management =====

static std::atomic<int> g_connectionStatus{0};
static std::atomic<int> g_lastConnectionResult{0};
static std::atomic<uint64_t> g_connectionGeneration{0};
static std::atomic<int64_t> g_connectionStartedAtMs{0};
static std::atomic<bool> g_disconnectInProgress{false};
static std::atomic<bool> g_enableTrustedDevices{false};
static std::atomic<uint64_t> g_videoFrameCount{0};
static std::atomic<uint64_t> g_videoByteCount{0};
static std::atomic<uint64_t> g_frameCallbackEnteredGeneration{0};
static std::atomic<uint64_t> g_frameCallbackCompletedGeneration{0};
static std::atomic<int64_t> g_lastVideoHealthLogMs{0};
static std::atomic<uint64_t> g_lastVideoHealthFrameCount{0};
static std::atomic<uint64_t> g_lastVideoHealthDecodedCount{0};
static std::mutex g_lastConnectionMessageMutex;
static std::string g_lastConnectionMessage;
static std::mutex g_connectionLifecycleMutex;
static std::condition_variable g_disconnectFinished;

struct NativeMouseInputEvent {
    float x{0.0F};
    float y{0.0F};
    int32_t action{0};
    int32_t button{0};
    int32_t hover{-1};
    int64_t timestamp{0};
    int32_t modifierMask{0};
    bool modifierValid{false};
};

struct NativeKeyInputEvent {
    int32_t keyCode{-1};
    int32_t action{-1};
    int64_t timestamp{0};
    int32_t modifierMask{0};
    bool modifierValid{false};
    bool capsLockOn{false};
    bool capsLockValid{false};
};

static std::mutex g_nativeMouseInputMutex;
static std::deque<NativeMouseInputEvent> g_nativeMouseInputEvents;
static OH_NativeXComponent* g_registeredMouseXComponent = nullptr;
static std::mutex g_nativeKeyInputMutex;
static std::deque<NativeKeyInputEvent> g_nativeKeyInputEvents;
static OH_NativeXComponent* g_registeredKeyXComponent = nullptr;

using GetExtraMouseEventInfoFn = int32_t (*)(
    OH_NativeXComponent*, OH_NativeXComponent_ExtraMouseEventInfo**);
using GetMouseModifierKeyStatesFn = int32_t (*)(
    OH_NativeXComponent_ExtraMouseEventInfo*, uint64_t*);
using GetKeyModifierKeyStatesFn = int32_t (*)(OH_NativeXComponent_KeyEvent*, uint64_t*);
using GetKeyCapsLockStateFn = int32_t (*)(OH_NativeXComponent_KeyEvent*, bool*);

struct HardwareKeyState {
    bool valid{false};
    int32_t modifierMask{0};
    bool capsLockOn{false};
    bool capsLockValid{false};
    int32_t querySuccessCount{0};
};

static bool QueryHardwareKeyState(int32_t keyCode, int32_t& pressed, int32_t& keySwitch) {
    Input_KeyState* state = OH_Input_CreateKeyState();
    if (state == nullptr) {
        return false;
    }
    OH_Input_SetKeyCode(state, keyCode);
    const Input_Result result = OH_Input_GetKeyState(state);
    if (result == INPUT_SUCCESS) {
        pressed = OH_Input_GetKeyPressed(state);
        keySwitch = OH_Input_GetKeySwitch(state);
    }
    OH_Input_DestroyKeyState(&state);
    return result == INPUT_SUCCESS;
}

static HardwareKeyState GetHardwareKeyState() {
    HardwareKeyState state;
    int32_t pressed = KEY_DEFAULT;
    int32_t keySwitch = KEY_DEFAULT;
    bool anyValid = false;
    if (QueryHardwareKeyState(KEYCODE_CTRL_LEFT, pressed, keySwitch) && pressed == KEY_PRESSED) {
        state.modifierMask |= 1;
    }
    state.querySuccessCount += pressed != KEY_DEFAULT ? 1 : 0;
    anyValid = anyValid || pressed != KEY_DEFAULT;
    pressed = KEY_DEFAULT;
    keySwitch = KEY_DEFAULT;
    if (QueryHardwareKeyState(KEYCODE_CTRL_RIGHT, pressed, keySwitch) && pressed == KEY_PRESSED) {
        state.modifierMask |= 1;
    }
    state.querySuccessCount += pressed != KEY_DEFAULT ? 1 : 0;
    anyValid = anyValid || pressed != KEY_DEFAULT;
    pressed = KEY_DEFAULT;
    keySwitch = KEY_DEFAULT;
    if (QueryHardwareKeyState(KEYCODE_SHIFT_LEFT, pressed, keySwitch) && pressed == KEY_PRESSED) {
        state.modifierMask |= 2;
    }
    state.querySuccessCount += pressed != KEY_DEFAULT ? 1 : 0;
    anyValid = anyValid || pressed != KEY_DEFAULT;
    pressed = KEY_DEFAULT;
    keySwitch = KEY_DEFAULT;
    if (QueryHardwareKeyState(KEYCODE_SHIFT_RIGHT, pressed, keySwitch) && pressed == KEY_PRESSED) {
        state.modifierMask |= 2;
    }
    state.querySuccessCount += pressed != KEY_DEFAULT ? 1 : 0;
    anyValid = anyValid || pressed != KEY_DEFAULT;
    pressed = KEY_DEFAULT;
    keySwitch = KEY_DEFAULT;
    if (QueryHardwareKeyState(KEYCODE_ALT_LEFT, pressed, keySwitch) && pressed == KEY_PRESSED) {
        state.modifierMask |= 4;
    }
    state.querySuccessCount += pressed != KEY_DEFAULT ? 1 : 0;
    anyValid = anyValid || pressed != KEY_DEFAULT;
    pressed = KEY_DEFAULT;
    keySwitch = KEY_DEFAULT;
    if (QueryHardwareKeyState(KEYCODE_ALT_RIGHT, pressed, keySwitch) && pressed == KEY_PRESSED) {
        state.modifierMask |= 4;
    }
    state.querySuccessCount += pressed != KEY_DEFAULT ? 1 : 0;
    anyValid = anyValid || pressed != KEY_DEFAULT;
    pressed = KEY_DEFAULT;
    keySwitch = KEY_DEFAULT;
    if (QueryHardwareKeyState(KEYCODE_CAPS_LOCK, pressed, keySwitch)) {
        state.capsLockValid = keySwitch == KEY_SWITCH_ON || keySwitch == KEY_SWITCH_OFF;
        state.capsLockOn = keySwitch == KEY_SWITCH_ON;
        anyValid = true;
    }
    state.querySuccessCount += pressed != KEY_DEFAULT ? 1 : 0;
    state.valid = anyValid;
    const int32_t signature = (state.querySuccessCount << 8) |
        (state.capsLockValid ? 1 << 7 : 0) | (state.capsLockOn ? 1 << 6 : 0) |
        (state.modifierMask & 0x0F);
    static std::atomic<int32_t> lastSignature{-1};
    if (lastSignature.exchange(signature) != signature) {
        OH_LOG_INFO(LOG_APP,
            "InputTrace hardware queries=%{public}d valid=%{public}d mask=%{public}d capsValid=%{public}d caps=%{public}d",
            state.querySuccessCount, state.valid ? 1 : 0, state.modifierMask,
            state.capsLockValid ? 1 : 0, state.capsLockOn ? 1 : 0);
    }
    return state;
}

static int32_t ToInputModifierMask(uint64_t keys) {
    int32_t mask = 0;
    if ((keys & ARKUI_MODIFIER_KEY_CTRL) != 0) {
        mask |= 1;
    }
    if ((keys & ARKUI_MODIFIER_KEY_SHIFT) != 0) {
        mask |= 2;
    }
    if ((keys & ARKUI_MODIFIER_KEY_ALT) != 0) {
        mask |= 4;
    }
    return mask;
}

static bool TryGetNativeMouseModifiers(OH_NativeXComponent* component, int32_t& modifierMask) {
    static auto getExtraInfo = reinterpret_cast<GetExtraMouseEventInfoFn>(
        dlsym(RTLD_DEFAULT, "OH_NativeXComponent_GetExtraMouseEventInfo"));
    static auto getModifierStates = reinterpret_cast<GetMouseModifierKeyStatesFn>(
        dlsym(RTLD_DEFAULT, "OH_NativeXComponent_GetMouseEventModifierKeyStates"));
    if (getExtraInfo == nullptr || getModifierStates == nullptr) {
        return false;
    }
    OH_NativeXComponent_ExtraMouseEventInfo* extraInfo = nullptr;
    uint64_t keys = 0;
    if (getExtraInfo(component, &extraInfo) != 0 || extraInfo == nullptr ||
        getModifierStates(extraInfo, &keys) != 0) {
        return false;
    }
    modifierMask = ToInputModifierMask(keys);
    return true;
}

static bool TryGetNativeKeyModifiers(OH_NativeXComponent_KeyEvent* event, int32_t& modifierMask) {
    static auto getModifierStates = reinterpret_cast<GetKeyModifierKeyStatesFn>(
        dlsym(RTLD_DEFAULT, "OH_NativeXComponent_GetKeyEventModifierKeyStates"));
    if (getModifierStates == nullptr) {
        return false;
    }
    uint64_t keys = 0;
    if (getModifierStates(event, &keys) != 0) {
        return false;
    }
    modifierMask = ToInputModifierMask(keys);
    return true;
}

static bool TryGetNativeCapsLockState(OH_NativeXComponent_KeyEvent* event, bool& capsLockOn) {
    static auto getCapsLockState = reinterpret_cast<GetKeyCapsLockStateFn>(
        dlsym(RTLD_DEFAULT, "OH_NativeXComponent_GetKeyEventCapsLockState"));
    return getCapsLockState != nullptr && getCapsLockState(event, &capsLockOn) == 0;
}

static void QueueNativeMouseInput(const NativeMouseInputEvent& input) {
    std::lock_guard<std::mutex> lock(g_nativeMouseInputMutex);
    if (input.hover < 0 && input.action == OH_NATIVEXCOMPONENT_MOUSE_MOVE &&
        !g_nativeMouseInputEvents.empty()) {
        NativeMouseInputEvent& last = g_nativeMouseInputEvents.back();
        if (last.hover < 0 && last.action == OH_NATIVEXCOMPONENT_MOUSE_MOVE) {
            last = input;
            return;
        }
    }
    if (g_nativeMouseInputEvents.size() >= 256) {
        g_nativeMouseInputEvents.pop_front();
    }
    g_nativeMouseInputEvents.push_back(input);
}

static void DispatchNativeMouseEvent(OH_NativeXComponent* component, void* window) {
    OH_NativeXComponent_MouseEvent event{};
    const int32_t result = OH_NativeXComponent_GetMouseEvent(component, window, &event);
    if (result != OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        return;
    }
    int32_t modifierMask = 0;
    bool modifierValid = TryGetNativeMouseModifiers(component, modifierMask);
    if (!modifierValid) {
        const HardwareKeyState hardwareState = GetHardwareKeyState();
        modifierMask = hardwareState.modifierMask;
        // A non-zero fallback is useful evidence. An empty fallback is not
        // authoritative on all HarmonyOS PC builds and must not clear a real
        // modifier snapshot captured by ArkUI.
        modifierValid = hardwareState.valid && hardwareState.modifierMask != 0;
    }
    QueueNativeMouseInput({event.x, event.y, static_cast<int32_t>(event.action),
        static_cast<int32_t>(event.button), -1, event.timestamp, modifierMask, modifierValid});
    if (event.action != OH_NATIVEXCOMPONENT_MOUSE_MOVE) {
        DiagnosticLog::instance().append("I", "input-native",
            "mouse action=" + std::to_string(static_cast<int32_t>(event.action)) +
            " button=" + std::to_string(static_cast<int32_t>(event.button)) +
            " x=" + std::to_string(event.x) + " y=" + std::to_string(event.y) +
            " modifiers=" + std::to_string(modifierMask) +
            " modifier_valid=" + std::to_string(modifierValid ? 1 : 0));
    }
}

static void DispatchNativeHoverEvent(OH_NativeXComponent*, bool isHover) {
    QueueNativeMouseInput({0.0F, 0.0F, 0, 0, isHover ? 1 : 0, 0, 0, false});
}

static OH_NativeXComponent_MouseEvent_Callback g_nativeMouseCallbacks = {
    .DispatchMouseEvent = DispatchNativeMouseEvent,
    .DispatchHoverEvent = DispatchNativeHoverEvent,
};

static void QueueNativeKeyInput(const NativeKeyInputEvent& input) {
    std::lock_guard<std::mutex> lock(g_nativeKeyInputMutex);
    if (g_nativeKeyInputEvents.size() >= 256) {
        g_nativeKeyInputEvents.pop_front();
    }
    g_nativeKeyInputEvents.push_back(input);
}

static void DispatchNativeKeyEvent(OH_NativeXComponent* component, void*) {
    OH_NativeXComponent_KeyEvent* event = nullptr;
    if (OH_NativeXComponent_GetKeyEvent(component, &event) != OH_NATIVEXCOMPONENT_RESULT_SUCCESS ||
        event == nullptr) {
        return;
    }
    OH_NativeXComponent_KeyAction action = OH_NATIVEXCOMPONENT_KEY_ACTION_UNKNOWN;
    OH_NativeXComponent_KeyCode code = KEY_UNKNOWN;
    int64_t timestamp = 0;
    if (OH_NativeXComponent_GetKeyEventAction(event, &action) != OH_NATIVEXCOMPONENT_RESULT_SUCCESS ||
        OH_NativeXComponent_GetKeyEventCode(event, &code) != OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        return;
    }
    OH_NativeXComponent_GetKeyEventTimestamp(event, &timestamp);
    int32_t modifierMask = 0;
    bool capsLockOn = false;
    bool modifierValid = TryGetNativeKeyModifiers(event, modifierMask);
    const HardwareKeyState hardwareState = GetHardwareKeyState();
    if (!modifierValid) {
        modifierMask = hardwareState.modifierMask;
        // Some HarmonyOS PC versions do not export the native key modifier
        // query API. A pressed hardware modifier is still authoritative; an
        // empty snapshot is not, because a few builds always report zero.
        modifierValid = hardwareState.valid && hardwareState.modifierMask != 0;
    } else if (hardwareState.modifierMask != 0) {
        // The native event snapshot can lag behind the physical Shift/Ctrl
        // state. Preserve any modifier confirmed by the hardware query for
        // the printable key that is being queued.
        modifierMask |= hardwareState.modifierMask;
    }
    const bool capsLockValid = TryGetNativeCapsLockState(event, capsLockOn);
    QueueNativeKeyInput({static_cast<int32_t>(code), static_cast<int32_t>(action), timestamp,
        modifierMask, modifierValid, capsLockOn, capsLockValid});
    if (code == KEY_CTRL_LEFT || code == KEY_CTRL_RIGHT || code == KEY_SHIFT_LEFT ||
        code == KEY_SHIFT_RIGHT || code == KEY_CAPS_LOCK) {
        OH_LOG_INFO(LOG_APP,
            "NativeKey code=%{public}d action=%{public}d modifiers=%{public}d valid=%{public}d caps=%{public}d",
            static_cast<int32_t>(code), static_cast<int32_t>(action), modifierMask,
            modifierValid ? 1 : 0, capsLockOn ? 1 : 0);
    }
    DiagnosticLog::instance().append("I", "input-native",
        "key code=" + std::to_string(static_cast<int32_t>(code)) +
        " action=" + std::to_string(static_cast<int32_t>(action)) +
        " modifiers=" + std::to_string(modifierMask) +
        " modifier_valid=" + std::to_string(modifierValid ? 1 : 0) +
        " caps=" + std::to_string(capsLockOn ? 1 : 0) +
        " caps_valid=" + std::to_string(capsLockValid ? 1 : 0));
}

static void TryRegisterNativeInput(napi_env env, napi_value exports) {
    bool hasNativeXComponent = false;
    if (napi_has_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &hasNativeXComponent) != napi_ok ||
        !hasNativeXComponent) {
        return;
    }
    napi_value nativeObject = nullptr;
    OH_NativeXComponent* component = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &nativeObject) != napi_ok ||
        nativeObject == nullptr ||
        napi_unwrap(env, nativeObject, reinterpret_cast<void**>(&component)) != napi_ok ||
        component == nullptr) {
        DiagnosticLog::instance().append("W", "input-native", "xcomponent_unwrap_failed");
        return;
    }
    if (component != g_registeredMouseXComponent) {
        const int32_t mouseResult = OH_NativeXComponent_RegisterMouseEventCallback(component, &g_nativeMouseCallbacks);
        if (mouseResult == OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
            g_registeredMouseXComponent = component;
        }
        DiagnosticLog::instance().append(mouseResult == OH_NATIVEXCOMPONENT_RESULT_SUCCESS ? "I" : "W",
            "input-native", "mouse_callback_registered result=" + std::to_string(mouseResult));
    }
    if (component != g_registeredKeyXComponent) {
        const int32_t keyResult = OH_NativeXComponent_RegisterKeyEventCallback(component, DispatchNativeKeyEvent);
        if (keyResult == OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
            g_registeredKeyXComponent = component;
        }
        OH_LOG_INFO(LOG_APP, "Native key callback registration result=%{public}d", keyResult);
        DiagnosticLog::instance().append(keyResult == OH_NATIVEXCOMPONENT_RESULT_SUCCESS ? "I" : "W",
            "input-native", "key_callback_registered result=" + std::to_string(keyResult));
    }
}

static void SetLastConnectionMessage(const std::string& message) {
    std::lock_guard<std::mutex> lock(g_lastConnectionMessageMutex);
    g_lastConnectionMessage = message;
}

static std::string GetLastConnectionMessage() {
    std::lock_guard<std::mutex> lock(g_lastConnectionMessageMutex);
    return g_lastConnectionMessage;
}

static int64_t NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

static std::string MaskPeerId(const std::string& peerId) {
    if (peerId.size() <= 4) {
        return "****";
    }
    return "****" + peerId.substr(peerId.size() - 4);
}

static std::string GetOrCreateClientHwid() {
    std::string hwid = Config::instance().get("trusted-device-hwid");
    if (!hwid.empty()) {
        return hwid;
    }

    uint8_t randomBytes[AEAD::KEY_SIZE] = {0};
    char encoded[AEAD::KEY_SIZE * 2 + 1] = {0};
    AEAD::generateKey(randomBytes);
    for (int i = 0; i < AEAD::KEY_SIZE; ++i) {
        std::snprintf(encoded + i * 2, 3, "%02x", randomBytes[i]);
    }
    hwid.assign(encoded);
    Config::instance().set("trusted-device-hwid", hwid);
    Config::instance().save();
    return hwid;
}

static std::string GetOrCreateClientId() {
    std::string clientId = Config::instance().get("client-id");
    if (!clientId.empty()) {
        return clientId;
    }

    uint8_t randomBytes[AEAD::KEY_SIZE] = {0};
    char encoded[17] = {0};
    AEAD::generateKey(randomBytes);
    for (int i = 0; i < 8; ++i) {
        std::snprintf(encoded + i * 2, 3, "%02x", randomBytes[i]);
    }
    clientId = std::string("harmony-") + encoded;
    Config::instance().set("client-id", clientId);
    Config::instance().save();
    return clientId;
}

static void OnRustVideoFrame(const unsigned char* data, int length, int width, int height,
                             int isKey, int64_t pts) {
    if (data == nullptr || length <= 0) {
        return;
    }
    g_videoFrameCount.fetch_add(1);
    g_videoByteCount.fetch_add(static_cast<uint64_t>(length));
    uint64_t generation = g_connectionGeneration.load();
    if (g_frameCallbackEnteredGeneration.exchange(generation) != generation) {
        OH_LOG_INFO(LOG_APP, "First video frame entered generation=%{public}llu size=%{public}d",
                    static_cast<unsigned long long>(generation), length);
        char codec = length > 5 && data[0] == 'S' && data[1] == 'R' && data[2] == 'D' && data[3] == '0'
            ? static_cast<char>(data[4]) : '?';
        DiagnosticLog::instance().append("I", "video",
            "first_input generation=" + std::to_string(generation) +
            " codec=" + std::string(1, codec) +
            " size=" + std::to_string(length) +
            " resolution=" + std::to_string(width) + "x" + std::to_string(height) +
            " key=" + std::to_string(isKey) + " pts=" + std::to_string(pts));
    }
    VideoRender::instance().onFrameReceived(data, length, width, height, isKey != 0, pts);
    if (g_frameCallbackCompletedGeneration.exchange(generation) != generation) {
        OH_LOG_INFO(LOG_APP, "First video frame completed generation=%{public}llu",
                    static_cast<unsigned long long>(generation));
        DiagnosticLog::instance().append("I", "video",
            "first_input_forwarded generation=" + std::to_string(generation));
    }
}

static bool IsSafeRustLifecycleEvent(const std::string& text) {
    const char* prefixes[] = {
        "file-session:",
        "rust_connect entered",
        "previous connection cleared",
        "rendezvous tcp connected",
        "rendezvous tcp failed:",
        "punch request sent",
        "punch request send failed",
        "rendezvous response received",
        "rendezvous response timeout",
        "direct peer connected",
        "direct peer failed:",
        "relay connected",
        "relay failed:",
        "relay response connect failed:",
        "relay response missing",
        "no direct addr",
        "secure fallback failed",
        "secure fallback completed",
        "secure peer: encrypted stream enabled",
        "secure peer: unavailable; use non-secure connection",
        "secure peer: wait signed id timeout",
        "secure peer: first peer msg not SignedId; use non-secure connection",
        "receive loop spawned",
        "peer message:",
        "login request sent",
        "login response: ok/",
        "login response: 2fa-",
        "performance options sent",
        "refresh video sent",
        "initial video received ack",
        "switch display received",
        "audio format received",
        "close reason sent",
        "close wait:",
        "close request:",
        "close reason send failed",
        "peer command channel closed",
        "peer task abort:",
        "receive loop peer eof",
        "receive loop error:",
        "stale receive loop ended",
        "receive loop ended",
        "skip stale peer command",
        "video frame:",
        "video fallback:",
        "remote cursor visibility updated:",
        "connection lost:",
        "login request send failed:",
        "performance options send failed:",
        "refresh video send failed:",
        "initial video received ack failed:",
        "peer message parse failed"
    };
    for (const char* prefix : prefixes) {
        if (text.rfind(prefix, 0) == 0) {
            return true;
        }
    }
    return false;
}

static void OnRustEvent(const char* message) {
    if (message == nullptr) {
        return;
    }
    const std::string text(message);
    if (IsSafeRustLifecycleEvent(text) || text.rfind("input-trace:", 0) == 0) {
        OH_LOG_INFO(LOG_APP, "rust_event: %{public}s", message);
        if (text != "peer message: CursorData" && text != "peer message: CursorId" &&
            text != "peer message: Misc") {
            DiagnosticLog::instance().append("I", "rust", text);
        }
    } else {
        OH_LOG_DEBUG(LOG_APP, "rust_event: %{private}s", message);
    }
    const std::string twoFactorPrefix = "login response: 2fa-required enable_trusted_devices=";
    const std::string loginErrorPrefix = "login response: error=";
    if (text.rfind(twoFactorPrefix, 0) == 0) {
        g_enableTrustedDevices.store(text.substr(twoFactorPrefix.length()) == "1");
        SetLastConnectionMessage("2FA Required");
        g_lastConnectionResult.store(0);
        g_connectionStartedAtMs.store(0);
        g_connectionStatus.store(4);
    } else if (text == "login response: 2fa-wrong") {
        SetLastConnectionMessage("Wrong 2FA Code");
        g_lastConnectionResult.store(0);
        g_connectionStartedAtMs.store(0);
        g_connectionStatus.store(4);
    } else if (text.rfind("login response: ok/peer info", 0) == 0) {
        SetLastConnectionMessage("");
        g_lastConnectionResult.store(0);
        g_connectionStartedAtMs.store(0);
        g_connectionStatus.store(2);
    } else if (text.rfind(loginErrorPrefix, 0) == 0) {
        SetLastConnectionMessage(text.substr(loginErrorPrefix.length()));
        g_lastConnectionResult.store(-17);
        g_connectionStartedAtMs.store(0);
        g_connectionStatus.store(3);
    } else if (text.rfind("connection lost:", 0) == 0) {
        SetLastConnectionMessage("Peer connection closed");
        g_lastConnectionResult.store(-18);
        g_connectionStatus.store(3);
    } else if (text == "receive loop ended" &&
               (g_connectionStatus.load() == 1 || g_connectionStatus.load() == 2 ||
                g_connectionStatus.load() == 4)) {
        SetLastConnectionMessage("Peer connection closed");
        g_lastConnectionResult.store(-18);
        g_connectionStatus.store(3);
    }
}

static int OnRustAudioStart(int sampleRate, int channels) {
    OH_LOG_INFO(LOG_APP, "audio start entered sampleRate=%{public}d channels=%{public}d", sampleRate, channels);
    const int result = audio_player_start(sampleRate, channels);
    OH_LOG_INFO(LOG_APP, "audio start completed result=%{public}d", result);
    DiagnosticLog::instance().append(result == 0 ? "I" : "E", "audio",
        "start sample_rate=" + std::to_string(sampleRate) + " channels=" +
        std::to_string(channels) + " result=" + std::to_string(result));
    return result;
}

static void OnRustAudioStop() {
    OH_LOG_INFO(LOG_APP, "audio stop entered");
    audio_player_stop();
    OH_LOG_INFO(LOG_APP, "audio stop completed");
    DiagnosticLog::instance().append("I", "audio", "stopped");
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
        case -20: return "Connection timed out";
        case -21: return "Previous connection is still closing";
        case -22: return "Connection state is busy";
        default: return "Connection failed (" + std::to_string(result) + ")";
    }
}

static napi_value Connect(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char peerId[128] = {0}, password[512] = {0};
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
    std::string clientHwid = Config::instance().get("trust-this-device") == "Y"
        ? GetOrCreateClientHwid() : "";
    std::string clientId = GetOrCreateClientId();

    if (peer.empty()) {
        napi_value ret;
        napi_create_int32(env, -1, &ret);
        return ret;
    }
    uint64_t generation = g_connectionGeneration.fetch_add(1) + 1;
    g_connectionStatus.store(1);
    g_lastConnectionResult.store(0);
    g_connectionStartedAtMs.store(NowMs());
    g_enableTrustedDevices.store(false);
    SetLastConnectionMessage("");
    g_lastVideoHealthLogMs.store(0);
    g_lastVideoHealthFrameCount.store(g_videoFrameCount.load());
    g_lastVideoHealthDecodedCount.store(0);
    DiagnosticLog::instance().append("I", "connection",
        "connect_requested generation=" + std::to_string(generation) +
        " peer=" + MaskPeerId(peer) +
        " password_configured=" + std::string(pass.empty() ? "no" : "yes") +
        " rendezvous=" + std::string(rendezvous.empty() ? "default" : "custom") +
        " relay=" + std::string(relay.empty() ? "default" : "custom") +
        " key=" + std::string(serverKey.empty() ? "empty" : "set"));
    std::thread([peer, pass, rendezvous, relay, serverKey, clientHwid, clientId, generation]() {
        {
            std::unique_lock<std::mutex> lock(g_connectionLifecycleMutex);
            g_disconnectFinished.wait(lock, []() { return !g_disconnectInProgress.load(); });
        }
        if (g_connectionGeneration.load() != generation) {
            OH_LOG_INFO(LOG_APP, "Skip stale queued connect generation=%{public}llu",
                        static_cast<unsigned long long>(generation));
            DiagnosticLog::instance().append("W", "connection",
                "skip_stale_connect generation=" + std::to_string(generation));
            return;
        }
        VideoRender::instance().resetSession();
        OH_LOG_INFO(LOG_APP, "Starting rust_connect peer=%{private}s password_len=%{public}zu server=%{private}s key=%{public}s",
                    peer.c_str(), pass.size(), rendezvous.c_str(), serverKey.empty() ? "empty" : "set");
        OH_LOG_INFO(LOG_APP, "rust_connect thread entered generation=%{public}llu", static_cast<unsigned long long>(generation));
        DiagnosticLog::instance().append("I", "connection",
            "rust_connect_started generation=" + std::to_string(generation));
        int result = rust_connect(peer.c_str(), pass.c_str(), rendezvous.c_str(), relay.c_str(),
                                  serverKey.c_str(), clientHwid.c_str(), clientId.c_str());
        OH_LOG_INFO(LOG_APP, "rust_connect finished result=%{public}d", result);
        DiagnosticLog::instance().append(result == 0 ? "I" : "E", "connection",
            "rust_connect_finished generation=" + std::to_string(generation) +
            " result=" + std::to_string(result) + " message=" + ConnectionResultToMessage(result));
        if (g_connectionGeneration.load() != generation) {
            OH_LOG_INFO(LOG_APP, "Ignore stale rust_connect result generation=%{public}llu", static_cast<unsigned long long>(generation));
            return;
        }
        g_lastConnectionResult.store(result);
        if (result != 0) {
            g_connectionStartedAtMs.store(0);
            g_connectionStatus.store(3);
        }
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
    bool expected = false;
    if (!g_disconnectInProgress.compare_exchange_strong(expected, true)) {
        napi_value ret;
        napi_create_int32(env, 0, &ret);
        return ret;
    }
    uint64_t disconnectGeneration = g_connectionGeneration.fetch_add(1) + 1;
    g_connectionStatus.store(0);
    g_connectionStartedAtMs.store(0);
    DiagnosticLog::instance().append("I", "connection",
        "disconnect_requested generation=" + std::to_string(disconnectGeneration));
    std::thread([disconnectGeneration]() {
        OH_LOG_INFO(LOG_APP, "disconnect cleanup started generation=%{public}llu",
                    static_cast<unsigned long long>(disconnectGeneration));
        rust_disconnect();
        OH_LOG_INFO(LOG_APP, "disconnect cleanup rust finished generation=%{public}llu",
                    static_cast<unsigned long long>(disconnectGeneration));
        DiagnosticLog::instance().append("I", "connection",
            "disconnect_core_finished generation=" + std::to_string(disconnectGeneration));
        if (g_connectionGeneration.load() == disconnectGeneration) {
            VideoRender::instance().resetSession();
        } else {
            OH_LOG_INFO(LOG_APP, "Preserve video state for queued connect generation=%{public}llu current=%{public}llu",
                        static_cast<unsigned long long>(disconnectGeneration),
                        static_cast<unsigned long long>(g_connectionGeneration.load()));
        }
        g_disconnectInProgress.store(false);
        g_disconnectFinished.notify_all();
        if (g_connectionGeneration.load() == disconnectGeneration && g_connectionStatus.load() != 1) {
            g_connectionStatus.store(0);
        }
    }).detach();
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

// ===== Input Events =====

static napi_value SendKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t keyCode = 0, action = 0, modifierMask = 0;
    napi_get_value_int32(env, args[0], &keyCode);
    napi_get_value_int32(env, args[1], &action);
    if (argc >= 3) {
        napi_get_value_int32(env, args[2], &modifierMask);
    }
    int result = rust_send_key_event(keyCode, action, modifierMask);
    if (keyCode == 16 || keyCode == 17 || keyCode == 18 || keyCode == 20 || keyCode == 91 ||
        (keyCode >= 'A' && keyCode <= 'Z') || (keyCode >= 'a' && keyCode <= 'z')) {
        OH_LOG_INFO(LOG_APP,
            "InputTrace napi_key key=%{public}d action=%{public}d modifiers=%{public}d result=%{public}d",
            keyCode, action, modifierMask, result);
    }
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendKeyEvent key=%{public}d action=%{public}d result=%{public}d", keyCode, action, result);
    }
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value SendPhysicalKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t scanCode = 0, action = 0, modifierMask = 0;
    napi_get_value_int32(env, args[0], &scanCode);
    napi_get_value_int32(env, args[1], &action);
    if (argc >= 3) {
        napi_get_value_int32(env, args[2], &modifierMask);
    }
    int result = rust_send_physical_key_event(scanCode, action, modifierMask);
    OH_LOG_INFO(LOG_APP,
        "InputTrace napi_physical scan=%{public}d action=%{public}d modifiers=%{public}d result=%{public}d",
        scanCode, action, modifierMask, result);
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

static napi_value Send2FA(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char code[16] = {0};
    size_t codeLen = 0;
    bool trustThisDevice = false;
    if (argc >= 1) {
        napi_get_value_string_utf8(env, args[0], code, sizeof(code), &codeLen);
    }
    if (argc >= 2) {
        napi_get_value_bool(env, args[1], &trustThisDevice);
    }

    int result = -3;
    if (g_connectionStatus.load() == 4) {
        trustThisDevice = trustThisDevice && g_enableTrustedDevices.load();
        std::string clientHwid = trustThisDevice ? GetOrCreateClientHwid() : "";
        Config::instance().set("trust-this-device", trustThisDevice ? "Y" : "");
        Config::instance().save();
        result = rust_send_2fa(code, clientHwid.c_str());
        if (result == 0) {
            SetLastConnectionMessage("");
            g_connectionStatus.store(1);
            g_connectionStartedAtMs.store(NowMs());
        } else {
            SetLastConnectionMessage("Invalid 2FA code");
        }
    }

    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value GetEnableTrustedDevices(napi_env env, napi_callback_info info) {
    napi_value ret;
    napi_get_boolean(env, g_enableTrustedDevices.load(), &ret);
    return ret;
}

static napi_value SendMouseEvent(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double x = 0, y = 0;
    int32_t action = 0, modifierMask = 0;
    napi_get_value_double(env, args[0], &x);
    napi_get_value_double(env, args[1], &y);
    napi_get_value_int32(env, args[2], &action);
    if (argc >= 4) {
        napi_get_value_int32(env, args[3], &modifierMask);
    }
    int result = rust_send_mouse_event(x, y, action, modifierMask);
    if (action != 0) {
        OH_LOG_INFO(LOG_APP,
            "InputTrace napi_mouse action=%{public}d modifiers=%{public}d x=%{public}.1f y=%{public}.1f result=%{public}d",
            action, modifierMask, x, y, result);
    }
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendMouseEvent x=%{public}.1f y=%{public}.1f action=%{public}d result=%{public}d", x, y, action, result);
    }
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value SendMouseWheel(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double deltaX = 0, deltaY = 0;
    int32_t modifierMask = 0;
    napi_get_value_double(env, args[0], &deltaX);
    napi_get_value_double(env, args[1], &deltaY);
    if (argc >= 3) {
        napi_get_value_int32(env, args[2], &modifierMask);
    }
    int result = rust_send_mouse_wheel(deltaX, deltaY, modifierMask);
    if (result != 0) {
        OH_LOG_WARN(LOG_APP, "SendMouseWheel x=%{public}.1f y=%{public}.1f result=%{public}d", deltaX, deltaY, result);
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

// ===== Device Info =====

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
    if (status == 1) {
        int64_t startedAt = g_connectionStartedAtMs.load();
        if (startedAt > 0 && NowMs() - startedAt > 30000) {
            g_connectionGeneration.fetch_add(1);
            g_connectionStartedAtMs.store(0);
            g_lastConnectionResult.store(-20);
            SetLastConnectionMessage("Connection timed out");
            g_connectionStatus.store(3);
            std::thread([]() {
                rust_disconnect();
                VideoRender::instance().resetSession();
            }).detach();
            status = 3;
        }
    }
    if ((status == 2 || status == 4) && rust_get_connection_status() == 0) {
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

static napi_value FallbackVideoToVp9(napi_env env, napi_callback_info info) {
    int result = rust_fallback_video_to_vp9();
    OH_LOG_WARN(LOG_APP, "FallbackVideoToVp9 result=%{public}d", result);
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static std::string GetStringArgument(napi_env env, napi_value value) {
    size_t length = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &length);
    std::vector<char> buffer(length + 1, '\0');
    napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}

static napi_value InitializeDiagnosticLog(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc > 0 && args[0] != nullptr) {
        DiagnosticLog::instance().initialize(GetStringArgument(env, args[0]));
        DiagnosticLog::instance().append("I", "app", "diagnostic_log_initialized");
    }
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value SetDiagnosticLogEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool enabled = false;
    if (argc > 0 && args[0] != nullptr) {
        napi_get_value_bool(env, args[0], &enabled);
    }
    DiagnosticLog::instance().setEnabled(enabled);
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value AppendDiagnosticLog(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string component = argc > 0 && args[0] != nullptr ? GetStringArgument(env, args[0]) : "arkts";
    std::string message = argc > 1 && args[1] != nullptr ? GetStringArgument(env, args[1]) : "";
    DiagnosticLog::instance().append("I", component.c_str(), message);
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value GetDiagnosticLog(napi_env env, napi_callback_info info) {
    std::string content = DiagnosticLog::instance().exportText();
    napi_value ret;
    napi_create_string_utf8(env, content.c_str(), content.size(), &ret);
    return ret;
}

static napi_value ClearDiagnosticLog(napi_env env, napi_callback_info info) {
    DiagnosticLog::instance().clear();
    DiagnosticLog::instance().append("I", "app", "diagnostic_log_cleared");
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value RequestRemoteDirectory(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = argc > 0 ? GetStringArgument(env, args[0]) : "";
    int result = rust_request_remote_directory(path.c_str());
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value GetRemoteCursorPosition(napi_env env, napi_callback_info info) {
    int32_t x = 0;
    int32_t y = 0;
    uint64_t sequence = 0;
    bool valid = rust_get_remote_cursor_position(&x, &y, &sequence) != 0;
    bool embedded = rust_is_remote_cursor_embedded() != 0;
    napi_value object;
    napi_create_object(env, &object);
    napi_value validValue;
    napi_get_boolean(env, valid, &validValue);
    napi_set_named_property(env, object, "valid", validValue);
    napi_value embeddedValue;
    napi_get_boolean(env, embedded, &embeddedValue);
    napi_set_named_property(env, object, "embedded", embeddedValue);
    napi_value xValue;
    napi_create_int32(env, x, &xValue);
    napi_set_named_property(env, object, "x", xValue);
    napi_value yValue;
    napi_create_int32(env, y, &yValue);
    napi_set_named_property(env, object, "y", yValue);
    napi_value sequenceValue;
    napi_create_int64(env, static_cast<int64_t>(sequence), &sequenceValue);
    napi_set_named_property(env, object, "sequence", sequenceValue);
    return object;
}

static napi_value GetRemoteCursorData(napi_env env, napi_callback_info info) {
    uint64_t id = 0;
    uint64_t sequence = 0;
    int32_t hotx = 0;
    int32_t hoty = 0;
    int32_t width = 0;
    int32_t height = 0;
    int required = rust_get_remote_cursor_data(
        &id, &hotx, &hoty, &width, &height, &sequence, nullptr, 0);

    napi_value object;
    napi_create_object(env, &object);
    napi_value validValue;
    napi_get_boolean(env, required > 0, &validValue);
    napi_set_named_property(env, object, "valid", validValue);
    if (required <= 0) {
        return object;
    }

    std::vector<unsigned char> colors(static_cast<size_t>(required));
    int copied = rust_get_remote_cursor_data(
        &id, &hotx, &hoty, &width, &height, &sequence,
        colors.data(), static_cast<int32_t>(colors.size()));
    if (copied <= 0 || copied > static_cast<int>(colors.size())) {
        napi_get_boolean(env, false, &validValue);
        napi_set_named_property(env, object, "valid", validValue);
        return object;
    }

    napi_value idValue;
    napi_create_int64(env, static_cast<int64_t>(id), &idValue);
    napi_set_named_property(env, object, "id", idValue);
    napi_value hotxValue;
    napi_create_int32(env, hotx, &hotxValue);
    napi_set_named_property(env, object, "hotx", hotxValue);
    napi_value hotyValue;
    napi_create_int32(env, hoty, &hotyValue);
    napi_set_named_property(env, object, "hoty", hotyValue);
    napi_value widthValue;
    napi_create_int32(env, width, &widthValue);
    napi_set_named_property(env, object, "width", widthValue);
    napi_value heightValue;
    napi_create_int32(env, height, &heightValue);
    napi_set_named_property(env, object, "height", heightValue);
    napi_value sequenceValue;
    napi_create_int64(env, static_cast<int64_t>(sequence), &sequenceValue);
    napi_set_named_property(env, object, "sequence", sequenceValue);
    napi_value buffer;
    void* bufferData = nullptr;
    napi_create_arraybuffer(env, static_cast<size_t>(copied), &bufferData, &buffer);
    if (bufferData != nullptr) {
        std::memcpy(bufferData, colors.data(), static_cast<size_t>(copied));
    }
    napi_set_named_property(env, object, "colors", buffer);
    return object;
}

static napi_value TakeRemoteDirectoryResult(napi_env env, napi_callback_info info) {
    char* value = rust_take_remote_directory_result();
    napi_value ret;
    napi_create_string_utf8(env, value == nullptr ? "" : value, NAPI_AUTO_LENGTH, &ret);
    if (value != nullptr) rust_free_string(value);
    return ret;
}

static napi_value StartFileUpload(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_value ret;
        napi_create_int32(env, -1, &ret);
        return ret;
    }
    std::string path = GetStringArgument(env, args[0]);
    std::string name = GetStringArgument(env, args[1]);
    std::string directory = GetStringArgument(env, args[2]);
    int result = rust_start_file_upload(path.c_str(), name.c_str(), directory.c_str());
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value StartFileDownloadBatch(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_value ret;
        napi_create_int32(env, -1, &ret);
        return ret;
    }
    std::string requestsJson = GetStringArgument(env, args[0]);
    std::string localRoot = GetStringArgument(env, args[1]);
    int result = rust_start_file_download_batch(requestsJson.c_str(), localRoot.c_str());
    napi_value ret;
    napi_create_int32(env, result, &ret);
    return ret;
}

static napi_value GetFileTransferStatus(napi_env env, napi_callback_info info) {
    char* value = rust_get_file_transfer_status();
    napi_value ret;
    napi_create_string_utf8(env, value == nullptr ? "" : value, NAPI_AUTO_LENGTH, &ret);
    if (value != nullptr) rust_free_string(value);
    return ret;
}

static napi_value CancelFileTransfer(napi_env env, napi_callback_info info) {
    int result = rust_cancel_file_transfer();
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

    std::string endpoint(server, serverLen);
    std::string hostname = endpoint;
    int port = 21116;
    auto parsePort = [](const std::string& value, int& parsedPort) -> bool {
        if (value.empty()) return false;
        char* end = nullptr;
        long candidate = std::strtol(value.c_str(), &end, 10);
        if (end == nullptr || *end != '\0' || candidate <= 0 || candidate > 65535) return false;
        parsedPort = static_cast<int>(candidate);
        return true;
    };

    if (!endpoint.empty() && endpoint.front() == '[') {
        size_t closingBracket = endpoint.find(']');
        if (closingBracket != std::string::npos) {
            hostname = endpoint.substr(1, closingBracket - 1);
            if (closingBracket + 1 < endpoint.size() && endpoint[closingBracket + 1] == ':') {
                parsePort(endpoint.substr(closingBracket + 2), port);
            }
        }
    } else if (std::count(endpoint.begin(), endpoint.end(), ':') == 1) {
        size_t colonPos = endpoint.rfind(':');
        int parsedPort = port;
        if (parsePort(endpoint.substr(colonPos + 1), parsedPort)) {
            hostname = endpoint.substr(0, colonPos);
            port = parsedPort;
        }
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo* addresses = nullptr;
    std::string portText = std::to_string(port);
    int resolveRet = getaddrinfo(hostname.c_str(), portText.c_str(), &hints, &addresses);
    if (resolveRet != 0 || addresses == nullptr) {
        result = "DNS/IPv6解析失败";
        napi_value ret;
        napi_create_string_utf8(env, result.c_str(), result.length(), &ret);
        return ret;
    }

    bool connected = false;
    result = "连接失败";
    for (struct addrinfo* address = addresses; address != nullptr && !connected; address = address->ai_next) {
        int sock = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (sock < 0) continue;
        int flags = fcntl(sock, F_GETFL, 0);
        if (flags < 0 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) < 0) {
            close(sock);
            continue;
        }

        int connectRet = ::connect(sock, address->ai_addr, address->ai_addrlen);
        if (connectRet == 0) {
            connected = true;
        } else if (errno == EINPROGRESS) {
            fd_set fdset;
            FD_ZERO(&fdset);
            FD_SET(sock, &fdset);
            struct timeval tv;
            tv.tv_sec = 5;
            tv.tv_usec = 0;
            int selectRet = select(sock + 1, nullptr, &fdset, nullptr, &tv);
            if (selectRet > 0) {
                int socketError = 0;
                socklen_t errorLength = sizeof(socketError);
                if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 && socketError == 0) {
                    connected = true;
                } else if (socketError != 0) {
                    result = "连接被拒绝 (" + std::string(strerror(socketError)) + ")";
                }
            } else if (selectRet == 0) {
                result = "连接超时 (5秒)";
            }
        } else {
            result = "连接被拒绝 (" + std::string(strerror(errno)) + ")";
        }
        close(sock);
    }
    freeaddrinfo(addresses);
    if (connected) result.clear();

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
    uint64_t totalFrames = g_videoFrameCount.load();
    uint64_t totalBytes = g_videoByteCount.load();
    uint64_t decodedFrames = VideoRender::instance().decodedFrameCount();
    int codec = VideoRender::instance().activeCodec();
    int decoderMode = VideoRender::instance().activeDecodeMode();
    int64_t now = NowMs();
    int64_t previousHealthLog = g_lastVideoHealthLogMs.load();
    int status = g_connectionStatus.load();
    if ((status == 1 || status == 2 || status == 4) &&
        (previousHealthLog == 0 || now - previousHealthLog >= 5000) &&
        g_lastVideoHealthLogMs.compare_exchange_strong(previousHealthLog, now)) {
        uint64_t previousFrames = g_lastVideoHealthFrameCount.exchange(totalFrames);
        uint64_t previousDecoded = g_lastVideoHealthDecodedCount.exchange(decodedFrames);
        DiagnosticLog::instance().append("I", "video-health",
            "generation=" + std::to_string(g_connectionGeneration.load()) +
            " status=" + std::to_string(status) +
            " route=" + std::to_string(rust_get_connection_route()) +
            " codec=" + std::to_string(codec) +
            " decoder_mode=" + std::to_string(decoderMode) +
            " input_total=" + std::to_string(totalFrames) +
            " input_delta=" + std::to_string(totalFrames - previousFrames) +
            " bytes_total=" + std::to_string(totalBytes) +
            " decoded_total=" + std::to_string(decodedFrames) +
            " decoded_delta=" + std::to_string(decodedFrames - std::min(decodedFrames, previousDecoded)) +
            " frame=" + std::to_string(width) + "x" + std::to_string(height) +
            " latest_size=" + std::to_string(length) +
            " has_frame=" + std::string(hasFrame ? "yes" : "no"));
    }
    napi_value obj;
    napi_create_object(env, &obj);
    napi_value hasFrameVal; napi_get_boolean(env, hasFrame, &hasFrameVal); napi_set_named_property(env, obj, "hasFrame", hasFrameVal);
    napi_value widthVal; napi_create_int32(env, width, &widthVal); napi_set_named_property(env, obj, "width", widthVal);
    napi_value heightVal; napi_create_int32(env, height, &heightVal); napi_set_named_property(env, obj, "height", heightVal);
    napi_value lengthVal; napi_create_int32(env, length, &lengthVal); napi_set_named_property(env, obj, "length", lengthVal);
    napi_value frameCountVal; napi_create_int64(env, static_cast<int64_t>(totalFrames), &frameCountVal); napi_set_named_property(env, obj, "totalFrames", frameCountVal);
    napi_value byteCountVal; napi_create_int64(env, static_cast<int64_t>(totalBytes), &byteCountVal); napi_set_named_property(env, obj, "totalBytes", byteCountVal);
    napi_value decodedCountVal; napi_create_int64(env, static_cast<int64_t>(decodedFrames), &decodedCountVal); napi_set_named_property(env, obj, "decodedFrames", decodedCountVal);
    napi_value codecVal; napi_create_int32(env, codec, &codecVal); napi_set_named_property(env, obj, "codec", codecVal);
    napi_value decoderModeVal; napi_create_int32(env, decoderMode, &decoderModeVal); napi_set_named_property(env, obj, "decoderMode", decoderModeVal);
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
    // Keep surface updates ordered. Dispatching the empty-surface update to a
    // detached thread allows an old cleanup to run after a new XComponent has
    // already been bound, destroying the new native window and leaving video
    // decoding active against a stale surface.
    DiagnosticLog::instance().append("I", "surface", surface.empty() ? "unbind" : "bind");
    VideoRender::instance().setSurfaceId(surface);

    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value PrepareSurfaceRebind(napi_env env, napi_callback_info info) {
    VideoRender::instance().prepareSurfaceRebind();
    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value RebindSurface(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char surfaceId[128] = {0};
    size_t surfaceIdLen = 0;
    napi_get_value_string_utf8(env, args[0], surfaceId, sizeof(surfaceId), &surfaceIdLen);
    VideoRender::instance().rebindSurface(std::string(surfaceId, surfaceIdLen));

    napi_value ret;
    napi_create_int32(env, 0, &ret);
    return ret;
}

static napi_value TakeNativeMouseEvents(napi_env env, napi_callback_info info) {
    (void)info;
    std::deque<NativeMouseInputEvent> pending;
    {
        std::lock_guard<std::mutex> lock(g_nativeMouseInputMutex);
        pending.swap(g_nativeMouseInputEvents);
    }

    napi_value array;
    napi_create_array_with_length(env, pending.size(), &array);
    uint32_t index = 0;
    for (const NativeMouseInputEvent& input : pending) {
        napi_value object;
        napi_create_object(env, &object);
        napi_value x;
        napi_create_double(env, input.x, &x);
        napi_set_named_property(env, object, "x", x);
        napi_value y;
        napi_create_double(env, input.y, &y);
        napi_set_named_property(env, object, "y", y);
        napi_value action;
        napi_create_int32(env, input.action, &action);
        napi_set_named_property(env, object, "action", action);
        napi_value button;
        napi_create_int32(env, input.button, &button);
        napi_set_named_property(env, object, "button", button);
        napi_value hover;
        napi_create_int32(env, input.hover, &hover);
        napi_set_named_property(env, object, "hover", hover);
        napi_value timestamp;
        napi_create_int64(env, input.timestamp, &timestamp);
        napi_set_named_property(env, object, "timestamp", timestamp);
        napi_value modifierMask;
        napi_create_int32(env, input.modifierMask, &modifierMask);
        napi_set_named_property(env, object, "modifierMask", modifierMask);
        napi_value modifierValid;
        napi_get_boolean(env, input.modifierValid, &modifierValid);
        napi_set_named_property(env, object, "modifierValid", modifierValid);
        napi_set_element(env, array, index++, object);
    }
    return array;
}

static napi_value TakeNativeKeyEvents(napi_env env, napi_callback_info info) {
    (void)info;
    std::deque<NativeKeyInputEvent> pending;
    {
        std::lock_guard<std::mutex> lock(g_nativeKeyInputMutex);
        pending.swap(g_nativeKeyInputEvents);
    }

    napi_value array;
    napi_create_array_with_length(env, pending.size(), &array);
    uint32_t index = 0;
    for (const NativeKeyInputEvent& input : pending) {
        napi_value object;
        napi_create_object(env, &object);
        napi_value keyCode;
        napi_create_int32(env, input.keyCode, &keyCode);
        napi_set_named_property(env, object, "keyCode", keyCode);
        napi_value action;
        napi_create_int32(env, input.action, &action);
        napi_set_named_property(env, object, "action", action);
        napi_value timestamp;
        napi_create_int64(env, input.timestamp, &timestamp);
        napi_set_named_property(env, object, "timestamp", timestamp);
        napi_value modifierMask;
        napi_create_int32(env, input.modifierMask, &modifierMask);
        napi_set_named_property(env, object, "modifierMask", modifierMask);
        napi_value modifierValid;
        napi_get_boolean(env, input.modifierValid, &modifierValid);
        napi_set_named_property(env, object, "modifierValid", modifierValid);
        napi_value capsLockOn;
        napi_get_boolean(env, input.capsLockOn, &capsLockOn);
        napi_set_named_property(env, object, "capsLockOn", capsLockOn);
        napi_value capsLockValid;
        napi_get_boolean(env, input.capsLockValid, &capsLockValid);
        napi_set_named_property(env, object, "capsLockValid", capsLockValid);
        napi_set_element(env, array, index++, object);
    }
    return array;
}

static napi_value GetHardwareKeyStateForJs(napi_env env, napi_callback_info info) {
    (void)info;
    const HardwareKeyState state = GetHardwareKeyState();
    napi_value object;
    napi_create_object(env, &object);
    napi_value valid;
    napi_get_boolean(env, state.valid, &valid);
    napi_set_named_property(env, object, "valid", valid);
    napi_value modifierMask;
    napi_create_int32(env, state.modifierMask, &modifierMask);
    napi_set_named_property(env, object, "modifierMask", modifierMask);
    napi_value capsLockOn;
    napi_get_boolean(env, state.capsLockOn, &capsLockOn);
    napi_set_named_property(env, object, "capsLockOn", capsLockOn);
    napi_value capsLockValid;
    napi_get_boolean(env, state.capsLockValid, &capsLockValid);
    napi_set_named_property(env, object, "capsLockValid", capsLockValid);
    return object;
}

// ===== Module Registration =====

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    TryRegisterNativeInput(env, exports);
    Config::instance().load();
    // Always subscribe to the controlled device's real cursor. The local
    // pointer preference only controls HarmonyOS' own physical mouse pointer.
    rust_set_remote_cursor_visible(1);
    rust_set_frame_callback(OnRustVideoFrame);
    rust_set_event_callback(OnRustEvent);
    rust_set_audio_callbacks(OnRustAudioStart, OnRustAudioStop, OnRustAudioFrame);
    VideoDecoderCapabilities decoderCapabilities = VideoRender::instance().decoderCapabilities();
    rust_set_video_codec_support(decoderCapabilities.h264 ? 1 : 0,
                                 decoderCapabilities.vp9 ? 1 : 0,
                                 decoderCapabilities.vp8 ? 1 : 0,
                                 decoderCapabilities.av1 ? 1 : 0,
                                 decoderCapabilities.h265 ? 1 : 0);
    DiagnosticLog::instance().append("I", "native", "module_initialized");

    napi_property_descriptor desc[] = {
        {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initializeDiagnosticLog", nullptr, InitializeDiagnosticLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setDiagnosticLogEnabled", nullptr, SetDiagnosticLogEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"appendDiagnosticLog", nullptr, AppendDiagnosticLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDiagnosticLog", nullptr, GetDiagnosticLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearDiagnosticLog", nullptr, ClearDiagnosticLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPerformancePreset", nullptr, SetPerformancePreset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disconnect", nullptr, Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendKeyEvent", nullptr, SendKeyEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendPhysicalKeyEvent", nullptr, SendPhysicalKeyEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendText", nullptr, SendText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"send2FA", nullptr, Send2FA, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getEnableTrustedDevices", nullptr, GetEnableTrustedDevices, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseEvent", nullptr, SendMouseEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMouseWheel", nullptr, SendMouseWheel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDisplayCount", nullptr, GetDisplayCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCurrentDisplay", nullptr, GetCurrentDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRemoteCursorPosition", nullptr, GetRemoteCursorPosition, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRemoteCursorData", nullptr, GetRemoteCursorData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"switchDisplay", nullptr, SwitchDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"refreshVideo", nullptr, RefreshVideo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fallbackVideoToVp9", nullptr, FallbackVideoToVp9, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPeerList", nullptr, GetPeerList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConnectionStatus", nullptr, GetConnectionStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConnectionRoute", nullptr, GetConnectionRoute, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLastConnectionError", nullptr, GetLastConnectionError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDeviceName", nullptr, GetDeviceName, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getClipboardText", nullptr, GetClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setClipboardText", nullptr, SetClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendClipboardText", nullptr, SendClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestRemoteDirectory", nullptr, RequestRemoteDirectory, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeRemoteDirectoryResult", nullptr, TakeRemoteDirectoryResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startFileUpload", nullptr, StartFileUpload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startFileDownloadBatch", nullptr, StartFileDownloadBatch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getFileTransferStatus", nullptr, GetFileTransferStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelFileTransfer", nullptr, CancelFileTransfer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeRemoteClipboardText", nullptr, TakeRemoteClipboardText, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setOption", nullptr, SetOption, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getOption", nullptr, GetOption, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAllOptions", nullptr, GetAllOptions, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"testIfValidServer", nullptr, TestIfValidServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isUsingPublicServer", nullptr, IsUsingPublicServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVideoFrame", nullptr, GetVideoFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSurfaceId", nullptr, SetSurfaceId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prepareSurfaceRebind", nullptr, PrepareSurfaceRebind, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rebindSurface", nullptr, RebindSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeNativeMouseEvents", nullptr, TakeNativeMouseEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeNativeKeyEvents", nullptr, TakeNativeKeyEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getHardwareKeyState", nullptr, GetHardwareKeyStateForJs, nullptr, nullptr, nullptr, napi_default, nullptr},
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
