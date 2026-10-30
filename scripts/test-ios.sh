#!/usr/bin/env bash
set -euo pipefail
xcodegen generate
simulator_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime,items in devices.items() if "iOS" in runtime for d in items if d["name"].startswith("iPhone")))')
xcodebuild test -project AniLounge.xcodeproj -scheme AniLounge -destination "platform=iOS Simulator,id=$simulator_id" -only-testing:AniLoungeTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
