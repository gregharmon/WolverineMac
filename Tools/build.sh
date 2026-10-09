#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_app="$task_root/Wolverine Mac.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -fobjc-arc -mmacosx-version-min=15.0 \
  -framework Cocoa -framework IOKit -framework CoreFoundation -framework GameController -framework Security \
  "$task_root/Sources/ControllerState.cpp" "$task_root/Sources/WolverineUSB.mm" \
  "$task_root/Sources/VirtualGamepad.mm" "$task_root/Sources/main.mm" \
  -o "$task_app/Contents/MacOS/WolverineMac"
cp "$task_root/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/THIRD_PARTY_NOTICES.txt" "$task_app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
rm -f "$task_app/Contents/Resources/README.txt"
cp "$task_root/README.md" "$task_app/Contents/Resources/README.md"
rm -f "$task_app/Contents/embedded.provisionprofile"
# Diagnostic build only. Restricted driver entitlements must come from an
# approved Apple profile through sign_with_profile.py, never ad hoc signing.
codesign --force --sign - "$task_app"
codesign --verify --strict "$task_app"
echo "Built diagnostic app: $task_app"
