#include "WolverineUSB.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <mach/mach_error.h>

#include <array>
#include <atomic>
#include <chrono>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <thread>
#include <utility>

namespace Wolverine {
namespace {

constexpr UInt16 kVendor = 0x1532;
constexpr UInt16 kWiredProduct = 0x0a57;
using Device = IOUSBDeviceInterface300;
using Interface = IOUSBInterfaceInterface300;

std::string errorText(const char* operation, IOReturn result) {
    std::ostringstream out;
    out << operation << ": " << mach_error_string(result) << " (0x"
        << std::hex << std::setw(8) << std::setfill('0')
        << static_cast<std::uint32_t>(result) << ")";
    if (result == kIOReturnExclusiveAccess || result == kIOReturnNotPermitted) {
        out << ". Another driver/app owns the interface, or macOS denied access.";
    }
    return out.str();
}

template <class T>
IOReturn interfaceForService(io_service_t service, CFUUIDRef type,
                            CFUUIDRef interfaceID, T*** object) {
    IOCFPlugInInterface** plugin = nullptr;
    SInt32 score = 0;
    const IOReturn result = IOCreatePlugInInterfaceForService(
        service, type, kIOCFPlugInInterfaceID, &plugin, &score);
    if (result != kIOReturnSuccess) return result;
    const HRESULT query = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(interfaceID), reinterpret_cast<LPVOID*>(object));
    IODestroyPlugInInterface(plugin);
    return query == S_OK && *object ? kIOReturnSuccess : kIOReturnUnsupported;
}

void matchNumber(CFMutableDictionaryRef match, CFStringRef key, int value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    CFDictionarySetValue(match, key, number);
    CFRelease(number);
}

IOReturn matchingRazer(bool wiredOnly, io_iterator_t* iterator) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return kIOReturnNoMemory;
    if (wiredOnly) {
        matchNumber(match, CFSTR(kUSBVendorID), kVendor);
        matchNumber(match, CFSTR(kUSBProductID), kWiredProduct);
    }
    return IOServiceGetMatchingServices(kIOMainPortDefault, match, iterator);
}

std::string serviceName(io_service_t service) {
    io_name_t name = {};
    IORegistryEntryGetName(service, name);
    return name;
}

} // namespace

struct USBTransport::Impl {
    std::atomic<bool> stopping{false};
    std::thread worker;
    mutable std::mutex statusMutex;
    USBStatus current;
    PacketHandler packets;
    StatusHandler statuses;
    Interface** interface = nullptr;
    CFRunLoopSourceRef source = nullptr;
    UInt8 inputPipe = 0;
    UInt16 packetSize = 0;
    std::array<std::uint8_t, 64> buffer{};
    bool pending = false;
    bool closing = false;
    IOReturn readError = kIOReturnSuccess;
    std::uint64_t registryID = 0;
    std::uint64_t failedRegistryID = 0;
    std::uint32_t locationID = 0;

    void publish(USBState state, std::string message, std::uint32_t location = 0) {
        USBStatus next{state, std::move(message), location};
        {
            std::lock_guard<std::mutex> lock(statusMutex);
            if (current.state == next.state && current.message == next.message &&
                current.locationID == next.locationID) return;
            current = next;
        }
        if (statuses) statuses(next);
    }

    static void received(void* context, IOReturn result, void* countPointer) {
        auto& self = *static_cast<Impl*>(context);
        self.pending = false;
        if (self.stopping || self.closing) return;
        if (result != kIOReturnSuccess) {
            self.readError = result;
            return;
        }
        const auto count = static_cast<std::size_t>(
            reinterpret_cast<std::uintptr_t>(countPointer));
        if (count > self.buffer.size()) {
            self.readError = kIOReturnOverrun;
            return;
        }
        if (self.packets) self.packets(self.buffer.data(), count);
        self.queueRead();
    }

    bool queueRead() {
        if (stopping || !interface) return false;
        const IOReturn result = (*interface)->ReadPipeAsync(
            interface, inputPipe, buffer.data(), packetSize, received, this);
        if (result != kIOReturnSuccess) {
            readError = result;
            return false;
        }
        pending = true;
        return true;
    }

    void close() {
        closing = true;
        if (interface) {
            if (pending) {
                // Interrupt pipes cannot use IOUSBLib timeout reads.
                // Abort synchronously, then drain the queued completion.
                (*interface)->AbortPipe(interface, inputPipe);
                for (int n = 0; pending && n < 10; ++n) {
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
                }
            }
            if (source) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
                CFRunLoopSourceInvalidate(source);
                CFRelease(source);
                source = nullptr;
            }
            (*interface)->USBInterfaceClose(interface);
            (*interface)->Release(interface);
            interface = nullptr;
        }
        pending = false;
        readError = kIOReturnSuccess;
        inputPipe = 0;
        packetSize = 0;
        registryID = 0;
        locationID = 0;
        closing = false;
    }

    bool open(io_service_t service, std::uint64_t identifier) {
        Device** device = nullptr;
        IOReturn result = interfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                              kIOUSBDeviceInterfaceID300, &device);
        if (result != kIOReturnSuccess) {
            publish(USBState::Error, errorText("Create USB device interface", result));
            return false;
        }
        UInt16 vendor = 0, product = 0;
        UInt8 configuration = 0;
        result = (*device)->GetDeviceVendor(device, &vendor);
        if (result == kIOReturnSuccess) result = (*device)->GetDeviceProduct(device, &product);
        if (result == kIOReturnSuccess) result = (*device)->GetLocationID(device, &locationID);
        if (result == kIOReturnSuccess) result = (*device)->GetConfiguration(device, &configuration);
        if (result != kIOReturnSuccess || vendor != kVendor || product != kWiredProduct ||
            configuration != 1) {
            (*device)->Release(device);
            publish(USBState::Error, result != kIOReturnSuccess
                ? errorText("Read USB device descriptors", result)
                : "Expected wired 1532:0a57 in USB configuration 1; device does not match.");
            return false;
        }

        IOUSBFindInterfaceRequest request{kUSBVendorSpecificClass, 0x5d, 0x01, 0};
        io_iterator_t iterator = IO_OBJECT_NULL;
        result = (*device)->CreateInterfaceIterator(device, &request, &iterator);
        (*device)->Release(device);
        if (result != kIOReturnSuccess) {
            publish(USBState::Error, errorText("Enumerate gamepad USB interface", result));
            return false;
        }

        bool found = false;
        io_service_t candidate = IO_OBJECT_NULL;
        while ((candidate = IOIteratorNext(iterator))) {
            Interface** candidateInterface = nullptr;
            result = interfaceForService(candidate, kIOUSBInterfaceUserClientTypeID,
                                         kIOUSBInterfaceInterfaceID300, &candidateInterface);
            IOObjectRelease(candidate);
            if (result != kIOReturnSuccess) continue;
            UInt8 number = 255, cls = 0, subclass = 0, protocol = 0, alternate = 255;
            UInt16 actualVendor = 0, actualProduct = 0;
            const bool matches =
                (*candidateInterface)->GetInterfaceNumber(candidateInterface, &number) == kIOReturnSuccess &&
                (*candidateInterface)->GetInterfaceClass(candidateInterface, &cls) == kIOReturnSuccess &&
                (*candidateInterface)->GetInterfaceSubClass(candidateInterface, &subclass) == kIOReturnSuccess &&
                (*candidateInterface)->GetInterfaceProtocol(candidateInterface, &protocol) == kIOReturnSuccess &&
                (*candidateInterface)->GetAlternateSetting(candidateInterface, &alternate) == kIOReturnSuccess &&
                (*candidateInterface)->GetDeviceVendor(candidateInterface, &actualVendor) == kIOReturnSuccess &&
                (*candidateInterface)->GetDeviceProduct(candidateInterface, &actualProduct) == kIOReturnSuccess &&
                number == 0 && cls == 0xff && subclass == 0x5d && protocol == 1 &&
                alternate == 0 && actualVendor == kVendor && actualProduct == kWiredProduct;
            if (matches) {
                interface = candidateInterface;
                found = true;
                break;
            }
            (*candidateInterface)->Release(candidateInterface);
        }
        IOObjectRelease(iterator);
        if (!found) {
            publish(USBState::Error, "Wired controller has no accessible interface 0 with class FF/5D/01.");
            return false;
        }

        // Do not seize an interface from another app or driver.
        result = (*interface)->USBInterfaceOpen(interface);
        if (result != kIOReturnSuccess) {
            (*interface)->Release(interface);
            interface = nullptr;
            publish(USBState::Error, errorText("Open gamepad USB interface 0", result));
            return false;
        }
        UInt8 endpoints = 0;
        result = (*interface)->GetNumEndpoints(interface, &endpoints);
        bool outputFound = false;
        for (UInt8 pipe = 1; result == kIOReturnSuccess && pipe <= endpoints; ++pipe) {
            UInt8 direction = 0, number = 0, transfer = 0, interval = 0;
            UInt16 size = 0;
            result = (*interface)->GetPipeProperties(interface, pipe, &direction, &number,
                                                     &transfer, &size, &interval);
            if (result != kIOReturnSuccess) break;
            if (number == 1 && transfer == kUSBInterrupt && interval == 1 && size == 32) {
                if (direction == kUSBIn) { inputPipe = pipe; packetSize = size; }
                if (direction == kUSBOut) outputFound = true;
            }
        }
        if (result != kIOReturnSuccess || !inputPipe || !outputFound) {
            const std::string message = result != kIOReturnSuccess
                ? errorText("Read gamepad endpoint descriptors", result)
                : "Expected interrupt endpoints 81/01, 32 bytes, interval 1; descriptors do not match.";
            close();
            publish(USBState::Error, message);
            return false;
        }

        result = (*interface)->CreateInterfaceAsyncEventSource(interface, &source);
        if (result != kIOReturnSuccess) {
            const std::string message = errorText("Create USB asynchronous event source", result);
            close();
            publish(USBState::Error, message);
            return false;
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
        registryID = identifier;
        if (!queueRead()) {
            const std::string message = errorText("Queue USB interrupt read", readError);
            close();
            publish(USBState::Error, message);
            return false;
        }

        // Original implementation of public Xbox 360 wire protocol facts.
        // Linux xpad.c (xpad_start_input) issues this capabilities/init read:
        // https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c
        // No Linux source code is incorporated here. A stall is permitted by
        // that protocol; actual gamepad input remains the success criterion.
        std::array<UInt8, 20> capabilities{};
        IOUSBDevRequestTO init{};
        init.bmRequestType = 0xc1;
        init.bRequest = 1;
        init.wValue = 0x0100;
        init.wIndex = 0;
        init.wLength = static_cast<UInt16>(capabilities.size());
        init.pData = capabilities.data();
        init.noDataTimeout = 100;
        init.completionTimeout = 100;
        const IOReturn initResult = (*interface)->ControlRequestTO(interface, 0, &init);
        if (initResult != kIOReturnSuccess && initResult != kIOUSBPipeStalled) {
            const std::string message = errorText("Xbox 360 initialization request", initResult);
            close();
            publish(USBState::Error, message);
            return false;
        }
        publish(USBState::Connected,
                initResult == kIOReturnSuccess
                    ? "Connected to wired Wolverine 1532:0a57, interface 0, endpoint 81."
                    : "Connected to wired Wolverine; optional X360 capabilities request stalled.",
                locationID);
        return true;
    }

    void run() {
        publish(USBState::Waiting, "Connect the Wolverine V3 Pro 8K PC directly by USB cable.");
        auto nextScan = std::chrono::steady_clock::now();
        while (!stopping) {
            if (interface && readError != kIOReturnSuccess) {
                const auto failed = registryID;
                const IOReturn result = readError;
                close();
                failedRegistryID = failed;
                if (result == kIOReturnNoDevice || result == kIOReturnNotResponding) {
                    publish(USBState::Waiting, "Controller disconnected. Reconnect the USB cable.");
                } else {
                    publish(USBState::Error, errorText("USB interrupt input", result) +
                            ". Unplug and reconnect the controller to retry.");
                }
            }
            const auto now = std::chrono::steady_clock::now();
            if (now >= nextScan) {
                nextScan = now + std::chrono::seconds(1);
                io_iterator_t iterator = IO_OBJECT_NULL;
                const IOReturn result = matchingRazer(true, &iterator);
                if (result != kIOReturnSuccess) {
                    if (interface) close();
                    publish(USBState::Error, errorText("Enumerate wired Wolverine USB device", result));
                } else {
                    io_service_t device = IOIteratorNext(iterator);
                    std::uint64_t identifier = 0;
                    if (device) IORegistryEntryGetRegistryEntryID(device, &identifier);
                    IOObjectRelease(iterator);
                    if (!device) {
                        if (interface) close();
                        failedRegistryID = 0;
                        publish(USBState::Waiting, "No wired Wolverine 1532:0a57 is connected.");
                    } else {
                        if (interface && identifier != registryID) close();
                        if (!interface && identifier != failedRegistryID) {
                            if (!open(device, identifier)) failedRegistryID = identifier;
                        }
                        IOObjectRelease(device);
                    }
                }
            }
            // At most 100 ms until observing stop, even if no reports arrive.
            const SInt32 loopResult = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
            if (loopResult == kCFRunLoopRunFinished) {
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
        }
        close();
        publish(USBState::Stopped, "USB transport is stopped.");
    }
};

USBTransport::USBTransport() : impl_(std::make_unique<Impl>()) {}
USBTransport::~USBTransport() { stop(); }

bool USBTransport::start(PacketHandler packets, StatusHandler statuses) {
    if (impl_->worker.joinable() || !packets) return false;
    impl_->packets = std::move(packets);
    impl_->statuses = std::move(statuses);
    impl_->stopping = false;
    impl_->failedRegistryID = 0;
    impl_->worker = std::thread([this] { impl_->run(); });
    return true;
}

void USBTransport::stop() {
    impl_->stopping = true;
    if (impl_->worker.joinable()) impl_->worker.join();
}

USBStatus USBTransport::status() const {
    std::lock_guard<std::mutex> lock(impl_->statusMutex);
    return impl_->current;
}

std::string USBTransport::diagnostics() {
    std::ostringstream out;
    io_iterator_t iterator = IO_OBJECT_NULL;
    const IOReturn enumerate = matchingRazer(false, &iterator);
    if (enumerate != kIOReturnSuccess) return errorText("Enumerate Razer USB devices", enumerate);
    int count = 0;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator))) {
        Device** device = nullptr;
        const IOReturn result = interfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                    kIOUSBDeviceInterfaceID300, &device);
        const std::string name = serviceName(service);
        IOObjectRelease(service);
        if (result != kIOReturnSuccess) {
            continue;
        }
        UInt16 vendor = 0, product = 0;
        UInt32 location = 0;
        UInt8 configuration = 0;
        (*device)->GetDeviceVendor(device, &vendor);
        (*device)->GetDeviceProduct(device, &product);
        (*device)->GetLocationID(device, &location);
        (*device)->GetConfiguration(device, &configuration);
        if (vendor != kVendor) {
            (*device)->Release(device);
            continue;
        }
        ++count;
        out << name << '\n';
        out << "  VID:PID " << std::hex << std::setw(4) << std::setfill('0')
            << vendor << ':' << std::setw(4) << product << ", location 0x"
            << std::setw(8) << location << std::dec << ", configuration "
            << static_cast<int>(configuration) << '\n';
        IOUSBFindInterfaceRequest request{kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                         kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
        io_iterator_t interfaces = IO_OBJECT_NULL;
        const IOReturn found = (*device)->CreateInterfaceIterator(device, &request, &interfaces);
        if (found == kIOReturnSuccess) {
            io_service_t entry = IO_OBJECT_NULL;
            while ((entry = IOIteratorNext(interfaces))) {
                Interface** interface = nullptr;
                const IOReturn query = interfaceForService(entry, kIOUSBInterfaceUserClientTypeID,
                                                           kIOUSBInterfaceInterfaceID300, &interface);
                IOObjectRelease(entry);
                if (query != kIOReturnSuccess) {
                    out << "  " << errorText("Read USB interface", query) << '\n';
                    continue;
                }
                UInt8 number = 0, cls = 0, subclass = 0, protocol = 0, alternate = 0;
                (*interface)->GetInterfaceNumber(interface, &number);
                (*interface)->GetInterfaceClass(interface, &cls);
                (*interface)->GetInterfaceSubClass(interface, &subclass);
                (*interface)->GetInterfaceProtocol(interface, &protocol);
                (*interface)->GetAlternateSetting(interface, &alternate);
                out << "  Interface " << static_cast<int>(number) << ", alternate "
                    << static_cast<int>(alternate) << ", class " << std::hex
                    << std::setw(2) << static_cast<int>(cls) << '/'
                    << std::setw(2) << static_cast<int>(subclass) << '/'
                    << std::setw(2) << static_cast<int>(protocol) << std::dec << '\n';
                if (number == 0 && cls == 0xff && subclass == 0x5d && protocol == 1) {
                    for (UInt8 direction : {static_cast<UInt8>(kUSBIn), static_cast<UInt8>(kUSBOut)}) {
                        UInt8 transfer = 0, interval = 0;
                        UInt16 size = 0;
                        const IOReturn endpoint = (*interface)->GetEndpointProperties(
                            interface, alternate, 1, direction, &transfer, &size, &interval);
                        if (endpoint == kIOReturnSuccess) {
                            out << "    Endpoint " << (direction == kUSBIn ? "81 IN" : "01 OUT")
                                << ", transfer " << static_cast<int>(transfer)
                                << ", max packet " << size << ", interval "
                                << static_cast<int>(interval) << '\n';
                        } else out << "    " << errorText("Read endpoint descriptor", endpoint) << '\n';
                    }
                }
                (*interface)->Release(interface);
            }
            IOObjectRelease(interfaces);
        } else out << "  " << errorText("Enumerate interfaces", found) << '\n';
        (*device)->Release(device);
    }
    IOObjectRelease(iterator);
    if (!count) out << "No Razer USB devices found. Connect the controller with a USB data cable.\n";
    return out.str();
}

} // namespace Wolverine
