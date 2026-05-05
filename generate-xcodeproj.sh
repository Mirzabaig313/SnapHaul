#!/bin/bash
# SnapHaul — Xcode Project Generator
#
# This script generates an Xcode project from the SPM package and
# provides instructions for adding the extension targets manually.
#
# The SPM package handles the host app and shared framework.
# Extension targets (File Provider, Finder Sync) must be added
# manually in Xcode because SPM doesn't support extension targets.
#
# Usage:
#   cd MediaIngestPro
#   chmod +x generate-xcodeproj.sh
#   ./generate-xcodeproj.sh

set -e

echo "╔══════════════════════════════════════════════════╗"
echo "║  SnapHaul — Xcode Project Setup                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo

# Step 1: Generate xcodeproj from SPM
echo "→ Generating Xcode project from Package.swift..."
swift package generate-xcodeproj 2>/dev/null || {
    echo "  Note: 'generate-xcodeproj' is deprecated. Using 'swift package' Xcode integration instead."
    echo "  Open Package.swift directly in Xcode: open Package.swift"
}

echo
echo "✓ Project generated."
echo
echo "═══════════════════════════════════════════════════"
echo "  MANUAL STEPS REQUIRED IN XCODE"
echo "═══════════════════════════════════════════════════"
echo
echo "1. Open the project in Xcode:"
echo "   open Package.swift"
echo
echo "2. Add File Provider Extension target:"
echo "   File → New → Target → File Provider Extension"
echo "   - Name: SnapHaulFileProvider"
echo "   - Bundle ID: com.snaphaul.app.fileprovider"
echo "   - Move source files from Sources/FileProviderExtension/ into the target"
echo "   - Add SnapHaulKit as a dependency"
echo "   - Enable 'File Provider' capability in Signing & Capabilities"
echo
echo "3. Add Finder Sync Extension target:"
echo "   File → New → Target → Finder Sync Extension"
echo "   - Name: SnapHaulFinderSync"
echo "   - Bundle ID: com.snaphaul.app.findersync"
echo "   - Move source files from Sources/FinderSyncExtension/ into the target"
echo "   - Add SnapHaulKit as a dependency"
echo
echo "4. Configure App Groups (for XPC between host app and extensions):"
echo "   - Add 'App Groups' capability to all three targets"
echo "   - Group ID: group.com.snaphaul"
echo
echo "5. Configure entitlements:"
echo "   Host App:"
echo "     - com.apple.security.app-sandbox = YES"
echo "     - com.apple.security.device.usb = YES"
echo "     - com.apple.security.files.user-selected.read-write = YES"
echo "   File Provider Extension:"
echo "     - com.apple.developer.fileprovider.testing-mode = YES (dev)"
echo "   Finder Sync Extension:"
echo "     - (no special entitlements needed)"
echo
echo "6. Sign with your Developer ID:"
echo "   - Select your team in Signing & Capabilities for all targets"
echo "   - Use 'Developer ID Application' certificate for distribution"
echo
echo "═══════════════════════════════════════════════════"
echo
echo "For development without extensions, you can continue"
echo "using 'swift build' — the host app works standalone."
