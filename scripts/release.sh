#!/bin/zsh

set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "Usage: zsh scripts/release.sh X.Y.Z" >&2
    exit 1
fi
tag="v$version"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
notes_path="$repo_root/docs/releases/$tag.md"
package_root="$repo_root/output/package"
app_name="Focus Island"
sign_identity="${OPEN_ISLAND_SIGN_IDENTITY:-Open Island Dev Local}"

cd "$repo_root"

[[ "$version" == "$(cat VERSION)" ]] || { echo "Update VERSION to $version before releasing." >&2; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "Release from main only." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean — commit first." >&2; exit 1; }
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main differs from origin/main — push or pull first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "Tag $tag already exists." >&2
    exit 1
fi
if [[ ! -f "$notes_path" ]]; then
    echo "Missing release notes: docs/releases/$tag.md (first line: # Focus Island $tag — Title)" >&2
    exit 1
fi
sparkle_tools="$(zsh scripts/sparkle-tools.sh)"
[[ "$("$sparkle_tools/generate_keys" --account focus-island -p)" == "$(cat config/packaging/sparkle-public-key.txt)" ]] || {
    echo "The Focus Island update signing key is missing or does not match the committed public key." >&2
    exit 1
}
if [[ "$sign_identity" == "-" ]]; then
    sign_identity=""
elif ! security find-identity -p codesigning -v | grep -q "\"$sign_identity\""; then
    echo "Signing identity \"$sign_identity\" not found — run: zsh scripts/setup-dev-signing.sh" >&2
    exit 1
fi

title="$(head -n 1 "$notes_path" | sed -e 's/^#[[:space:]]*//')"
body_path="$(mktemp)"
tail -n +2 "$notes_path" > "$body_path"
trap 'rm -f "$body_path"' EXIT

bin/test.dev

OPEN_ISLAND_UNIVERSAL=true \
OPEN_ISLAND_VERSION="$version" \
OPEN_ISLAND_SIGN_IDENTITY="$sign_identity" \
    zsh scripts/package-app.sh

appcast_dir="$package_root/appcast"
rm -rf "$appcast_dir"
mkdir -p "$appcast_dir"
cp "$package_root/$app_name.zip" "$appcast_dir/Focus.Island.zip"
cp "$notes_path" "$appcast_dir/Focus.Island.md"
"$sparkle_tools/generate_appcast" --account focus-island --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/mpakus/focus-island/releases/download/$tag/" \
    --link "https://github.com/mpakus/focus-island/releases/tag/$tag" "$appcast_dir"

git tag -a "$tag" -m "$title"
git push origin "$tag"

gh release create "$tag" \
    "$package_root/$app_name.dmg" \
    "$package_root/$app_name.zip" \
    "$appcast_dir/appcast.xml" \
    --title "$title" \
    --notes-file "$body_path" \
    --verify-tag

echo "Released $tag"
