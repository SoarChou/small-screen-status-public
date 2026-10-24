#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
app_dir="$project_dir/build/Small Screen Status.app"
staging="$project_dir/build/.Small Screen Status.app.staging.$$"
previous="$project_dir/build/.Small Screen Status.app.previous"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources/Scripts" "$staging/Contents/Resources/Tools"
sdk="$(/usr/bin/python3 "$project_dir/scripts/select_sdk.py")"
sdk_args=()
if [[ -n "$sdk" ]]; then sdk_args=(-sdk "$sdk"); export SDKROOT="$sdk"; print "Using SDK: $sdk"; fi
/usr/bin/swiftc -O -target "$(uname -m)-apple-macos13.0" "${sdk_args[@]}" "$project_dir"/src/app/*.swift -o "$staging/Contents/MacOS/SmallScreenStatus" -framework Cocoa -framework SwiftUI -framework Carbon
/usr/bin/swiftc -O -target "$(uname -m)-apple-macos13.0" "${sdk_args[@]}" "$project_dir/src/launcher/ChatGPTLauncher.swift" -o "$staging/Contents/Resources/Tools/ChatGPTSmallScreenLauncher" -framework Cocoa
cp "$project_dir"/src/cli/*.py "$project_dir/src/config/widgets.json" "$staging/Contents/Resources/Scripts/"
cp "$project_dir/src/config/widgets.json" "$staging/Contents/Resources/widgets.json"
cp "$project_dir/docs/EXTENSIONS.md" "$staging/Contents/Resources/EXTENSIONS.md"
cp "$project_dir/assets/AppIcon.icns" "$staging/Contents/Resources/AppIcon.icns"
cat > "$staging/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SmallScreenStatus</string>
<key>CFBundleIdentifier</key><string>local.soar.small-screen-status</string>
<key>CFBundleName</key><string>Small Screen Status</string>
<key>CFBundleDisplayName</key><string>Small Screen Status</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$staging"
rm -rf "$previous"
if [[ -d "$app_dir" ]]; then mv "$app_dir" "$previous"; fi
if ! mv "$staging" "$app_dir"; then
    if [[ -d "$previous" ]]; then mv "$previous" "$app_dir"; fi
    exit 1
fi
rm -rf "$previous"
cp "$app_dir/Contents/Resources/Tools/ChatGPTSmallScreenLauncher" "$project_dir/build/ChatGPTSmallScreenLauncher"
print "$app_dir"
