#pragma once

#include "ControllerState.h"
#include <array>
#include <cstdint>
#include <memory>
#include <string>

namespace Wolverine {

// Complete Xbox Series Bluetooth report 1, including its report ID.
// X360 stick Y is positive upward. HID Y is positive downward.
std::array<uint8_t, 17> encodeXboxReport(const X360State& state);
std::array<uint8_t, 2> encodeXboxGuideReport(const X360State& state);

class VirtualGamepad {
public:
    VirtualGamepad();
    ~VirtualGamepad();
    VirtualGamepad(const VirtualGamepad&) = delete;
    VirtualGamepad& operator=(const VirtualGamepad&) = delete;

    // One worker owns create/publish/destroy. Serialize external reads with that
    // worker. Main-queue get-report callbacks protect their cached data internally.
    bool create(std::string& error);
    // Every input is published; this does not coalesce controller state.
    bool publish(const X360State& state, std::string& error);
    void destroy();
    bool active() const;
    // Call on the main thread so GameController shares the application's loop.
    std::string diagnostics() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace Wolverine
