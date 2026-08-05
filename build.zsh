#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
SRC="$ROOT/ClipBar"
ICON="$ROOT/Resources/ClipBar.icns"

APP="/Applications/ClipBar.app"
TMP_APP="${APP}.new"
OLD_APP="${APP}.old"

SIGNING_IDENTITY="${APPLE_SIGN_IDENTITY:--}"

[[ -f "$ICON" ]] || {
    echo "Error: Icon not found: $ICON" >&2
    exit 1
}

# Validate bundled plugin JSON and reject duplicate IDs before signing.
python3 - "$ROOT/DefaultPlugins" <<'PYVALIDATE'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
seen = {}
errors = []

for path in sorted(root.glob("*.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{path.name}: invalid JSON: {exc}")
        continue

    plugin_id = data.get("id")
    if not isinstance(plugin_id, str) or not plugin_id.strip():
        errors.append(f"{path.name}: missing non-empty id")
        continue

    if plugin_id in seen:
        errors.append(
            f"duplicate id '{plugin_id}' in {seen[plugin_id]} and {path.name}"
        )

    seen[plugin_id] = path.name

    if data.get("type") != "group":
        for key in ("title", "symbol", "type"):
            if not isinstance(data.get(key), str) or not data[key].strip():
                errors.append(f"{path.name}: missing non-empty {key}")

if errors:
    print("Plugin validation failed:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Validated {len(seen)} bundled plugin definitions")
PYVALIDATE

killall ClipBar 2>/dev/null || true
rm -rf "$TMP_APP" "$OLD_APP"

mkdir -p \
    "$TMP_APP/Contents/MacOS" \
    "$TMP_APP/Contents/Resources/DefaultPlugins" \
    "$TMP_APP/Contents/Resources/ThirdPartyLicenses"

swiftc \
    "$SRC"/*.swift \
    -target arm64-apple-macosx13.0 \
    -o "$TMP_APP/Contents/MacOS/ClipBar" \
    -framework AppKit \
    -framework SwiftUI \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework QuartzCore \
    -lsqlite3

cp "$ICON" "$TMP_APP/Contents/Resources/ClipBar.icns"
cp "$ROOT/LICENSE" "$TMP_APP/Contents/Resources/LICENSE"
cp "$ROOT/DefaultPlugins"/*.json \
    "$TMP_APP/Contents/Resources/DefaultPlugins/"
cp "$ROOT/Resources/Thesaurus.sqlite" \
    "$TMP_APP/Contents/Resources/Thesaurus.sqlite"
cp "$ROOT/Resources/ThirdPartyLicenses"/*.txt \
    "$TMP_APP/Contents/Resources/ThirdPartyLicenses/"

cat > "$TMP_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>

    <key>CFBundleName</key>
    <string>ClipBar</string>

    <key>CFBundleDisplayName</key>
    <string>ClipBar</string>

    <key>CFBundleIdentifier</key>
    <string>de.steffenwoell.clipbar</string>

    <key>CFBundleExecutable</key>
    <string>ClipBar</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleShortVersionString</key>
    <string>1.4.1</string>

    <key>CFBundleVersion</key>
    <string>141</string>

    <key>CFBundleIconFile</key>
    <string>ClipBar</string>

    <key>CFBundleGetInfoString</key>
    <string>ClipBar 1.4.1 &quot;Frija&quot;</string>

    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>

    <key>LSUIElement</key>
    <true/>

    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Steffen Wöll</string>

    <key>NSAccessibilityUsageDescription</key>
    <string>ClipBar needs accessibility access to detect selected text.</string>

    <key>NSHighResolutionCapable</key>
    <true/>

</dict>
</plist>
PLIST

plutil -lint "$TMP_APP/Contents/Info.plist"

test -f "$TMP_APP/Contents/Resources/ClipBar.icns"
test -f "$TMP_APP/Contents/Resources/LICENSE"
test -f "$TMP_APP/Contents/Resources/DefaultPlugins/chatgpt.json"
test -f "$TMP_APP/Contents/Resources/DefaultPlugins/ai.group.json"
test -f "$TMP_APP/Contents/Resources/Thesaurus.sqlite"
test -f "$TMP_APP/Contents/Resources/ThirdPartyLicenses/OpenThesaurus-LGPL.txt"
test -f "$TMP_APP/Contents/Resources/ThirdPartyLicenses/WordNet-3.0-License.txt"

xattr -cr "$TMP_APP"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Signing ad hoc..."
else
    if ! security find-identity -v -p codesigning \
        | grep -Fq "$SIGNING_IDENTITY"; then
        echo "Error: Code-signing identity not found:" >&2
        echo "  $SIGNING_IDENTITY" >&2
        echo >&2
        echo "Available identities:" >&2
        security find-identity -v -p codesigning >&2
        exit 1
    fi

    echo "Signing with: $SIGNING_IDENTITY"
fi

codesign \
    --force \
    --deep \
    --sign "$SIGNING_IDENTITY" \
    "$TMP_APP"

codesign --verify --deep --strict --verbose=2 "$TMP_APP"

if [[ -d "$APP" ]]; then
    mv "$APP" "$OLD_APP"
fi

if ! mv "$TMP_APP" "$APP"; then
    [[ -d "$OLD_APP" ]] && mv "$OLD_APP" "$APP"
    exit 1
fi

rm -rf "$OLD_APP"

touch "$APP"
open "$APP"

echo "Built and started: ClipBar 1.4.1 'Frija' at $APP"
