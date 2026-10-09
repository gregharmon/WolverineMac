#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace Wolverine {

enum class USBState { Waiting, Connected, Error, Stopped };

struct USBStatus {
    USBState state = USBState::Stopped;
    std::string message = "USB transport is stopped.";
    std::uint32_t locationID = 0;
};

// Opens only the wired 1532:0a57 controller's interface 0, FF/5D/01.
// It never opens or seizes the keyboard or configuration HID interfaces.
class USBTransport final {
public:
    using PacketHandler = std::function<void(const std::uint8_t*, std::size_t)>;
    using StatusHandler = std::function<void(const USBStatus&)>;

    USBTransport();
    ~USBTransport();
    USBTransport(const USBTransport&) = delete;
    USBTransport& operator=(const USBTransport&) = delete;

    // Starts USB discovery and asynchronous reads on a private thread.
    // Handlers execute on that thread. Packet storage is valid only during
    // the handler call; copy it when dispatching to another thread.
    // Receives every successfully read packet, including status messages.
    // The caller must validate the X360 packet header and length.
    // Handlers must not destroy this object or call start()/stop().
    bool start(PacketHandler packets, StatusHandler statuses = {});
    // Aborts the pending interrupt read and joins the private thread.
    void stop();
    USBStatus status() const;

    // Lists attached Razer USB devices and all their interface descriptors.
    // This is read-only; it does not open USB interfaces or change settings.
    static std::string diagnostics();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace Wolverine
