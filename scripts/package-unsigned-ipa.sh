#!/usr/bin/env bash
# Builds a DEVICE .app without signing (on a Mac / macOS CI runner) and wraps it
# in the IPA container (Payload/<App>.app) that Windows sideloading tools
# (Sideloadly / AltServer) expect. Those tools re-sign it with your Apple ID
# on Windows. The .ipa produced here is NOT installable by itself — iOS will
# refuse it until Sideloadly/AltStore signs it. That is Apple's rule, not a bug.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
xcodegen generate

DERIVED="$PWD/build/DerivedData"
xcodebuild build \
  -project RelationshipAIKeyboard.xcodeproj \
  -scheme RelationshipAIKeyboard \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

APP="$DERIVED/Build/Products/Release-iphoneos/RelationshipAIKeyboard.app"
[ -d "$APP" ] || { echo "Build product not found: $APP"; exit 1; }

# Sanity: both extensions must be embedded, or the IPA is just the shell app.
for ext in KeyboardExtension.appex BroadcastExtension.appex; do
  [ -d "$APP/PlugIns/$ext" ] || { echo "Missing embedded extension: $ext"; exit 1; }
done

rm -rf build/Payload build/RelationshipAIKeyboard-unsigned.ipa
mkdir -p build/Payload
cp -R "$APP" build/Payload/
( cd build && zip -qry RelationshipAIKeyboard-unsigned.ipa Payload )
echo "Created: build/RelationshipAIKeyboard-unsigned.ipa"
echo "Next (on Windows): open it in Sideloadly, connect the iPhone by USB, sign with your Apple ID, install."
