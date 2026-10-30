#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'XcodeGen fehlt: brew install xcodegen'; exit 1; }
xcodegen generate
xcodebuild -resolvePackageDependencies -project AniLounge.xcodeproj -scheme AniLounge
xcodebuild -project AniLounge.xcodeproj -scheme AniLounge \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  build
app_path='build/DerivedData/Build/Products/Release-iphoneos/AniLounge.app'
test -f "$app_path/AniLounge"
# Ad-hoc signature for packaging; TrollStore performs the installation signing.
if [ -d "$app_path/Frameworks" ]; then
  for framework in "$app_path"/Frameworks/*.framework "$app_path"/Frameworks/*.dylib; do
    [ -e "$framework" ] || continue
    codesign --force --sign - --timestamp=none "$framework"
  done
fi
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict "$app_path"
mkdir -p build/package/Payload
ditto "$app_path" build/package/Payload/AniLounge.app
(cd build/package && /usr/bin/zip -qry ../AniLounge.ipa Payload)
python3 scripts/validate-ipa.py build/AniLounge.ipa
