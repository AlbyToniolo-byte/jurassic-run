#!/bin/sh
# Compila "Jurassic Run.app" (con icona) nella cartella corrente.
set -e
cd "$(dirname "$0")"
APP="Jurassic Run.app"
TMP=$(mktemp -d)

swiftc main.swift -o "$TMP/selftest" && "$TMP/selftest" --selftest # build di debug: gli assert sono attivi

rm -rf "$APP" TouchRunner.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# app universale (Apple Silicon + Intel) da macOS 13: gira su tutti i MacBook Pro con Touch Bar
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 main.swift -o "$TMP/JurassicRun-$arch"
done
lipo -create "$TMP/JurassicRun-arm64" "$TMP/JurassicRun-x86_64" -output "$APP/Contents/MacOS/JurassicRun"

# icona: il gioco disegna un PNG 1024x1024, poi lo riduciamo a tutte le misure richieste da macOS
mkdir "$TMP/AppIcon.iconset"
"$APP/Contents/MacOS/JurassicRun" --icon "$TMP/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Jurassic Run</string>
  <key>CFBundleDisplayName</key><string>Jurassic Run</string>
  <key>CFBundleExecutable</key><string>JurassicRun</string>
  <key>CFBundleIdentifier</key><string>local.jurassicrun</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.arcade-games</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF

codesign --force --deep --sign - "$APP" # firma locale: necessaria sui Mac Apple Silicon
rm -rf "$TMP"

if [ "$1" = "install" ]; then # ./build.sh install → copia anche nella cartella Applicazioni
  rm -rf "/Applications/$APP"
  ditto "$APP" "/Applications/$APP"
  # aggiorna subito icona e nome in Finder, Launchpad e Spotlight
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
  echo "Installata: /Applications/$APP"
fi
echo "Fatto: open \"$APP\""
