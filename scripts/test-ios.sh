#!/usr/bin/env bash
set -euo pipefail
xcodegen generate
mkdir -p build
simulator_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime,items in devices.items() if "iOS" in runtime for d in items if d["name"].startswith("iPhone")))')
# Xcode 16.4 / iOS 18.5 simulator omits libswiftWebKit for older deployment targets.
# Simulator-only workaround: https://bugs.webkit.org/show_bug.cgi?id=293831
# The separate device build retains the project's iOS 16.4 deployment target.
xcodebuild test -resultBundlePath "${TEST_RESULT_BUNDLE:-build/iOS-Tests-$(date +%s).xcresult}" -project AniLounge.xcodeproj -scheme AniLounge -destination "platform=iOS Simulator,id=$simulator_id" -only-testing:AniLoungeTests -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=18.4 CODE_SIGNING_ALLOWED=NO
