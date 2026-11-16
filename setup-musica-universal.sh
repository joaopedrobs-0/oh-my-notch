#!/bin/zsh
# Música de QUALQUER app no notch (YouTube no navegador, Podcasts, etc.).
#
# Desde o macOS 15.4 a Apple bloqueia apps comuns de ler "o que está tocando".
# O projeto aberto mediaremote-adapter (licença BSD-3, github.com/ungive/mediaremote-adapter)
# contorna isso usando o /usr/bin/perl do próprio sistema, que tem essa permissão,
# para carregar uma pequena biblioteca que só imprime o que está tocando.
#
# Rode UMA vez você mesmo, depois rode ./build.sh. Para desfazer: apague Vendor/mediaremote-adapter/build.
set -e
cd "$(dirname "$0")/Vendor/mediaremote-adapter"
F=build/MediaRemoteAdapter.framework
rm -rf build; mkdir -p "$F/Versions/A/Resources"
clang -arch arm64 -dynamiclib -fobjc-arc -fvisibility=default -Iinclude -Isrc \
  src/adapter/*.m src/private/MediaRemote.m src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$F/Versions/A/MediaRemoteAdapter" 2>/dev/null
ln -sf A "$F/Versions/Current"
ln -sf Versions/Current/MediaRemoteAdapter "$F/MediaRemoteAdapter"
ln -sf Versions/Current/Resources "$F/Resources"
cat > "$F/Versions/A/Resources/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>MediaRemoteAdapter</string><key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string><key>CFBundlePackageType</key><string>FMWK</string><key>CFBundleShortVersionString</key><string>0.1</string><key>CFBundleVersion</key><string>0.1.0</string></dict></plist>
PL
codesign --force --deep --sign - "$F" >/dev/null
echo "Testando (toque algo no YouTube ou em qualquer player)..."
/usr/bin/perl bin/mediaremote-adapter.pl "$(pwd)/$F" get --no-artwork || true
echo
echo "✅ Pronto. Agora rode ./build.sh para colocar no app."
