#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tools_dir="$repo_root/.build/sparkle-tools-2.10.0"
if [[ ! -x "$tools_dir/bin/generate_appcast" ]]; then
    archive="$(mktemp)"
    trap 'rm -f "$archive"' EXIT
    curl -fsSL --max-time 120 https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz -o "$archive"
    [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c ]] || { echo "Sparkle download checksum mismatch." >&2; exit 1; }
    mkdir -p "$tools_dir"
    tar -xJf "$archive" -C "$tools_dir"
fi
echo "$tools_dir/bin"
