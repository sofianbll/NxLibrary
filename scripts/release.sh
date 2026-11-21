#!/usr/bin/env bash
# scripts/release.sh <version> [--engine-repo <url> --engine-commit <sha>] [--publish --notes <file>]
#
# Builds a release copy of NX Library (version in its plist, NXLibraryRelease marker, bundled
# runtime), verifies its signature and zips it as work/release/NXLibrary-<version>.zip, the asset
# the app's updater looks for, plus work/release/NXLibrary-<version>.dmg for a first install (the
# DMG must hold the release copy, or that install would never update itself). Nothing leaves
# this Mac unless --publish is given: then the tag v<version> is pushed and a GitHub release is
# created with both files (GitHub computes the zip's digest, which the app checks).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() { echo "usage: scripts/release.sh <version> [--engine-repo <url> --engine-commit <sha>] [--publish --notes <file>]" >&2; exit 2; }

VERSION="${1:-}"
[ -n "$VERSION" ] || usage
shift
PUBLISH=0
NOTES=""
ENGINE_REPO=""
ENGINE_COMMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --notes) shift; NOTES="${1:-}" ;;
    --engine-repo) [ $# -ge 2 ] && [ -n "$2" ] || usage; ENGINE_REPO="$2"; shift ;;
    --engine-commit) [ $# -ge 2 ] && [ -n "$2" ] || usage; ENGINE_COMMIT="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail "the version must be dotted numbers, like 0.2.0"
TAG="v$VERSION"

# Private Google client: published builds never receive these variables.
if [ "$PUBLISH" = "1" ] && [ -n "${ARCANE_GOOGLE_CLIENT_ID+x}${ARCANE_GOOGLE_CLIENT_SECRET+x}" ]; then
  fail "unset ARCANE_GOOGLE_CLIENT_ID and ARCANE_GOOGLE_CLIENT_SECRET before using --publish"
fi
GOOGLE_CLIENT_ID="${ARCANE_GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${ARCANE_GOOGLE_CLIENT_SECRET:-}"
unset ARCANE_GOOGLE_CLIENT_ID ARCANE_GOOGLE_CLIENT_SECRET
PRIVATE=0
if [[ "$GOOGLE_CLIENT_ID" =~ [^[:space:]] && "$GOOGLE_CLIENT_SECRET" =~ [^[:space:]] ]]; then PRIVATE=1; fi

if [ "$PUBLISH" = "1" ]; then
  [ -n "$NOTES" ] && [ -f "$NOTES" ] || fail "--publish needs --notes <file> with the release notes"
  command -v gh >/dev/null || fail "--publish needs the GitHub CLI (gh)"
  REPOSITORY="$(sed -n 's/.*defaultRepository: String? = "\([^"]*\)".*/\1/p' "$ROOT/Sources/NXLibraryCore/App/AppUpdate.swift")"
  [ -n "$REPOSITORY" ] || fail "no public update repository is configured"
  [ "$(gh api "repos/$REPOSITORY" --jq .private)" = "false" ] \
    || fail "the update repository must be publicly accessible before publishing"
fi
[ -z "$(git status --porcelain)" ] || fail "the working tree has changes; commit or stash them first"
if [ "$PRIVATE" = "0" ] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "the tag $TAG already exists"
fi
[ "$(tr -d '[:space:]' < "$ROOT/VERSION")" = "$VERSION" ] || fail "VERSION says $(tr -d '[:space:]' < "$ROOT/VERSION"); set it to $VERSION first"
if [ "$PUBLISH" = "1" ]; then
  # The tag goes on what players can see: the tip of the pushed main branch.
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || fail "HEAD is not origin/main; merge the release into main and push it first"
fi

# Optional tested-engine pin. Validate reachability from a public branch, not merely
# existence as an object in GitHub's fork network. A tip needs no clone.
if [[ -n "$ENGINE_REPO$ENGINE_COMMIT" ]]; then
  [[ "$ENGINE_REPO" =~ ^https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] \
    || fail "--engine-repo must be an HTTPS GitHub repository URL"
  [[ "$ENGINE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || fail "--engine-commit must be the full 40-character lowercase SHA"
  if ! (
    export GIT_TERMINAL_PROMPT=0
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
    heads="$(git ls-remote --exit-code --heads "$ENGINE_REPO")" || exit 1
    if ! awk -v pin="$ENGINE_COMMIT" '$1 == pin { found = 1 } END { exit !found }' <<< "$heads"; then
      probe="$(mktemp -d)" || exit 1
      trap 'rm -rf "$probe"' EXIT
      git clone --quiet --bare --filter=blob:none --no-tags "$ENGINE_REPO" "$probe" || exit 1
      [ -n "$(git -C "$probe" for-each-ref --count=1 --contains="$ENGINE_COMMIT" refs/heads)" ]
    fi
  ); then
    fail "engine commit $ENGINE_COMMIT must be reachable from a public branch of $ENGINE_REPO"
  fi
fi
# Always pass the validated pair (or empty values), never ambient build options.
export NX_ENGINE_REPO="$ENGINE_REPO" NX_ENGINE_COMMIT="$ENGINE_COMMIT"

# Every release is tested from its own tree.
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test --package-path "$ROOT" \
  || fail "swift test failed"
for check in "$ROOT"/Tests/CatalogAppChecks/run_*.py; do
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" python3 "$check" \
    || fail "application regressions failed: ${check##*/}"
done
(cd "$ROOT" && python3 -m unittest discover -s Tests/PublicationChecks >/dev/null 2>&1) \
  || fail "the publication checks' tests failed (python3 -m unittest discover -s Tests/PublicationChecks)"
[ -d "$ROOT/work/Runtime" ] || fail "no work/Runtime: run scripts/bundle_runtime.sh first (a release carries its Python and tools)"
python3 "$ROOT/scripts/check_publication.py" --runtime "$ROOT/work/Runtime"

# What this release needs on a player's Mac, as a hidden line in its notes (AppUpdate.requirements(in:)): the
# update dialog warns about an Xcode to update first and the engine Setup downloads after the restart.
MIN_XCODE="$(sed -n 's/.*minimumXcode: "\([0-9.]*\)".*/\1/p' "$ROOT/Sources/ArcanePorting/Setup/ToolchainRequirements.swift" | head -1)"
ENGINE="${ENGINE_COMMIT:-$(sed -n 's/.*let defaultPinnedEngineCommit = "\([0-9a-f]\{40\}\)".*/\1/p' "$ROOT/Sources/NXLibrary/ViewModels/AppViewModel.swift" | head -1)}"
[ -n "$MIN_XCODE" ] && [ -n "$ENGINE" ] || fail "could not read minimumXcode or defaultPinnedEngineCommit from the sources"
REQUIRES="<!-- nxlibrary-requires xcode=$MIN_XCODE engine=$ENGINE -->"
echo "Requires: Xcode $MIN_XCODE, nxnative ${ENGINE:0:7}"

OUT="$ROOT/work/release"
if [ "$PRIVATE" = "1" ]; then OUT="$ROOT/work/release-private"; fi
APP="$OUT/NXLibrary.app"
ZIP="$OUT/NXLibrary-$VERSION.zip"
rm -rf "$OUT"
mkdir -p "$OUT"

if [ "$PRIVATE" = "1" ]; then
  ARCANE_GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" ARCANE_GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET" \
    NX_VERSION="$VERSION" NX_RELEASE=1 bash "$ROOT/scripts/build_app.sh" "$APP"
else
  NX_VERSION="$VERSION" NX_RELEASE=1 bash "$ROOT/scripts/build_app.sh" "$APP"
fi
unset GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
codesign --verify --deep --strict "$APP"
if [ "$PUBLISH" = "1" ]; then
  /usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
  for key in ArcaneGoogleClientID ArcaneGoogleClientSecret; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
      fail "the built Info.plist contains a private Google OAuth key; nothing was published"
    fi
  done
fi
if /usr/libexec/PlistBuddy -c 'Print :NXLibraryDevelopmentProfile' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  fail "a release must not select the development data profile"
fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
  || fail "the built app does not carry version $VERSION"
[ "$(/usr/libexec/PlistBuddy -c 'Print :NXLibraryRelease' "$APP/Contents/Info.plist")" = "true" ] \
  || fail "the built app is not marked as a release"
if [[ -n "$ENGINE_REPO" ]]; then
  [ "$(/usr/bin/plutil -extract NXLibraryEngineRepository raw "$APP/Contents/Info.plist")" = "$ENGINE_REPO" ] \
    && [ "$(/usr/bin/plutil -extract NXLibraryEngineCommit raw "$APP/Contents/Info.plist")" = "$ENGINE_COMMIT" ] \
    || fail "the built app does not carry the requested engine pin"
fi

# Finder metadata becomes AppleDouble sidecars in a ZIP; release bundles need only
# their sealed files and relative links, not those extra unsealed resources.
ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
"$APP/Contents/Resources/Runtime/python/bin/python3" -I -B \
  "$APP/Contents/Resources/validate_update.py" "$ZIP" "$OUT/.update-check"
codesign --verify --deep --strict "$OUT/.update-check/NXLibrary.app"
python3 "$ROOT/scripts/check_localizations.py" --app "$OUT/.update-check/NXLibrary.app"
rm -rf "$OUT/.update-check"
echo "Zip: $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
DMG="$OUT/NXLibrary-$VERSION.dmg"
bash "$ROOT/scripts/build_dmg.sh" "$APP"
mv "$ROOT/dist/NXLibrary.dmg" "$DMG"
echo "DMG: $DMG"

if [ "$PUBLISH" = "1" ]; then
  git tag "$TAG"
  git push origin "$TAG"
  {
    cat "$NOTES"
    if [[ -n "$ENGINE_REPO" ]]; then
      printf '\n\n## Moteur épinglé\n\n- Dépôt : %s\n- Commit : `%s`.\n' "$ENGINE_REPO" "$ENGINE_COMMIT"
    fi
    printf '\n\n%s\n' "$REQUIRES"
  } > "$OUT/notes.md"
  gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPOSITORY" \
    --title "Arcane $VERSION" --notes-file "$OUT/notes.md"
  echo "Published $TAG"
else
  echo "Not published (add --publish --notes <file> to create the GitHub release)."
fi
