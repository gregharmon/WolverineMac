#include "VirtualGamepad.h"
#include <cassert>
#include <iostream>

using namespace Wolverine;

static uint16_t read16(const std::array<uint8_t, 17>& report, size_t offset) {
    return static_cast<uint16_t>(report[offset] | (uint16_t{report[offset + 1]} << 8));
}

int main() {
    X360State state{};
    const auto neutral = encodeXboxReport(state);
    assert((neutral == std::array<uint8_t, 17>{1, 0, 128, 0, 128, 0, 128, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0}));

    state.lx = -32768;
    state.ly = 32767;
    state.rx = 32767;
    state.ry = -32768;
    state.leftTrigger = 255;
    state.rightTrigger = 128;
    auto report = encodeXboxReport(state);
    assert(read16(report, 1) == 0);
    assert(read16(report, 3) == 1);
    assert(read16(report, 5) == 65535);
    assert(read16(report, 7) == 65535);
    assert(read16(report, 9) == 1023);
    assert(read16(report, 11) == 513);
    state.lx = 32767;
    state.ly = -32768;
    state.rx = -32768;
    state.ry = 32767;
    report = encodeXboxReport(state);
    assert(read16(report, 1) == 65535 && read16(report, 3) == 65535);
    assert(read16(report, 5) == 0 && read16(report, 7) == 1);

    struct ButtonCase { uint16_t wire; size_t byte; uint8_t mask; };
    const ButtonCase controls[] = {
        {0x1000, 14, 0x01}, {0x2000, 14, 0x02}, {0x4000, 14, 0x08}, {0x8000, 14, 0x10},
        {0x0100, 14, 0x40}, {0x0200, 14, 0x80}, {0x0020, 15, 0x04}, {0x0010, 15, 0x08},
        {0x0040, 15, 0x20}, {0x0080, 15, 0x40}, {0x0400, 15, 0x10},
    };
    for (const auto& control : controls) {
        state = {};
        state.buttons = control.wire;
        report = encodeXboxReport(state);
        assert(report[control.byte] == control.mask);
        for (size_t i = 0; i < report.size(); ++i)
            assert(i == control.byte || report[i] == neutral[i]);
    }
    const uint16_t directions[] = {0, 1, 9, 8, 10, 2, 6, 4, 5};
    for (uint8_t direction = 0; direction < 9; ++direction) {
        state = {};
        state.buttons = directions[direction];
        report = encodeXboxReport(state);
        assert(report[13] == direction);
        assert(report[14] == 0);
        assert(report[15] == 0);
        assert(report[16] == 0);
    }
    state.buttons = 0x000F;
    assert(encodeXboxReport(state)[13] == 0);
    state.buttons = 0x0400;
    assert((encodeXboxGuideReport(state) == std::array<uint8_t, 2>{2, 1}));
    state.buttons = 0;
    assert((encodeXboxGuideReport(state) == std::array<uint8_t, 2>{2, 0}));
    std::cout << "Virtual Xbox report checks passed: neutral, all buttons, axes, triggers, and D-pad.\n";
}
