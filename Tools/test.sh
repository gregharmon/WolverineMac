#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/wolverine-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I "$task_root/Sources" "$task_root/Sources/ControllerState.cpp" \
  "$task_root/Tests/ControllerStateTests.cpp" -o "$task_temp/controller-tests"
"$task_temp/controller-tests"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fobjc-arc -fsanitize=address,undefined \
    -framework Foundation -framework IOKit -framework GameController -framework Security \
    -I "$task_root/Sources" "$task_root/Sources/ControllerState.cpp" \
    "$task_root/Sources/VirtualGamepad.mm" "$task_root/Tests/VirtualReportTests.mm" \
    -o "$task_temp/virtual-tests"
"$task_temp/virtual-tests"
