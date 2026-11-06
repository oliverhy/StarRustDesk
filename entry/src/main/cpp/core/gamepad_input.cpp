#include "gamepad_input.h"

#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_pad.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
constexpr size_t kMaxEvents = 512;
constexpr size_t kMaxDevices = 16;
std::mutex g_mutex;
std::atomic<bool> g_active{false};
void* g_library = nullptr; // Intentionally kept loaded while callbacks may be in flight.
std::deque<GamepadInputEvent> g_events;
std::unordered_map<std::string, int32_t> g_deviceSlots;
int32_t g_nextSlot = 1;

using ButtonCallback = GamePad_ButtonInputMonitorCallback;
using AxisCallback = GamePad_AxisInputMonitorCallback;
using DeviceCallback = GameDevice_DeviceMonitorCallback;
using RegisterButton = GameController_ErrorCode (*)(ButtonCallback);
using RegisterAxis = GameController_ErrorCode (*)(AxisCallback);
using RegisterDevice = GameController_ErrorCode (*)(DeviceCallback);
using Unregister = GameController_ErrorCode (*)();
using ButtonId = decltype(&OH_GamePad_ButtonEvent_GetDeviceId);
using ButtonAction = decltype(&OH_GamePad_ButtonEvent_GetButtonAction);
using ButtonCode = decltype(&OH_GamePad_ButtonEvent_GetButtonCode);
using AxisId = decltype(&OH_GamePad_AxisEvent_GetDeviceId);
using AxisSource = decltype(&OH_GamePad_AxisEvent_GetAxisSourceType);
using AxisValue = decltype(&OH_GamePad_AxisEvent_GetXAxisValue);
using DeviceType = decltype(&OH_GameDevice_DeviceEvent_GetChangedType);
using DeviceInfo = decltype(&OH_GameDevice_DeviceEvent_GetDeviceInfo);
using DeviceId = decltype(&OH_GameDevice_DeviceInfo_GetDeviceId);
using DestroyDevice = decltype(&OH_GameDevice_DestroyDeviceInfo);

ButtonId g_buttonId = nullptr;
ButtonAction g_buttonAction = nullptr;
ButtonCode g_buttonCode = nullptr;
AxisId g_axisId = nullptr;
AxisSource g_axisSource = nullptr;
AxisValue g_x = nullptr, g_y = nullptr, g_z = nullptr, g_rz = nullptr;
AxisValue g_hatX = nullptr, g_hatY = nullptr, g_brake = nullptr, g_gas = nullptr;
DeviceType g_deviceType = nullptr;
DeviceInfo g_deviceInfo = nullptr;
DeviceId g_deviceId = nullptr;
DestroyDevice g_destroyDevice = nullptr;
std::vector<Unregister> g_unregister;

template <typename T> T Symbol(const char* name) {
    return reinterpret_cast<T>(dlsym(g_library, name));
}

int32_t SlotLocked(const char* id, bool create) {
    if (!id || !*id) return 0;
    const std::string key(id);
    auto it = g_deviceSlots.find(key);
    if (it != g_deviceSlots.end()) return it->second;
    if (!create || g_deviceSlots.size() >= kMaxDevices) return 0;
    if (g_nextSlot <= 0 || g_nextSlot >= 0x7ffffffe) g_nextSlot = 1;
    const int32_t slot = g_nextSlot++;
    g_deviceSlots.emplace(key, slot);
    return slot;
}

void PushLocked(const GamepadInputEvent& event) {
    // Coalesce only adjacent axes for the same device/control; never move an
    // axis across a button edge. Overflow fails closed by requesting release.
    if (event.kind == 1 && !g_events.empty()) {
        GamepadInputEvent& tail = g_events.back();
        if (tail.kind == 1 && tail.device == event.device && tail.control == event.control) {
            tail = event;
            return;
        }
    }
    if (g_events.size() >= kMaxEvents) {
        g_events.clear();
        g_events.push_back(GamepadInputEvent{3});
        return;
    }
    g_events.push_back(event);
}

void ButtonEvent(const GamePad_ButtonEvent* event) {
    if (!g_active.load() || !event) return;
    char* id = nullptr;
    GamePad_Button_ActionType action{};
    int32_t code = 0;
    if (g_buttonId(event, &id) != GAME_CONTROLLER_SUCCESS || !id ||
        g_buttonAction(event, &action) != GAME_CONTROLLER_SUCCESS ||
        g_buttonCode(event, &code) != GAME_CONTROLLER_SUCCESS) {
        std::free(id);
        return;
    }
    if (action != DOWN && action != UP) { std::free(id); return; }
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_active.load()) {
            int32_t slot = SlotLocked(id, true);
            if (slot) PushLocked(GamepadInputEvent{0, slot, code, action == DOWN ? 0 : 1});
        }
    }
    std::free(id);
}

void AxisEvent(const GamePad_AxisEvent* event) {
    if (!g_active.load() || !event) return;
    char* id = nullptr;
    GamePad_AxisSourceType source{};
    double x = 0, y = 0;
    if (g_axisId(event, &id) != GAME_CONTROLLER_SUCCESS || !id ||
        g_axisSource(event, &source) != GAME_CONTROLLER_SUCCESS) {
        std::free(id);
        return;
    }
    GameController_ErrorCode first = GAME_CONTROLLER_PARAM_ERROR;
    GameController_ErrorCode second = GAME_CONTROLLER_SUCCESS;
    switch (source) {
        case LEFT_THUMBSTICK: first = g_x(event, &x); second = g_y(event, &y); break;
        case RIGHT_THUMBSTICK: first = g_z(event, &x); second = g_rz(event, &y); break;
        case DPAD: first = g_hatX(event, &x); second = g_hatY(event, &y); break;
        case LEFT_TRIGGER: first = g_brake(event, &x); break;
        case RIGHT_TRIGGER: first = g_gas(event, &x); break;
        default: break;
    }
    if (first == GAME_CONTROLLER_SUCCESS && second == GAME_CONTROLLER_SUCCESS &&
        std::isfinite(x) && std::isfinite(y)) {
        x = std::max(-1.0, std::min(1.0, x));
        y = std::max(-1.0, std::min(1.0, y));
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_active.load()) {
            int32_t slot = SlotLocked(id, true);
            if (slot) PushLocked(GamepadInputEvent{1, slot, static_cast<int32_t>(source), 0, x, y});
        }
    }
    std::free(id);
}

void DeviceEvent(const GameDevice_DeviceEvent* event) {
    if (!g_active.load() || !event) return;
    GameDevice_StatusChangedType state{};
    GameDevice_DeviceInfo* info = nullptr;
    char* id = nullptr;
    const bool offline = g_deviceType(event, &state) == GAME_CONTROLLER_SUCCESS && state == OFFLINE;
    if (offline && g_deviceInfo(event, &info) == GAME_CONTROLLER_SUCCESS && info) {
        g_deviceId(info, &id);
    }
    if (offline) {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_active.load()) {
            if (!id) {
                // A device disappeared before the system could supply its ID.
                // Release every mapped input rather than leaving a key stuck.
                PushLocked(GamepadInputEvent{3});
                g_deviceSlots.clear();
            } else {
                const int32_t slot = SlotLocked(id, false);
                if (slot) {
                    PushLocked(GamepadInputEvent{2, slot});
                    g_deviceSlots.erase(id);
                }
            }
        }
    }
    std::free(id);
    if (info) g_destroyDevice(&info);
}

bool LoadApi() {
    if (!g_library) g_library = dlopen("libohgame_controller.z.so", RTLD_NOW | RTLD_LOCAL);
    if (!g_library) return false;
#define LOAD(member, name) member = Symbol<decltype(member)>(name); if (!member) return false
    LOAD(g_buttonId, "OH_GamePad_ButtonEvent_GetDeviceId");
    LOAD(g_buttonAction, "OH_GamePad_ButtonEvent_GetButtonAction");
    LOAD(g_buttonCode, "OH_GamePad_ButtonEvent_GetButtonCode");
    LOAD(g_axisId, "OH_GamePad_AxisEvent_GetDeviceId");
    LOAD(g_axisSource, "OH_GamePad_AxisEvent_GetAxisSourceType");
    LOAD(g_x, "OH_GamePad_AxisEvent_GetXAxisValue");
    LOAD(g_y, "OH_GamePad_AxisEvent_GetYAxisValue");
    LOAD(g_z, "OH_GamePad_AxisEvent_GetZAxisValue");
    LOAD(g_rz, "OH_GamePad_AxisEvent_GetRZAxisValue");
    LOAD(g_hatX, "OH_GamePad_AxisEvent_GetHatXAxisValue");
    LOAD(g_hatY, "OH_GamePad_AxisEvent_GetHatYAxisValue");
    LOAD(g_brake, "OH_GamePad_AxisEvent_GetBrakeAxisValue");
    LOAD(g_gas, "OH_GamePad_AxisEvent_GetGasAxisValue");
    LOAD(g_deviceType, "OH_GameDevice_DeviceEvent_GetChangedType");
    LOAD(g_deviceInfo, "OH_GameDevice_DeviceEvent_GetDeviceInfo");
    LOAD(g_deviceId, "OH_GameDevice_DeviceInfo_GetDeviceId");
    LOAD(g_destroyDevice, "OH_GameDevice_DestroyDeviceInfo");
#undef LOAD
    return true;
}

bool Register(const char* registerName, const char* unregisterName, int type) {
    auto unreg = Symbol<Unregister>(unregisterName);
    if (!unreg) return false;
    GameController_ErrorCode result = GAME_CONTROLLER_PARAM_ERROR;
    if (type == 0) {
        auto reg = Symbol<RegisterButton>(registerName);
        if (reg) result = reg(ButtonEvent);
    } else if (type == 1) {
        auto reg = Symbol<RegisterAxis>(registerName);
        if (reg) result = reg(AxisEvent);
    } else {
        auto reg = Symbol<RegisterDevice>(registerName);
        if (reg) result = reg(DeviceEvent);
    }
    if (result != GAME_CONTROLLER_SUCCESS) return false;
    g_unregister.push_back(unreg);
    return true;
}
} // namespace

int StartGamepadInput() {
    if (g_active.load()) return 0;
    if (!LoadApi()) return -1;
    g_active.store(true);
    const char* buttons[] = { "LeftShoulder", "RightShoulder", "LeftTrigger", "RightTrigger",
        "ButtonMenu", "ButtonHome", "ButtonA", "ButtonB", "ButtonC", "ButtonX", "ButtonY",
        "Dpad_LeftButton", "Dpad_RightButton", "Dpad_UpButton", "Dpad_DownButton",
        "LeftThumbstick", "RightThumbstick" };
    const char* axes[] = { "LeftTrigger", "RightTrigger", "Dpad", "LeftThumbstick", "RightThumbstick" };
    bool ok = Register("OH_GameDevice_RegisterDeviceMonitor", "OH_GameDevice_UnregisterDeviceMonitor", 2);
    for (const char* name : buttons) {
        if (!ok) break;
        const std::string prefix = std::string("OH_GamePad_") + name;
        ok = Register((prefix + "_RegisterButtonInputMonitor").c_str(),
                      (prefix + "_UnregisterButtonInputMonitor").c_str(), 0);
    }
    for (const char* name : axes) {
        if (!ok) break;
        const std::string prefix = std::string("OH_GamePad_") + name;
        ok = Register((prefix + "_RegisterAxisInputMonitor").c_str(),
                      (prefix + "_UnregisterAxisInputMonitor").c_str(), 1);
    }
    if (!ok) { StopGamepadInput(); return -2; }
    return 0;
}

void StopGamepadInput() {
    g_active.store(false);
    for (auto it = g_unregister.rbegin(); it != g_unregister.rend(); ++it) (*it)();
    g_unregister.clear();
    std::lock_guard<std::mutex> lock(g_mutex);
    g_events.clear();
    g_deviceSlots.clear();
}

std::vector<GamepadInputEvent> TakeGamepadInput() {
    std::lock_guard<std::mutex> lock(g_mutex);
    std::vector<GamepadInputEvent> result(g_events.begin(), g_events.end());
    g_events.clear();
    return result;
}
