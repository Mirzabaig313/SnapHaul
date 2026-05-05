# SnapHaul — Xcode Project Setup

> **The correct approach:** Use [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate
> the `.xcodeproj` from `project.yml`. One command, reproducible, no manual clicking.
>
> `swift package generate-xcodeproj` was removed in Xcode 16. Do not use it.

---

## Architecture note — why there is no Finder Sync Extension

The original design included both a File Provider Extension and a Finder Sync Extension.
**This does not work.** Apple explicitly states:

> "No, applications cannot use both the FinderSync and FileProvider extension points."
> — [Apple Developer Forums, thread/718381](https://developer.apple.com/forums/thread/718381)

Both extensions occupy the same XPC slot in `Contents/PlugIns/`. Only one works at a time.

**The solution:** Use `NSFileProviderCustomAction` (part of the File Provider framework) for
right-click context menu items. This is the same approach used by Dropbox, OneDrive, and
iCloud Drive. The `FinderSyncExtension/` source directory is kept for reference but is not
compiled into the app.

---

## Step 1 — Install XcodeGen

```bash
brew install xcodegen
```

Verify:
```bash
xcodegen --version
```

---

## Step 2 — Generate the Xcode project

```bash
cd /Users/mirza/Documents/PROJECTS/Media_Ingest_Pro/MediaIngestPro
xcodegen generate
```

This reads `project.yml` and creates `SnapHaul.xcodeproj`. Run this command any time
`project.yml` changes — it is safe to re-run, it overwrites the existing project file.

---

## Step 3 — Open the generated project

```bash
open SnapHaul.xcodeproj
```

**Always open `SnapHaul.xcodeproj`, not `Package.swift`.**

---

## Step 4 — Configure signing

1. Select the **SnapHaul** target → **Signing & Capabilities**
2. Set **Team** to your Apple ID (free personal team works for local testing)
3. Check **Automatically manage signing**
4. Repeat for **SnapHaulFileProvider** target

For the File Provider extension to work, both targets must be signed by the same team.

---

## Step 5 — Build and run

```
⌘B  — Build all targets
⌘R  — Run SnapHaul
```

The app appears in the menu bar. Connect your Android device — it should be detected
within 3 seconds.

---

## Step 6 — Test the File Provider (Finder sidebar volume)

1. Run the app (⌘R)
2. Connect your Android device
3. Open Finder — the device should appear in the sidebar under **Locations**
4. Click it to browse files on the device

If the volume does not appear:
- Check Console.app for `com.snaphaul.fileprovider` log messages
- The `com.apple.developer.fileprovider.testing-mode` entitlement is set in
  `Sources/FileProviderExtension/SnapHaulFileProvider.entitlements` — this allows
  testing without the production App Store entitlement

---

## Troubleshooting

### "xcodegen: command not found"
```bash
brew install xcodegen
```

### "No such module 'SnapHaulKit'"
Run `xcodegen generate` again, then clean the build folder (⇧⌘K) in Xcode.

### "File Provider volume not appearing in Finder"
The File Provider extension requires the host app to be running. Launch SnapHaul first.
Check that both targets are signed with the same team.

### "libmtp not found at build time"
```bash
brew install libmtp
```
The `project.yml` references `/opt/homebrew/opt/libmtp/lib/libmtp.dylib` (Apple Silicon
Homebrew path). If you're on Intel Mac, change this to `/usr/local/opt/libmtp/lib/libmtp.dylib`.

### "Build fails after changing project.yml"
```bash
xcodegen generate
```
Then in Xcode: **Product → Clean Build Folder** (⇧⌘K), then build again.

---

## File reference

| File | Purpose |
|:-----|:--------|
| `project.yml` | XcodeGen spec — defines all targets, dependencies, entitlements |
| `Sources/FileProviderExtension/Info.plist` | Extension bundle info |
| `Sources/FileProviderExtension/SnapHaulFileProvider.entitlements` | Extension sandbox + app group |
| `Resources/SnapHaul.entitlements` | Host app USB + app group + XPC service |
| `Resources/Info.plist` | Host app bundle info |
| `Sources/FinderSyncExtension/` | Reference only — not compiled (see architecture note above) |
