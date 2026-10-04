#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
app_dir="$project_dir/build/Small Screen Status.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Scripts" "$app_dir/Contents/Resources/Tools"
/usr/bin/swiftc -O -target "$(uname -m)-apple-macos13.0" "$project_dir"/src/app/*.swift -o "$app_dir/Contents/MacOS/SmallScreenStatus" -framework Cocoa -framework SwiftUI -framework Carbon
/usr/bin/swiftc -O -target "$(uname -m)-apple-macos13.0" "$project_dir/src/launcher/ChatGPTLauncher.swift" -o "$project_dir/build/ChatGPTSmallScreenLauncher" -framework Cocoa
cp "$project_dir/build/ChatGPTSmallScreenLauncher" "$app_dir/Contents/Resources/Tools/"
cp "$project_dir"/src/cli/*.py "$project_dir/src/config/widgets.json" "$app_dir/Contents/Resources/Scripts/"
cp "$project_dir/src/config/widgets.json" "$app_dir/Contents/Resources/widgets.json"
cp "$project_dir/docs/EXTENSIONS.md" "$app_dir/Contents/Resources/EXTENSIONS.md"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SmallScreenStatus</string>
<key>CFBundleIdentifier</key><string>local.soar.small-screen-status</string>
<key>CFBundleName</key><string>Small Screen Status</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app_dir"
print "$app_dir"
