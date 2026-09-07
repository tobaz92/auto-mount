#!/bin/bash
# build.sh — Compile et crée le bundle AutoMount.app

APP_NAME="AutoMount"
BUILD_DIR="build"
INSTALL_DIR="$HOME/Applications"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
PLIST_DIR="$APP_BUNDLE/Contents"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
VERSION=$(git describe --tags --always 2>/dev/null || echo "1.0")

echo "Compilation de $APP_NAME v$VERSION..."

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc -O -swift-version 5 \
    -o "$MACOS_DIR/$APP_NAME" \
    AutoMount.swift \
    -framework AppKit \
    -framework NetFS \
    -framework ServiceManagement

if [ $? -ne 0 ]; then
    echo "Erreur de compilation."
    exit 1
fi

# Info.plist avec ATS verrouillé
cat > "$PLIST_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.automount.app</string>
    <key>CFBundleName</key>
    <string>AutoMount</string>
    <key>CFBundleDisplayName</key>
    <string>AutoMount NAS</string>
    <key>CFBundleExecutable</key>
    <string>AutoMount</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
    </dict>
</dict>
</plist>
PLIST

# Entitlements (réseau client requis pour SMB)
ENTITLEMENTS="$BUILD_DIR/AutoMount.entitlements"
cat > "$ENTITLEMENTS" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
ENT

# Générer l'icône si absente
if [ ! -f "AppIcon.icns" ] && [ -f "generate-icon.swift" ]; then
    echo "Génération de l'icône..."
    swiftc -O -framework AppKit -o /tmp/generate-icon generate-icon.swift
    (cd /tmp && ./generate-icon)
    iconutil -c icns /tmp/AppIcon.iconset -o AppIcon.icns 2>/dev/null
    rm -rf /tmp/generate-icon /tmp/AppIcon.iconset
fi

# Copier l'icône
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$RESOURCES_DIR/"
fi

# Signature ad-hoc + hardened runtime + entitlements
codesign --force --deep --sign - --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "Signature ad-hoc + entitlements appliquée."
else
    echo "Signature impossible (non bloquant)."
fi

echo ""
echo "Build réussi : $APP_BUNDLE"

if [ "$1" != "--install" ]; then
    echo ""
    echo "Pour lancer :"
    echo "  open $APP_BUNDLE"
    echo ""
    echo "Pour installer dans $INSTALL_DIR et relancer :"
    echo "  ./build.sh --install"
    exit 0
fi

# L'app tourne en agent : sans arrêt préalable, le cp écrase un bundle en
# cours d'exécution et laisse l'ancienne version en mémoire.
INSTALLED="$INSTALL_DIR/$APP_NAME.app"
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME"
sleep 1

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED"
cp -R "$APP_BUNDLE" "$INSTALLED" || { echo "Installation échouée."; exit 1; }

echo "Installé : $INSTALLED"
open "$INSTALLED" && echo "Relancé depuis $INSTALL_DIR."
