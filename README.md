# Wolverine Mac

A macOS USB controller bridge for the Razer Wolverine V3 Pro 8K PC.

## Status

USB report delivery was verified with a wired Razer Wolverine V3 Pro 8K PC.
The build script produces a diagnostic app. It cannot yet send gamepad input to games.
Apple must approve the HID Virtual Device capability for this app. A matching
provisioning profile and signature are required. Virtual gamepad output remains unverified.

The source includes the USB reader, input decoder, virtual Xbox gamepad output,
native input-test window, command-line diagnostics, build/tests, and profile
signing helper. Virtual output and input inside Mac games remain unverified.
This is not a released or Razer-supported driver.

## Test the controller

1. Run `./Tools/build.sh`, then open "Wolverine Mac.app" from this folder.
2. Connect the controller directly with a USB data cable.
3. Click "Test USB input".
4. Move both sticks, pull both triggers, and press the buttons and D-pad.
   The window shows the decoded input and received packet count.
5. Click Stop to release the controller interface. Closing the app also stops it.

Only one reader can own the controller interface at a time. Stop this input test
before running command-line capture. The controller sends input changes; zero
packets after opening an idle controller does not measure its polling rate.

## Enable gamepad output

1. Register the macOS App ID org.wolverinemac.WolverineMac in your Apple Developer
   account and request the HID Virtual Device capability:
   https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device
2. After Apple approves the capability, generate a macOS development profile
   for that exact App ID. Include this Mac's provisioning UDID and the Apple
   Development certificate used for signing. A Developer ID profile/identity
   can be used for distribution after any applicable Apple approval.
3. Build, then sign with the approved profile:

   ```sh
   ./Tools/build.sh
   python3 ./Tools/sign_with_profile.py "./Wolverine Mac.app" \
       --profile "/absolute/path/Approved.provisionprofile" \
       --identity "exact Apple Development or Developer ID Application identity"
   ```

   The helper verifies the capability, app/team IDs, expiry, signing certificate,
   and Mac registration before embedding the profile and signing. It refuses
   wildcard, expired, unrelated, or unapproved profiles. Rebuilding replaces the
   app with a diagnostic build, so repeat the signing step after rebuilding.
4. Open the signed app. It starts the gamepad driver automatically. Plugging in
   the wired controller creates a virtual Xbox compatibility gamepad; unplugging
   it removes that virtual device. Reconnection is detected within about a second.
5. Verify both sticks, both triggers, every standard button, Guide, and D-pad in
   an actual Mac game. The game must offer controller input support. Also run
   --run and check its owned-HID/GameController diagnostic when stopping it.
   HID publication alone does not prove Apple GameController, Steam, or game
   compatibility. Apple can change how virtual controllers are handled.

No administrator/root launch is implemented or needed for the verified USB
reader. Root and an ad hoc signature cannot replace Apple's HID capability.

## Development

Requires Xcode command-line tools and the macOS SDK. The current build targets
macOS 15 or later and the local architecture. It builds on Apple Silicon with a
current macOS SDK. No third-party runtime dependencies are installed.

```sh
./Tools/test.sh
"./Wolverine Mac.app/Contents/MacOS/WolverineMac" --diagnose
"./Wolverine Mac.app/Contents/MacOS/WolverineMac" --capture 30
"./Wolverine Mac.app/Contents/MacOS/WolverineMac" --run
```

Capture runs for 1–300 seconds. --run requires the approved signed build and
continues until Ctrl-C. Exit codes: 0 success; 3 missing signing permission;
4 transport/output failure; 5 no input observed; 64 invalid command.

## Scope

The input path matches only wired VID:PID 1532:0a57, configuration 1,
interface 0 FF/5D/01, interrupt endpoints 81/01 (32 bytes, interval 1).
It does not seize another driver or open the keyboard/configuration interfaces.
The known Xbox 360 initialization request reads capabilities; no firmware,
profile, remapping, polling-rate, or device output changes are sent.

The driver preserves standard sticks, analog triggers, face buttons, bumpers,
stick clicks, View/Menu/Guide, and D-pad. Extra paddles/buttons appear only as
their existing hardware assignments in the standard Xbox input report. Their
independent identity and Synapse configuration are not implemented. This build
does not add wireless-dongle support, haptics, audio, or an 8,000 Hz performance
claim. It does not install a login item or system extension.

## Sources and license

USB identifiers and protocol facts:
https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c
https://github.com/openrazer/openrazer/issues/2569
Standard Xbox input parsing:
https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_xbox360.c
https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_xboxone.c
Virtual HID descriptor provenance and license are in THIRD_PARTY_NOTICES.txt.
The USB reader and Xbox 360 decoder are original implementations of protocol
facts; Linux GPL driver code was not incorporated.
Apple's virtual-controller compatibility limits:
https://developer.apple.com/forums/thread/812774

See [VERIFICATION.txt](VERIFICATION.txt) for the checks and remaining hardware tests.
