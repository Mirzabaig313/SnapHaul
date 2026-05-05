#!/bin/bash
# SnapHaul — Build & Package as DMG
#
# Builds the SPM executable, wraps it in a proper .app bundle with
# Info.plist and app icon, then packages into a DMG for distribution.
#
# Usage:
#   cd MediaIngestPro
#   chmod +x build-dmg.sh
#   ./build-dmg.sh
#
# Output: build/SnapHaul.dmg

set -e

APP_NAME="SnapHaul"
BUNDLE_ID="com.snaphaul.app"
VERSION="0.1.0"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "╔══════════════════════════════════════════════════╗"
echo "║  SnapHaul — Build & Package                     ║"
echo "║  Version: ${VERSION}                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Step 1: Build the SPM executable in release mode
echo "→ Building release binary..."
swift build -c release 2>&1 | tail -3
BINARY_PATH=".build/release/${APP_NAME}"

if [ ! -f "${BINARY_PATH}" ]; then
    echo "✗ Build failed — binary not found at ${BINARY_PATH}"
    exit 1
fi
echo "✓ Binary built: $(du -h "${BINARY_PATH}" | cut -f1) "
echo

# Step 2: Create the .app bundle structure
echo "→ Creating app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"

# Copy the binary
cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/"

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
    echo "  ✓ App icon copied"
fi

# Copy entitlements (for reference, not embedded in unsigned builds)
if [ -f "Resources/SnapHaul.entitlements" ]; then
    cp "Resources/SnapHaul.entitlements" "${APP_BUNDLE}/Contents/Resources/"
fi

# Copy bundled libraries (libmtp, libusb)
echo "  → Bundling dynamic libraries..."
LIBMTP_PATH=$(pkg-config --libs-only-L libmtp 2>/dev/null | sed 's/-L//' | tr -d ' ')
if [ -z "${LIBMTP_PATH}" ]; then
    LIBMTP_PATH="/opt/homebrew/lib"
fi

for lib in libmtp.dylib libmtp.9.dylib; do
    SRC="${LIBMTP_PATH}/${lib}"
    if [ -f "${SRC}" ]; then
        cp "${SRC}" "${APP_BUNDLE}/Contents/Frameworks/"
        chmod 755 "${APP_BUNDLE}/Contents/Frameworks/${lib}"
        xattr -c "${APP_BUNDLE}/Contents/Frameworks/${lib}" 2>/dev/null || true
        echo "  ✓ Bundled ${lib}"
    fi
done

# libusb may be in a different path
LIBUSB_PATH="/opt/homebrew/lib"
for lib in libusb-1.0.0.dylib libusb-1.0.dylib; do
    SRC="${LIBUSB_PATH}/${lib}"
    if [ -f "${SRC}" ]; then
        cp "${SRC}" "${APP_BUNDLE}/Contents/Frameworks/"
        chmod 755 "${APP_BUNDLE}/Contents/Frameworks/${lib}"
        xattr -c "${APP_BUNDLE}/Contents/Frameworks/${lib}" 2>/dev/null || true
        echo "  ✓ Bundled ${lib}"
    fi
done

# Fix library paths to use @rpath
echo "  → Fixing library paths..."
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

# Update libmtp to find libusb via @rpath
# Fix library install names for @rpath resolution
LIBUSB_FRAMEWORK="${APP_BUNDLE}/Contents/Frameworks/libusb-1.0.0.dylib"
if [ -f "${LIBUSB_FRAMEWORK}" ]; then
    install_name_tool -id "@rpath/libusb-1.0.0.dylib" "${LIBUSB_FRAMEWORK}" 2>/dev/null || true
    echo "  ✓ Fixed libusb install name"
fi

LIBMTP_FRAMEWORK="${APP_BUNDLE}/Contents/Frameworks/libmtp.9.dylib"
if [ -f "${LIBMTP_FRAMEWORK}" ]; then
    # Change libmtp's reference to libusb to use @rpath
    LIBUSB_OLD=$(otool -L "${LIBMTP_FRAMEWORK}" | grep libusb | awk '{print $1}')
    if [ -n "${LIBUSB_OLD}" ]; then
        install_name_tool -change "${LIBUSB_OLD}" "@rpath/libusb-1.0.0.dylib" \
            "${LIBMTP_FRAMEWORK}" 2>/dev/null || true
    fi
    # Change libmtp's own install name
    install_name_tool -id "@rpath/libmtp.9.dylib" "${LIBMTP_FRAMEWORK}" 2>/dev/null || true
fi

# Update the main binary to find libmtp via @rpath
LIBMTP_OLD=$(otool -L "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" | grep libmtp | awk '{print $1}')
if [ -n "${LIBMTP_OLD}" ]; then
    install_name_tool -change "${LIBMTP_OLD}" "@rpath/libmtp.9.dylib" \
        "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
fi

LIBUSB_OLD=$(otool -L "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" | grep libusb | awk '{print $1}')
if [ -n "${LIBUSB_OLD}" ]; then
    install_name_tool -change "${LIBUSB_OLD}" "@rpath/libusb-1.0.0.dylib" \
        "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
fi

# Copy license files
mkdir -p "${APP_BUNDLE}/Contents/Resources/Licenses"
cp "../LICENSE" "${APP_BUNDLE}/Contents/Resources/Licenses/SnapHaul-LICENSE.txt" 2>/dev/null || true

# Copy Sparkle framework only if it's needed (requires Developer ID signing)
# Sparkle is excluded from development/ad-hoc builds due to Team ID mismatch.
# SPARKLE_FRAMEWORK=$(find .build -name "Sparkle.framework" -type d 2>/dev/null | head -1)
# if [ -n "${SPARKLE_FRAMEWORK}" ] && [ -d "${SPARKLE_FRAMEWORK}" ]; then
#     cp -R "${SPARKLE_FRAMEWORK}" "${APP_BUNDLE}/Contents/Frameworks/"
#     echo "  ✓ Bundled Sparkle.framework"
# fi

echo "✓ App bundle created: ${APP_BUNDLE}"
echo "  Size: $(du -sh "${APP_BUNDLE}" | cut -f1)"
echo

# Fix permissions and strip quarantine attributes from all bundled files
echo "→ Fixing permissions..."
find "${APP_BUNDLE}" -type f -exec chmod 755 {} \; 2>/dev/null || true
find "${APP_BUNDLE}" -type d -exec chmod 755 {} \; 2>/dev/null || true
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
echo "  ✓ Permissions fixed"

# Re-sign all bundled dylibs with ad-hoc signature to match the app.
# Homebrew dylibs are signed with Homebrew's Developer ID, which macOS
# refuses to load into an ad-hoc signed process (Team ID mismatch).
echo "→ Re-signing bundled libraries..."
for dylib in "${APP_BUNDLE}/Contents/Frameworks/"*.dylib; do
    if [ -f "${dylib}" ]; then
        codesign --force --sign - "${dylib}" 2>/dev/null && \
            echo "  ✓ Re-signed $(basename "${dylib}")" || \
            echo "  ⚠ Could not re-sign $(basename "${dylib}")"
    fi
done

# Step 3: Ad-hoc sign the app bundle with Info.plist bound
echo "→ Signing app bundle (ad-hoc)..."
codesign --force --deep --sign - \
    --entitlements "Resources/SnapHaul.entitlements" \
    "${APP_BUNDLE}" 2>&1 | grep -v "^$" || true

# Verify the signature
SIGN_STATUS=$(codesign -dv "${APP_BUNDLE}" 2>&1 | grep "Info.plist")
if echo "${SIGN_STATUS}" | grep -q "not bound"; then
    echo "  ⚠ Info.plist not bound — trying alternate signing..."
    codesign --force --deep --sign - "${APP_BUNDLE}" 2>&1 | grep -v "^$" || true
else
    echo "  ✓ App signed successfully"
fi

# Step 3: Verify the app bundle
echo "→ Verifying app bundle..."
if [ -x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" ]; then
    echo "  ✓ Binary is executable"
fi

# Check dynamic library dependencies (no-execute check)
echo "  → Checking library dependencies..."
MISSING_LIBS=$(otool -L "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null | grep "not found" || true)
if [ -n "${MISSING_LIBS}" ]; then
    echo "  ⚠ Missing libraries:"
    echo "${MISSING_LIBS}"
else
    echo "  ✓ All libraries resolved"
fi
echo

# Step 4: Create DMG
echo "→ Creating DMG..."
DMG_STAGING="${BUILD_DIR}/dmg-staging"
mkdir -p "${DMG_STAGING}"

# Copy app to staging
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "${DMG_STAGING}/Applications"

# Create the DMG
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${BUILD_DIR}/${DMG_NAME}" 2>&1 | grep -v "^$"

# Clean up staging
rm -rf "${DMG_STAGING}"

echo
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✓ Build complete!                              ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  App:  ${BUILD_DIR}/${APP_NAME}.app"
echo "║  DMG:  ${BUILD_DIR}/${DMG_NAME}"
echo "║  Size: $(du -h "${BUILD_DIR}/${DMG_NAME}" | cut -f1)"
echo "╚══════════════════════════════════════════════════╝"
echo
echo "To install: Open ${BUILD_DIR}/${DMG_NAME} and drag SnapHaul to Applications."
echo
echo "NOTE: This build is unsigned. macOS will show a Gatekeeper warning."
echo "To open: Right-click → Open → Open (first time only)."
