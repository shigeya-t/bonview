#!/bin/zsh
# Generate and build the iOS / iPadOS app.
#   scripts/build_ios.sh                     FFmpeg for iOS (once) + iOS/BonView-iOS.xcodeproj + Simulator build
#   DESTINATION=device scripts/build_ios.sh  build for devices (DEVELOPMENT_TEAM=… for signing)
#   GENERATE_ONLY=1 scripts/build_ios.sh     stop after generating the Xcode project (open it in Xcode)
# Requires XcodeGen (`brew install xcodegen`). Output: build/ios/Build/Products/*/BonView.app
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }
scripts/build_ffmpeg_ios.sh
DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-} xcodegen generate --spec iOS/project.yml --quiet
echo "iOS/BonView-iOS.xcodeproj"
[[ -n "${GENERATE_ONLY:-}" ]] && exit 0

if [[ "${DESTINATION:-simulator}" == device ]]; then
  DEST=(-destination 'generic/platform=iOS')
  SIGN=()
  [[ -z "${DEVELOPMENT_TEAM:-}" ]] && SIGN=(CODE_SIGNING_ALLOWED=NO)
else
  DEST=(-destination 'generic/platform=iOS Simulator')
  SIGN=()
fi
xcodebuild -project iOS/BonView-iOS.xcodeproj -scheme BonViewiOS -configuration "${CONFIG:-Debug}" \
  "${DEST[@]}" -derivedDataPath build/ios -quiet "${SIGN[@]}" build
ls -d build/ios/Build/Products/*/BonView.app
