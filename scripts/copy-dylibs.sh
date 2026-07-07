#!/bin/bash
# Copy libusb and libmtp into the app bundle's Frameworks/ directory.
# libmtp is required for LIBMTP_Init() which enables macOS USB authorization.

set -euo pipefail

FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${FRAMEWORKS_DIR}"

MAIN_BINARY="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}"
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

# Copy libusb
LIBUSB_SRC="/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib"
if [ -f "${LIBUSB_SRC}" ]; then
    cp -f "${LIBUSB_SRC}" "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    chmod u+w "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    install_name_tool -id "@rpath/libusb-1.0.0.dylib" "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    codesign --force --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/libusb-1.0.0.dylib"
    echo "✓ libusb-1.0.0.dylib"
fi

# Copy libmtp
LIBMTP_SRC="/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib"
if [ -f "${LIBMTP_SRC}" ]; then
    cp -f "${LIBMTP_SRC}" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    chmod u+w "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    install_name_tool -id "@rpath/libmtp.9.dylib" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    codesign --force --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    echo "✓ libmtp.9.dylib"
fi

# Fix references in main binary and debug dylib
for BINARY in "${MAIN_BINARY}" "${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/${PRODUCT_NAME}.debug.dylib"; do
    if [ -f "${BINARY}" ]; then
        chmod u+w "${BINARY}" 2>/dev/null || true
        install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" "${BINARY}" 2>/dev/null || true
        install_name_tool -change "/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib" "@rpath/libmtp.9.dylib" "${BINARY}" 2>/dev/null || true
    fi
done

echo "✓ Done"
