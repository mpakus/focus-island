#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_dir="${1:?Expected app bundle path}"
identity="${2:--}"
framework="$repo_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework" ]] || { echo "Resolve the Sparkle Swift package before packaging." >&2; exit 1; }
mkdir -p "$bundle_dir/Contents/Frameworks" "$bundle_dir/Contents/Resources"
cp "$repo_root/config/packaging/Sparkle-LICENSE" "$bundle_dir/Contents/Resources/Sparkle-LICENSE"
rm -rf "$bundle_dir/Contents/Frameworks/Sparkle.framework"
ditto "$framework" "$bundle_dir/Contents/Frameworks/Sparkle.framework"
framework="$bundle_dir/Contents/Frameworks/Sparkle.framework"
for component in "$framework/Versions/B/XPCServices/Downloader.xpc" \
                 "$framework/Versions/B/XPCServices/Installer.xpc" \
                 "$framework/Versions/B/Autoupdate" \
                 "$framework/Versions/B/Updater.app" "$framework"; do
    codesign --force --options runtime --sign "$identity" "$component"
done
