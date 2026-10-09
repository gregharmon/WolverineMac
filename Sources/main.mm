#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <Security/SecTask.h>
#include "ControllerState.h"
#include "WolverineUSB.h"
#include "VirtualGamepad.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <sstream>

using namespace Wolverine;
static bool hasVirtualPermission() {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return false;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.hid.virtual.device"), nullptr);
    const bool allowed = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
    CFRelease(task);
    return allowed;
}
static const char *signingBlock =
    "Gamepad output is blocked: this app needs Apple's HID Virtual Device approval "
    "and a matching signed provisioning profile. The included USB input test can run now. "
    "See README.md for the signing step.";

struct Snapshot {
    X360State state;
    uint64_t packets = 0, ignored = 0, forwarded = 0;
    uint16_t buttonsSeen = 0;
    int16_t minimum[4] = {}, maximum[4] = {};
    uint8_t triggerMaximum[2] = {};
    bool virtualActive = false;
    std::string error;
};

// GUI and CLI use this same driver lifecycle. USB callbacks own publication;
// the display reads snapshots without changing or coalescing controller input.
class Runtime {
    USBTransport usb;
    VirtualGamepad gamepad;
    mutable std::mutex mutex;
    Snapshot latest;
    bool driver = false;
public:
    ~Runtime() { stop(); }
    bool start(bool asDriver, std::string &error) {
        stop();
        if (asDriver && !hasVirtualPermission()) { error = signingBlock; return false; }
        driver = asDriver;
        { std::lock_guard<std::mutex> lock(mutex); latest = {}; }
        const bool ok = usb.start([this](const uint8_t *bytes, size_t length) {
            X360State state;
            std::lock_guard<std::mutex> lock(mutex);
            if (!decodePacket(bytes,length,state)) { ++latest.ignored; return; }
            latest.state = state;
            latest.buttonsSeen |= state.buttons;
            const int16_t axes[] = {state.lx,state.ly,state.rx,state.ry};
            for (int i=0;i<4;++i) {
                if (latest.packets == 0) latest.minimum[i] = latest.maximum[i] = axes[i];
                latest.minimum[i] = std::min(latest.minimum[i],axes[i]);
                latest.maximum[i] = std::max(latest.maximum[i],axes[i]);
            }
            latest.triggerMaximum[0] = std::max(latest.triggerMaximum[0],state.leftTrigger);
            latest.triggerMaximum[1] = std::max(latest.triggerMaximum[1],state.rightTrigger);
            ++latest.packets;
            if (driver && latest.error.empty() && gamepad.active()) {
                std::string failure;
                if (gamepad.publish(state,failure)) ++latest.forwarded;
                else latest.error = failure;
            }
        },[this](const USBStatus &status) {
            std::lock_guard<std::mutex> lock(mutex);
            if (status.state != USBState::Connected) latest.state = {};
            if (!driver) return;
            if (status.state == USBState::Connected && latest.error.empty()) {
                std::string failure;
                if (!gamepad.create(failure)) latest.error = failure;
            } else if (status.state != USBState::Connected) {
                gamepad.destroy();
            }
            latest.virtualActive = gamepad.active();
        });
        if (!ok) { error = "Could not start the USB reader."; return false; }
        return true;
    }
    void stop() { usb.stop(); std::lock_guard<std::mutex> lock(mutex); gamepad.destroy(); latest.virtualActive = false; }
    USBStatus status() const { return usb.status(); }
    Snapshot snapshot() const { std::lock_guard<std::mutex> lock(mutex); return latest; }
    std::string diagnostics() { std::lock_guard<std::mutex> lock(mutex); return gamepad.diagnostics(); }
};

static void printSummary(const Snapshot &s) {
    std::printf("Valid USB input packets: %llu\nIgnored status/unknown packets: %llu\nForwarded input states: %llu\n",
        (unsigned long long)s.packets,(unsigned long long)s.ignored,(unsigned long long)s.forwarded);
    X360State seen; seen.buttons = s.buttonsSeen;
    std::printf("Controls exercised: %s\n",describeState(seen).substr(0,describeState(seen).find('\n')).c_str());
    const char *names[] = {"LX","LY","RX","RY"};
    for(int i=0;i<4;++i) std::printf("%s observed range: %d .. %d\n",names[i],s.minimum[i],s.maximum[i]);
    std::printf("Maximum triggers: %u, %u\n",s.triggerMaximum[0],s.triggerMaximum[1]);
}
static volatile std::sig_atomic_t interrupted = 0;
static void interruptHandler(int) { interrupted = 1; }
static int runCLI(int argc, const char *argv[]) {
    const std::string command = argv[1];
    if (command == "--diagnose") {
        std::printf("HID Virtual Device entitlement: %s\n",hasVirtualPermission()?"present":"missing");
        std::printf("%s",USBTransport::diagnostics().c_str());
        std::printf("Existing Apple GameController count: %lu\n",(unsigned long)GCController.controllers.count);
        for(GCController *controller in GCController.controllers)
            std::printf("Existing Apple GameController: %s; extended gamepad: %s\n",
                controller.vendorName.UTF8String,controller.extendedGamepad?"yes":"no");
        return 0;
    }
    if (command != "--capture" && command != "--run") {
        std::fprintf(stderr,"Usage: WolverineMac [--diagnose | --capture [seconds] | --run]\n"); return 64;
    }
    const bool driver = command == "--run";
    double duration = driver ? 0 : 30;
    if (argc > 2) {
        char *end = nullptr; duration = std::strtod(argv[2],&end);
        if (driver || !end || *end || !std::isfinite(duration) || duration < 1 || duration > 300) {
            std::fprintf(stderr,"Capture duration must be between 1 and 300 seconds.\n"); return 64;
        }
    }
    Runtime runtime;
    std::string error;
    if (!runtime.start(driver,error)) { std::fprintf(stderr,"%s\n",error.c_str()); return 3; }
    std::signal(SIGINT,interruptHandler); std::signal(SIGTERM,interruptHandler);
    std::puts(driver?"Driver started. Press Ctrl-C to stop.":"USB input test started. Move both sticks, pull both triggers, and press buttons.");
    std::fflush(stdout);
    const auto start = std::chrono::steady_clock::now();
    std::string previousStatus;
    while (!interrupted) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false);
        const auto status = runtime.status();
        if (status.message != previousStatus) {
            std::printf("%s\n",status.message.c_str()); previousStatus = status.message; std::fflush(stdout);
        }
        const auto snapshot = runtime.snapshot();
        if (!snapshot.error.empty() || status.state == USBState::Error) {
            std::fprintf(stderr,"%s\n",snapshot.error.empty()?status.message.c_str():snapshot.error.c_str());
            runtime.stop(); return 4;
        }
        if (duration && std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count() >= duration) break;
    }
    const auto snapshot = runtime.snapshot();
    if (driver) std::printf("%s\n",runtime.diagnostics().c_str());
    runtime.stop();
    printSummary(snapshot);
    if (!snapshot.packets) {
        std::fprintf(stderr,"No input packets received. This controller sends changes; move a control during the test.\n");
        return 5;
    }
    return 0;
}

@interface AppDelegate : NSObject <NSApplicationDelegate,NSWindowDelegate>
@end
@implementation AppDelegate {
    NSWindow *_window;
    NSTextField *_status, *_input, *_counts;
    NSTimer *_timer;
    std::unique_ptr<Runtime> _runtime;
    BOOL _running;
    NSString *_message;
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.frame = frame; field.font = [NSFont systemFontOfSize:size];
    [_window.contentView addSubview:field]; return field;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _runtime = std::make_unique<Runtime>();
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,650,470)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Wolverine Mac"; _window.delegate = self;
    _window.releasedWhenClosed = NO;
    [_window center];
    [self label:@"Wolverine V3 Pro 8K PC" frame:NSMakeRect(24,417,602,30) size:22];
    _status = [self label:@"Ready." frame:NSMakeRect(24,313,602,93) size:14];
    _input = [self label:@"No input received." frame:NSMakeRect(24,159,602,140) size:16];
    _input.font = [NSFont monospacedSystemFontOfSize:16 weight:NSFontWeightRegular];
    _counts = [self label:@"Connect by USB, then test the input." frame:NSMakeRect(24,119,602,35) size:13];
    NSArray *titles = @[@"Start gamepad driver",@"Test USB input",@"Stop"];
    SEL actions[] = {@selector(startDriver:),@selector(startMonitor:),@selector(stopRuntime:)};
    CGFloat x = 24;
    for(NSUInteger i=0;i<titles.count;++i) {
        NSButton *button = [NSButton buttonWithTitle:titles[i] target:self action:actions[i]];
        button.frame = NSMakeRect(x,65,i==0?190:i==1?150:90,32);
        [_window.contentView addSubview:button]; x += button.frame.size.width+12;
    }
    [self label:@"USB input test reads your controls. Gamepad output requires approved Apple signing."
        frame:NSMakeRect(24,17,602,38) size:12];
    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    if (hasVirtualPermission()) [self startDriver:nil];
    else { _message = @(signingBlock); [self refresh:nil]; }
}
- (void)start:(BOOL)driver {
    std::string error;
    _running = _runtime->start(driver,error);
    _message = _running ? (driver?@"Waiting for controller.":@"USB input test is running.") : [NSString stringWithUTF8String:error.c_str()];
    [self refresh:nil];
}
- (void)startDriver:(id)sender { (void)sender; [self start:YES]; }
- (void)startMonitor:(id)sender { (void)sender; [self start:NO]; }
- (void)stopRuntime:(id)sender { (void)sender; _runtime->stop(); _running = NO; _message = @"Stopped."; [self refresh:nil]; }
- (void)refresh:(id)sender {
    (void)sender;
    const auto s = _runtime->snapshot();
    const auto status = _runtime->status();
    if (_running && (!s.error.empty() || status.state == USBState::Error)) {
        _message = [NSString stringWithUTF8String:s.error.empty()?status.message.c_str():s.error.c_str()];
        _runtime->stop(); _running = NO;
    }
    if (_running) {
        NSString *statusText = [NSString stringWithUTF8String:status.message.c_str()];
        _status.stringValue = [NSString stringWithFormat:@"%@\n%@",statusText,
            s.virtualActive?@"Virtual Xbox gamepad published. Game detection needs verification.":@"No virtual gamepad is currently published."];
    } else _status.stringValue = _message?:@"Stopped.";
    _input.stringValue = s.packets ? [NSString stringWithUTF8String:describeState(s.state).c_str()] : @"No input received. Move a control to send a report.";
    _counts.stringValue = [NSString stringWithFormat:@"Input packets: %llu    Forwarded inputs: %llu    Ignored packets: %llu",
        (unsigned long long)s.packets,(unsigned long long)s.forwarded,(unsigned long long)s.ignored];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [_timer invalidate]; _runtime->stop(); }
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc > 1) return runCLI(argc,argv);
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *applicationItem = [NSMenuItem new];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"Wolverine Mac"];
    [applicationMenu addItemWithTitle:@"Quit Wolverine Mac" action:@selector(terminate:) keyEquivalent:@"q"];
    applicationItem.submenu = applicationMenu;
    [mainMenu addItem:applicationItem]; app.mainMenu = mainMenu;
    AppDelegate *delegate = [AppDelegate new]; app.delegate = delegate;
    [app run];
    return 0;
}}
