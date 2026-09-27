#!/bin/zsh
# Crash hunting (CI_TEST_CMD=scripts/ci/lldb-tests.sh, or the ci.yml `lldb` dispatch input): runs
# the Swift Testing bundle the way `swift test` does, under lldb, and prints every thread's native
# backtrace if the process crashes. Arguments are passed to the test runner (--filter/--skip).
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --build-tests >/dev/null
bundle=$(swift build --show-bin-path)/denPackageTests.xctest/Contents/MacOS/denPackageTests
helper=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
[[ -x $helper && -f $bundle ]] || { echo "no $helper or $bundle"; exit 2; }
# What `swift test` adds: Testing.framework / XCTest live in the platform's developer dirs.
platform=$(xcode-select -p)/Platforms/MacOSX.platform/Developer
out=$(mktemp)
lldb --batch \
  -o "settings set target.env-vars DYLD_FRAMEWORK_PATH=$platform/Library/Frameworks DYLD_LIBRARY_PATH=$platform/usr/lib" \
  -o 'settings set target.process.stop-on-exec false' \
  -o 'process handle SIGPIPE -n true -p true -s false' \
  -o run \
  -k 'thread backtrace all' -k 'register read' -k 'quit 1' \
  -- "$helper" --test-bundle-path "$bundle" "$bundle" --testing-library swift-testing "$@" 2>&1 | tee "$out"
# lldb's own status says nothing about the tests: pass only if the process exited 0.
grep -q 'exited with status = 0 ' "$out"
