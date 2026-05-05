#!/bin/bash
# Copy libmtp and libusb into the app bundle's Frameworks/ directory,
# re-sign them, and fix all references so the binary uses @rpath.
#
# This script runs as an Xcode "Run Script" build phase.

set -e

FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${FRAMEWORKS_DIR}"

# The main binary (or debug dylib) that links against libmtp/libusb
MAIN_BINARY="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}"
# Xcode debug builds produce a .debug.dylib — check for it
DEBUG_DYLIB="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/${PRODUCT_NAME}.debug.dylib"

# Copy libmtp
LIBMTP_SRC="/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib"
if [ -f "${LIBMTP_SRC}" ]; then
    cp -f "${LIBMTP_SRC}" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    chmod u+w "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    install_name_tool -id "@rpath/libmtp.9.dylib" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    echo "✓ Copied and signed libmtp.9.dylib"
else
    echo "✗ libmtp not found at ${LIBMTP_SRC}"
    exit 1
fi

# Copy libusb
LIBUSB_SRC="/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib"
if [ -f "${LIBUSB_SRC}" ]; then
    cp -f "${LIBUSB_SRC}" "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    chmod u+w "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    install_name_tool -id "@rpath/libusb-1.0.0.dylib" "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    echo "✓ Copied and signed libusb-1.0.0.dylib"
else
    echo "✗ libusb not found at ${LIBUSB_SRC}"
    exit 1
fi

# Fix libmtp's internal reference to libusb
chmod u+w "${FRAMEWORKS_DIR}/libmtp.9.dylib"
install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/libmtp.9.dylib"

# Fix the main binary's references to point to @rpath instead of /opt/homebrew
for BINARY in "${MAIN_BINARY}" "${DEBUG_DYLIB}"; do
    if [ -f "${BINARY}" ]; then
        chmod u+w "${BINARY}"
        install_name_tool -change "/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib" "@rpath/libmtp.9.dylib" "${BINARY}" 2>/dev/null || true
        install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" "${BINARY}" 2>/dev/null || true
        echo "✓ Fixed references in $(basename ${BINARY})"
    fi
done

echo "✓ All dylibs ready in ${FRAMEWORKS_DIR}"
