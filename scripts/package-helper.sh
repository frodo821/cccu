#!/bin/sh
# macOS ヘルパーを配布用にパッケージする (CI と手元の両方で使う)。
#   出力: dist/cccu-helper-<version>-macos-universal.tar.gz (+ .sha256)
#   署名: CCCU_SIGN_IDENTITY があればそれ (CI では Developer ID Application)、無ければ bin/cccu-sign の自動選択
#   公証: NOTARY_KEY_ID / NOTARY_KEY_ISSUER / NOTARY_KEY_PATH (App Store Connect API key) が揃っていれば notarytool を実行
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(python3 -c "import json;print(json.load(open('$ROOT/.claude-plugin/plugin.json'))['version'])")}"
OUT="$ROOT/dist"; mkdir -p "$OUT"
cd "$ROOT/ax_helpers/macos"

echo "[package] building universal release $VERSION"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/cccu-helper"
[ -x "$BIN" ] || BIN=".build/release/cccu-helper"
APP="$OUT/cccu-helper.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/cccu-helper"
sed "s/<string>[0-9.]*<\/string><!--version-->/<string>$VERSION<\/string><!--version-->/" Info.plist > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" 2>/dev/null || true

"$ROOT/bin/cccu-sign" "$APP"

AUTHORITY="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1)"
if ! echo "$AUTHORITY" | grep -q 'Developer ID Application'; then
  echo "[package] notarization skipped: signed with '${AUTHORITY#Authority=}', notarization needs a Developer ID Application identity"
elif [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_KEY_ISSUER:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then
  echo "[package] notarizing"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER" --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/notarize.zip"
else
  echo "[package] notarization skipped (no NOTARY_* secrets)"
fi

TAR="$OUT/cccu-helper-$VERSION-macos-universal.tar.gz"
tar -C "$OUT" -czf "$TAR" cccu-helper.app
(cd "$OUT" && shasum -a 256 "$(basename "$TAR")" > "$TAR.sha256")
codesign -dvv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier' | head -2 | sed 's/^/[package] /'
echo "[package] $TAR"
