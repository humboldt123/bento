#!/bin/zsh
# Archive Bento and upload it to App Store Connect for TestFlight.
#   scripts/testflight.sh
# Needs: Xcode signed into the Apple account whose team is DEVELOPMENT_TEAM in Config.xcconfig,
# and the app created once in App Store Connect with bundle id <BUNDLE_ID_PREFIX>.bento.
set -euo pipefail
cd "$(dirname "$0")/.."

team=$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' Config.xcconfig)
[[ -n "$team" ]] || { echo "Set DEVELOPMENT_TEAM in Config.xcconfig"; exit 1; }
build=$(date +%Y%m%d%H%M)   # every upload needs a new build number
out=build-testflight

xcodegen generate -q
rm -rf "$out"
xcodebuild -project Bento.xcodeproj -scheme Bento -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/Bento.xcarchive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" archive -quiet

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$out/Bento.xcarchive" -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export" -allowProvisioningUpdates
echo "Uploaded build $build. It shows up in TestFlight after Apple finishes processing (usually 5–15 min)."
