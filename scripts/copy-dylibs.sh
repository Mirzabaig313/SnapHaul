#!/bin/bash
# Copy libusb and libmtp into the app bundle's Frameworks/ directory and fix references.
# libmtp is linked for its IOKit initialization side effects (enables USB interface claiming).
# MTP protocol logic is handled by CMTPCore — libmtp functions are not called directly.

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
    echo "✓ Copied and signed libusb-1.0.0.dylib"
else
    echo "error: libusb not found at ${LIBUSB_SRC}" >&2
    exit 1
fi

# Copy libmtp (linked for IOKit initialization, not called directly)
LIBMTP_SRC="/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib"
if [ -f "${LIBMTP_SRC}" ]; then
    cp -f "${LIBMTP_SRC}" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    chmod u+w "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    install_name_tool -id "@rpath/libmtp.9.dylib" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    # Fix libmtp's internal reference to libusb
    install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    codesign --force --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/libmtp.9.dylib"
    echo "✓ Copied and signed libmtp.9.dylib"
else
    echo "warning: libmtp not found at ${LIBMTP_SRC} — USB claim may fail" >&2
fi

# Fix the main binary's references
if [ -f "${MAIN_BINARY}" ]; then
    chmod u+w "${MAIN_BINARY}" 2>/dev/null || true
    install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" "${MAIN_BINARY}" 2>/dev/null || true
    install_name_tool -change "/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib" "@rpath/libmtp.9.dylib" "${MAIN_BINARY}" 2>/dev/null || true
    echo "✓ Fixed dylib paths in $(basename "${MAIN_BINARY}")"
fi

# Fix the debug dylib if present
DEBUG_DYLIB="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/${PRODUCT_NAME}.debug.dylib"
if [ -f "${DEBUG_DYLIB}" ]; then
    chmod u+w "${DEBUG_DYLIB}" 2>/dev/null || true
    install_name_tool -change "/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" "${DEBUG_DYLIB}" 2>/dev/null || true
    install_name_tool -change "/opt/homebrew/opt/libmtp/lib/libmtp.9.dylib" "@rpath/libmtp.9.dylib" "${DEBUG_DYLIB}" 2>/dev/null || true
    echo "✓ Fixed dylib paths in $(basename "${DEBUG_DYLIB}")"
fi

echo "✓ Done"
