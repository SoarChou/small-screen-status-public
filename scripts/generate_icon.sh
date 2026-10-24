#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
mkdir -p "$project_dir/build"
sdk="$(/usr/bin/python3 "$project_dir/scripts/select_sdk.py")"
sdk_args=()
if [[ -n "$sdk" ]]; then sdk_args=(-sdk "$sdk"); fi
/usr/bin/swiftc -O "${sdk_args[@]}" "$project_dir/src/app/Brand.swift" "$project_dir/scripts/generate_icon.swift" \
    -o "$project_dir/build/generate_icon" -framework AppKit
"$project_dir/build/generate_icon" "$project_dir/assets/AppIcon.icns" "$project_dir/assets/AppIcon-preview.png"
