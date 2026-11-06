#pragma once

#include <cstdint>
#include <vector>

// Local, ephemeral device slots only: never export a hardware identifier.
struct GamepadInputEvent {
    // 0 button, 1 axis, 2 device disconnected, 3 overflow/reset.
    int32_t kind = 0;
    int32_t device = 0;
    int32_t control = 0;
    int32_t action = 0; // button: 0 down, 1 up
    double x = 0;
    double y = 0;
};

// Loading GameControllerKit is optional: this app supports devices older than
// API 21. No system library is loaded or monitor registered until requested.
int StartGamepadInput();
void StopGamepadInput();
std::vector<GamepadInputEvent> TakeGamepadInput();
