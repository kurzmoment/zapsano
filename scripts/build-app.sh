#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP_DIR="$PWD/build/Zapsáno.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp .build/release/Faktura "$APP_DIR/Contents/MacOS/Faktura"
cp Branding/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Faktura/Resources/SupplierLogo.pdf "$APP_DIR/Contents/Resources/SupplierLogo.pdf"
cp Faktura/Resources/Manrope-OFL.txt "$APP_DIR/Contents/Resources/Manrope-OFL.txt"
cp Faktura/Resources/SupplierLogo-Provenance.txt "$APP_DIR/Contents/Resources/SupplierLogo-Provenance.txt"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Faktura</string>
<key>CFBundleIdentifier</key><string>cz.faktura.app</string>
<key>CFBundleName</key><string>Zapsáno</string>
<key>CFBundleDisplayName</key><string>Zapsáno</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>cs</string>
<key>CFBundleLocalizations</key><array><string>cs</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
echo "Aplikace: $APP_DIR"
