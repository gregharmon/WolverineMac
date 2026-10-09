// Xbox Series Bluetooth HID descriptor adapted from OpenJoystickDriver.
// Copyright (c) 2026 Krystian J. MIT license; see THIRD_PARTY_NOTICES.txt.
// Source commit: d43199315ce713cc8c5f543077cf5da616b61efb
// Sources/OpenJoystickDriverKit/Output/HID/Xbox/Bluetooth.swift
// Report bytes follow the physical Xbox Series Bluetooth parser in official SDL
// commit 075e1d87596ca5595da181233d72e1cea4942239, SDL_hidapi_xboxone.c.
// OJD's contiguous button packer does not match the physical 17-byte Xbox Series
// layout and is not used. Live game input is unverified.
#include "VirtualGamepad.h"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <algorithm>
#include <cstring>
#include <mach/mach_time.h>
#include <mutex>
#include <pthread.h>
#include <sstream>

namespace Wolverine {

namespace {
constexpr uint8_t kXboxDescriptor[] = {
    0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x09, 0x30, 0x09, 0x31,
    0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x95, 0x02, 0x75, 0x10, 0x81, 0x02, 0xC0, 0x09, 0x01,
    0xA1, 0x00, 0x09, 0x33, 0x09, 0x34, 0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x95, 0x02, 0x75,
    0x10, 0x81, 0x02, 0xC0, 0x05, 0x01, 0x09, 0x32, 0x15, 0x00, 0x26, 0xFF, 0x03, 0x95, 0x01, 0x75,
    0x0A, 0x81, 0x02, 0x15, 0x00, 0x25, 0x00, 0x75, 0x06, 0x95, 0x01, 0x81, 0x03, 0x05, 0x01, 0x09,
    0x35, 0x15, 0x00, 0x26, 0xFF, 0x03, 0x95, 0x01, 0x75, 0x0A, 0x81, 0x02, 0x15, 0x00, 0x25, 0x00,
    0x75, 0x06, 0x95, 0x01, 0x81, 0x03, 0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08, 0x35, 0x00,
    0x46, 0x3B, 0x01, 0x66, 0x14, 0x00, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0x75, 0x04, 0x95, 0x01,
    0x15, 0x00, 0x25, 0x00, 0x35, 0x00, 0x45, 0x00, 0x65, 0x00, 0x81, 0x03, 0x05, 0x09, 0x19, 0x01,
    0x29, 0x0F, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0F, 0x81, 0x02, 0x15, 0x00, 0x25, 0x00,
    0x75, 0x01, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x0C, 0x0A, 0xB2, 0x00, 0x15, 0x00, 0x25, 0x01, 0x95, 0x01, 0x75, 0x01, 0x81, 0x02, 0x15,
    0x00, 0x25, 0x00, 0x75, 0x07, 0x95, 0x01, 0x81, 0x03, 0x05, 0x01, 0x09, 0x80, 0x85, 0x02, 0xA1,
    0x00, 0x09, 0x85, 0x15, 0x00, 0x25, 0x01, 0x95, 0x01, 0x75, 0x01, 0x81, 0x02, 0x15, 0x00, 0x25,
    0x00, 0x75, 0x07, 0x95, 0x01, 0x81, 0x03, 0xC0, 0x05, 0x0F, 0x09, 0x21, 0x85, 0x03, 0xA1, 0x02,
    0x09, 0x97, 0x15, 0x00, 0x25, 0x01, 0x75, 0x04, 0x95, 0x01, 0x91, 0x02, 0x15, 0x00, 0x25, 0x00,
    0x75, 0x04, 0x95, 0x01, 0x91, 0x03, 0x09, 0x70, 0x15, 0x00, 0x25, 0x64, 0x75, 0x08, 0x95, 0x04,
    0x91, 0x02, 0x09, 0x50, 0x66, 0x01, 0x10, 0x55, 0x0E, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
    0x95, 0x01, 0x91, 0x02, 0x09, 0xA7, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x01, 0x91,
    0x02, 0x65, 0x00, 0x55, 0x00, 0x09, 0x7C, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x01,
    0x91, 0x02, 0xC0, 0x85, 0x04, 0x05, 0x06, 0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
    0x95, 0x01, 0x81, 0x02, 0xC0,
};
constexpr const char* kSerial = "WolverineMac-USB-C-Bridge";

struct ReportCache {
    std::mutex mutex;
    std::array<uint8_t, 17> input = encodeXboxReport(X360State{});
    bool guideSent = false;
    uint8_t lastGuide = 0;
};

void write16(std::array<uint8_t, 17>& bytes, size_t offset, uint16_t value) {
    bytes[offset] = static_cast<uint8_t>(value);
    bytes[offset + 1] = static_cast<uint8_t>(value >> 8);
}

uint16_t stick(int16_t value, bool invert) {
    int32_t signedValue = invert ? -static_cast<int32_t>(value) : value;
    signedValue = std::clamp(signedValue, int32_t{-32768}, int32_t{32767});
    return static_cast<uint16_t>(signedValue + 32768);
}

uint8_t hat(uint16_t buttons) {
    const int x = ((buttons & 0x0008) != 0) - ((buttons & 0x0004) != 0);
    const int y = ((buttons & 0x0002) != 0) - ((buttons & 0x0001) != 0);
    if (y < 0) return x < 0 ? 8 : (x > 0 ? 2 : 1);
    if (y > 0) return x < 0 ? 6 : (x > 0 ? 4 : 5);
    return x < 0 ? 7 : (x > 0 ? 3 : 0);
}

std::string ioError(const char* action, IOReturn result) {
    std::ostringstream message;
    message << action << " failed (IOKit 0x" << std::hex << static_cast<uint32_t>(result) << ").";
    return message.str();
}
} // namespace

std::array<uint8_t, 17> encodeXboxReport(const X360State& state) {
    std::array<uint8_t, 17> report{};
    report[0] = 1;
    write16(report, 1, stick(state.lx, false));
    write16(report, 3, stick(state.ly, true));
    write16(report, 5, stick(state.rx, false));
    write16(report, 7, stick(state.ry, true));
    write16(report, 9, static_cast<uint16_t>(static_cast<uint32_t>(state.leftTrigger) * 1023 / 255));
    write16(report, 11, static_cast<uint16_t>(static_cast<uint32_t>(state.rightTrigger) * 1023 / 255));
    report[13] = hat(state.buttons);
    const uint16_t b = state.buttons;
    // Physical Xbox Series report 1 leaves Button usages 3, 6, 9, and 10 clear.
    // D-pad is the hat above; it does not overlap the Menu/Guide/stick buttons.
    report[14] = static_cast<uint8_t>(((b & A) ? 0x01 : 0) | ((b & B) ? 0x02 : 0)
        | ((b & X) ? 0x08 : 0) | ((b & Y) ? 0x10 : 0)
        | ((b & LeftBumper) ? 0x40 : 0) | ((b & RightBumper) ? 0x80 : 0));
    report[15] = static_cast<uint8_t>(((b & Back) ? 0x04 : 0) | ((b & Start) ? 0x08 : 0)
        | ((b & Guide) ? 0x10 : 0) | ((b & LeftStick) ? 0x20 : 0)
        | ((b & RightStick) ? 0x40 : 0));
    // X360 input has no independent Xbox Series Share control.
    return report;
}

std::array<uint8_t, 2> encodeXboxGuideReport(const X360State& state) {
    return {2, static_cast<uint8_t>((state.buttons & 0x0400) != 0)};
}

struct VirtualGamepad::Impl {
    IOHIDUserDeviceRef device = nullptr;
    std::shared_ptr<ReportCache> reports = std::make_shared<ReportCache>();
};

VirtualGamepad::VirtualGamepad() : impl_(std::make_unique<Impl>()) {}
VirtualGamepad::~VirtualGamepad() { destroy(); }

bool VirtualGamepad::create(std::string& error) {
    error.clear();
    if (active()) {
        error = "The virtual gamepad is already active.";
        return false;
    }
    NSDictionary* properties = @{
        @kIOHIDReportDescriptorKey: [NSData dataWithBytes:kXboxDescriptor length:sizeof(kXboxDescriptor)],
        @kIOHIDVendorIDKey: @0x045E,
        @kIOHIDProductIDKey: @0x0B13,
        @kIOHIDVersionNumberKey: @0,
        @kIOHIDProductKey: @"Xbox Wireless Controller",
        @kIOHIDManufacturerKey: @"Microsoft",
        @kIOHIDSerialNumberKey: [NSString stringWithUTF8String:kSerial],
        @kIOHIDTransportKey: @"Bluetooth",
        @kIOHIDLocationIDKey: @0x574D0001,
        @kIOHIDMaxInputReportSizeKey: @17,
        @kIOHIDMaxOutputReportSizeKey: @9,
    };
    IOHIDUserDeviceRef device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault,
        (__bridge CFDictionaryRef)properties, IOHIDUserDeviceOptionsCreateOnActivate);
    if (!device) {
        error = "macOS refused virtual HID creation. This requires an Apple-approved "
            "com.apple.developer.hid.virtual.device provisioning profile and matching code signature. "
            "Ad hoc signing and root do not grant this capability.";
        return false;
    }
    auto reports = std::make_shared<ReportCache>();
    IOHIDUserDeviceRegisterGetReportBlock(device, ^IOReturn(IOHIDReportType type,
        uint32_t reportID, uint8_t* bytes, CFIndex* length) {
        if (type != kIOHIDReportTypeInput) return kIOReturnUnsupported;
        if (!bytes || !length || *length < 0) return kIOReturnBadArgument;
        if (reportID == 1) {
            std::lock_guard<std::mutex> lock(reports->mutex);
            if (*length < static_cast<CFIndex>(reports->input.size())) return kIOReturnNoSpace;
            std::memcpy(bytes, reports->input.data(), reports->input.size());
            *length = reports->input.size();
            return kIOReturnSuccess;
        }
        if (reportID == 2) {
            if (*length < 2) return kIOReturnNoSpace;
            std::lock_guard<std::mutex> lock(reports->mutex);
            bytes[0] = 2;
            bytes[1] = (reports->input[15] & 0x10) ? 1 : 0;
            *length = 2;
            return kIOReturnSuccess;
        }
        // Physical battery and haptics are not implemented.
        return kIOReturnUnsupported;
    });
    IOHIDUserDeviceRegisterSetReportBlock(device, ^IOReturn(IOHIDReportType, uint32_t,
        const uint8_t*, CFIndex) { return kIOReturnUnsupported; });
    IOHIDUserDeviceSetDispatchQueue(device, dispatch_get_main_queue());
    IOHIDUserDeviceSetCancelHandler(device, ^{ CFRelease(device); });
    IOHIDUserDeviceActivate(device);
    // IOHIDUserDevice creation forces Transport=Virtual. Publishing the source
    // identity's transport after activation matches OJD's current implementation.
    if (!IOHIDUserDeviceSetProperty(device, CFSTR(kIOHIDTransportKey), CFSTR("Bluetooth"))) {
        IOHIDUserDeviceCancel(device);
        error = "macOS refused the Xbox Bluetooth HID transport property.";
        return false;
    }
    impl_->device = device;
    impl_->reports = reports;
    if (!publish(X360State{}, error)) {
        destroy();
        return false;
    }
    return true;
}

bool VirtualGamepad::publish(const X360State& state, std::string& error) {
    error.clear();
    if (!active()) {
        error = "The virtual gamepad is not active.";
        return false;
    }
    const auto report = encodeXboxReport(state);
    const auto guide = encodeXboxGuideReport(state);
    bool guideChanged;
    {
        std::lock_guard<std::mutex> lock(impl_->reports->mutex);
        guideChanged = !impl_->reports->guideSent || impl_->reports->lastGuide != guide[1];
        impl_->reports->input = report;
    }
    const IOReturn result = IOHIDUserDeviceHandleReportWithTimeStamp(impl_->device,
        mach_absolute_time(), report.data(), report.size());
    if (result != kIOReturnSuccess) {
        error = ioError("Virtual gamepad report publication", result);
        return false;
    }
    // Xbox Bluetooth exposes System Main Menu in input report 2. SDL's official
    // Xbox One HIDAPI parser consumes this separate Guide packet. Always publish
    // its first state and both edges; every primary controller report still runs.
    if (guideChanged) {
        const IOReturn guideResult = IOHIDUserDeviceHandleReportWithTimeStamp(impl_->device,
            mach_absolute_time(), guide.data(), guide.size());
        if (guideResult != kIOReturnSuccess) {
            error = ioError("Virtual Guide report publication", guideResult);
            return false;
        }
        std::lock_guard<std::mutex> lock(impl_->reports->mutex);
        impl_->reports->guideSent = true;
        impl_->reports->lastGuide = guide[1];
    }
    return true;
}

void VirtualGamepad::destroy() {
    if (!impl_ || !impl_->device) return;
    IOHIDUserDeviceCancel(impl_->device);
    impl_->device = nullptr;
}

bool VirtualGamepad::active() const { return impl_ && impl_->device != nullptr; }

std::string VirtualGamepad::diagnostics() const {
    if (!pthread_main_np()) return "Virtual gamepad diagnostics require the main thread.";
    if (!active()) return "Virtual HID inactive; Mac game input has not been verified.";
    NSDictionary* ownedProperties = @{
        @kIOHIDVendorIDKey: @0x045E,
        @kIOHIDProductIDKey: @0x0B13,
        @kIOHIDSerialNumberKey: [NSString stringWithUTF8String:kSerial],
    };
    CFMutableDictionaryRef matching = IOServiceMatching("IOHIDDevice");
    if (!matching) return "Virtual HID active; registry matching failed.";
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), (__bridge CFDictionaryRef)ownedProperties);
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) return "Virtual HID active; owned device is not yet visible in IOKit.";
    IOHIDDeviceRef hid = IOHIDDeviceCreate(kCFAllocatorDefault, service);
    IOObjectRelease(service);
    if (!hid) return "Owned HID is visible; IOHIDDevice creation failed.";
    const bool supported = [GCController supportsHIDDevice:hid];
    NSString* transport = (__bridge NSString*)IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDTransportKey));
    std::ostringstream result;
    result << "Owned HID visible. GameController supportsHIDDevice=" << (supported ? "yes" : "no")
        << "; connected GCController count=" << [GCController controllers].count << " (all devices)."
        << " Published transport=" << (transport.UTF8String ?: "unknown") << "."
        << " Input in a Mac game remains unverified.";
    CFRelease(hid);
    return result.str();
}

} // namespace Wolverine
