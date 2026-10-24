#!/usr/bin/env python3
"""Choose a Command Line Tools SDK supported by the available Swift macro plugins."""
import os
from pathlib import Path
import subprocess


def select_sdk():
    explicit = os.environ.get('SDKROOT', '')
    if explicit and not explicit.startswith('/Library/Developer/CommandLineTools/SDKs/'):
        return None
    sdk_dir = Path('/Library/Developer/CommandLineTools/SDKs')
    if not sdk_dir.is_dir():
        return None
    try:
        swiftc = Path(subprocess.check_output(['/usr/bin/xcrun', '--find', 'swiftc'], text=True).strip())
    except (OSError, subprocess.CalledProcessError):
        return None
    toolchain = swiftc.parent.parent.parent
    macro = toolchain / 'lib/swift/host/plugins/libSwiftUIMacros.dylib'
    candidates = []
    for sdk in sdk_dir.glob('MacOSX*.sdk'):
        version = sdk.name.removeprefix('MacOSX').removesuffix('.sdk')
        if not version or not all(part.isdigit() for part in version.split('.')):
            continue
        module = sdk / 'System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule'
        if not module.is_dir():
            continue
        try:
            needs_macro = any(b'type: "StateMacro"' in file.read_bytes() for file in module.glob('*.swiftinterface'))
        except OSError:
            continue
        if needs_macro and not macro.exists():
            continue
        candidates.append((tuple(int(part) for part in version.split('.')), sdk))
    return max(candidates, default=(None, None))[1]


if __name__ == '__main__':
    chosen = select_sdk()
    if chosen:
        print(chosen)
