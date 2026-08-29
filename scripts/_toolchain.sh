# Pick one Swift toolchain and stick to it. Sourced by the other scripts.
#
# This machine has two: Command Line Tools (Swift 6.0.3, SDK 15.2) which `xcode-select`
# points at, and Xcode 26.6 (Swift 6.3.3, SDK 26.5) which it does not.
#
# Both can build this app. What neither survives is being *mixed*: object files compiled by
# 6.3.3 do not link with the 6.0.3 linker, and the failure is opaque —
#
#   Undefined symbols: _swift_coroFrameAlloc
#   cannot link directly with 'SwiftUICore' because product being built is not an allowed client
#
# which reads like a code problem and is not. Running `swift test` (needs Xcode for XCTest)
# and then `swift build` (defaults to CLT) is enough to produce it, since both share .build.
#
# So: everything uses Xcode when it is present. If it is not, everything uses CLT, and only
# the tests are unavailable.

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
