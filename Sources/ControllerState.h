#pragma once
#include <cstddef>
#include <cstdint>
#include <string>

namespace Wolverine {
// Standard Xbox 360 USB wire bit positions, not HID button indices.
enum Button : uint16_t {
    Up = 0x0001, Down = 0x0002, Left = 0x0004, Right = 0x0008,
    Start = 0x0010, Back = 0x0020, LeftStick = 0x0040, RightStick = 0x0080,
    LeftBumper = 0x0100, RightBumper = 0x0200, Guide = 0x0400,
    A = 0x1000, B = 0x2000, X = 0x4000, Y = 0x8000
};
struct X360State {
    uint16_t buttons = 0;
    uint8_t leftTrigger = 0, rightTrigger = 0;
    int16_t lx = 0, ly = 0, rx = 0, ry = 0;
};
// Returns false for status, malformed and truncated packets. Leaves state intact.
bool decodePacket(const uint8_t *bytes, size_t length, X360State &state);
std::string describeState(const X360State &state);
}
