#!/bin/zsh
# Builds the direct-download Mac app (Developer ID, Sparkle auto-update).
#   ./build.sh            build into build/Depotticker.app
#   ./build.sh install    also copy it to /Applications
#   ./build.sh release    also create the signed (and, if set up, notarized) zip and the update feed
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mode="${1:-}"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Support/Info.plist)
sparkle=.build/artifacts/sparkle/Sparkle/bin

# Sign with the Developer ID certificate when it is in the keychain, otherwise ad hoc.
identity="${DEPOT_SIGN_IDENTITY:-Developer ID Application}"
if security find-identity -v -p codesigning | grep -q "$identity"; then
  sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
else
  echo "No '$identity' certificate found, signing ad hoc."
  sign() { codesign --force --sign - "$@"; }
fi

swift build -c release
products=$(swift build -c release --show-bin-path)

if [[ ! -f Support/AppIcon.icns ]]; then
  swift Scripts/make-icon.swift Support/icon-1024.png
  set=Support/AppIcon.iconset
  mkdir -p "$set"
  for s in 16 32 128 256 512; do
    sips -z $s $s Support/icon-1024.png --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Support/icon-1024.png --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o Support/AppIcon.icns
  rm -r "$set" Support/icon-1024.png
fi

app=build/Depotticker.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$products/Depotticker" "$app/Contents/MacOS/Depotticker"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
ditto "$products/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# The public half of the update-signing key; the private half stays in the login keychain.
sed "s|__SPARKLE_PUBLIC_KEY__|$($sparkle/generate_keys -p)|" Support/Info.plist > "$app/Contents/Info.plist"

# Widget extension (small, medium and large desktop widgets).
appex="$app/Contents/PlugIns/DepottickerWidget.appex"
mkdir -p "$appex/Contents/MacOS"
swiftc -O -D DIRECT -target arm64-apple-macos26.0 -swift-version 5 -parse-as-library -application-extension \
  -module-name DepottickerWidget -Xlinker -e -Xlinker _NSExtensionMain \
  Sources/Depotticker/Models.swift Sources/Depotticker/Yahoo.swift Sources/Depotticker/Format.swift \
  Sources/Depotticker/MarketData.swift Sources/Depotticker/EODHD.swift Sources/Depotticker/ECB.swift \
  Widget/DepotWidget.swift -o "$appex/Contents/MacOS/DepottickerWidget"
cp Widget/Info.plist "$appex/Contents/Info.plist"

# Sign from the inside out.
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$framework/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$framework/XPCServices/Downloader.xpc"
sign "$framework/Autoupdate"
sign "$framework/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements Widget/Widget.entitlements "$appex"
sign "$app"
codesign --verify --deep --strict "$app"

if [[ "$mode" == "install" ]]; then
  pkill -x Depotticker 2>/dev/null || true
  rm -rf /Applications/Depotticker.app
  ditto "$app" /Applications/Depotticker.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Depotticker.app
  echo "Installed /Applications/Depotticker.app"
fi

if [[ "$mode" == "release" ]]; then
  zip="build/Depotticker-$version.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  # Notarize when credentials were stored with:
  #   xcrun notarytool store-credentials depotticker-notary --apple-id <id> --team-id <team> --password <app-specific password>
  if xcrun notarytool history --keychain-profile depotticker-notary >/dev/null 2>&1; then
    xcrun notarytool submit "$zip" --keychain-profile depotticker-notary --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    echo "Notarized."
  else
    echo "NOT notarized: no 'depotticker-notary' keychain profile. Gatekeeper will warn on other Macs."
  fi
  # The update-signing key is read from a private file when present (no keychain prompt), else from the keychain.
  keyfile="$HOME/.config/depotticker/sparkle-private-key"
  if [[ -s "$keyfile" ]]; then
    signature=$($sparkle/sign_update --ed-key-file "$keyfile" "$zip")
  else
    signature=$($sparkle/sign_update "$zip")
  fi
  cat > site/public/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Depotticker</title>
    <link>https://depotticker.com/appcast.xml</link>
    <item>
      <title>Version $version</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/dottenbr/depotticker/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/dottenbr/depotticker/releases/download/v$version/Depotticker-$version.zip" type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
  # GitHub Pages keeps a copy at the address version 0.1 looks for its updates.
  cp site/public/appcast.xml docs/appcast.xml
  printf '{ "version": "%s" }\n' "$version" > site/src/release.json
  echo "Release archive: $zip"
  echo "Next: publish the GitHub release, then deploy the website (pnpm --dir site run deploy)."
fi
