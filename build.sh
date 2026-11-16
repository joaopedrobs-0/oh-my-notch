#!/bin/zsh
# Compila o Oh My Notch! e instala em /Applications.
# Uso: ./build.sh            (compila e instala)
#      ./build.sh --no-install
set -e
cd "$(dirname "$0")"
APP="Oh My Notch!.app"
EXE="OhMyNotch"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

# Ícone
# Ícone: a logo do Oh My Notch! (AppIcon-1024.png); se faltar, gera o antigo
if [[ -f AppIcon-1024.png ]]; then
  cp AppIcon-1024.png build/icon_1024.png
else
  swiftc -O icon.swift -o build/icon
  ./build/icon build/icon_1024.png
fi
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2)); sips -z $d $d build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# App
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 main.swift Design.swift Island.swift Feeds.swift LockScreen.swift HUD.swift ClaudeActivity.swift MediaKeys.swift Extras.swift -o "$APP/Contents/MacOS/$EXE"
# fotos de fones ficam fora da versão pública (PUBLIC=1)
[[ -d Devices && -z "$PUBLIC" ]] && ditto Devices "$APP/Contents/Resources/Devices"
ditto Localization "$APP/Contents/Resources"
# Música de qualquer app: só entra se você mesmo gerou o adaptador (./setup-musica-universal.sh)
MRA=Vendor/mediaremote-adapter
if [[ -d "$MRA/build/MediaRemoteAdapter.framework" ]]; then
  ditto "$MRA/build/MediaRemoteAdapter.framework" "$APP/Contents/Resources/MediaRemoteAdapter.framework"
  cp "$MRA/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
fi
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Oh My Notch!</string>
  <key>CFBundleDevelopmentRegion</key><string>pt</string>
  <key>CFBundleLocalizations</key><array><string>pt</string><string>en</string></array>
  <key>CFBundleDisplayName</key><string>Oh My Notch!</string>
  <key>CFBundleIdentifier</key><string>local.ohmynotch</string>
  <key>CFBundleExecutable</key><string>OhMyNotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSRemindersUsageDescription</key><string>Para mostrar suas tarefas do app Lembretes na ilha.</string>
  <key>CFBundleShortVersionString</key><string>0.1.0-alpha</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Para mostrar e controlar a música tocando no Spotify e no app Música.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Para mostrar suas tarefas do app Lembretes na ilha e criar novas.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Para colocar seus prints novos na estante do notch.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Para mostrar seus próximos eventos na ilha do notch.</string>
  <key>NSHumanReadableCopyright</key><string>Ilha dinâmica no notch do Mac.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "✅ Compilado: $(pwd)/$APP"

if [[ "$1" != "--no-install" ]]; then
  pkill -x OhMyNotch 2>/dev/null || true
  pkill -x VolumeSeguro 2>/dev/null || true
  rm -rf "/Applications/VolumeSeguro.app"   # versão antiga, com o nome anterior
  sleep 0.5
  rm -rf "/Applications/$APP"
  ditto "$APP" "/Applications/$APP"
  open "/Applications/$APP"
  echo "✅ Instalado e aberto: /Applications/$APP"
fi
