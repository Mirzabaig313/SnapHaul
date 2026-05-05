# Contributing to SnapHaul

SnapHaul is free software licensed under GPLv3. Contributions are welcome from everyone.

## Getting started

```bash
# Install dependencies
brew install libmtp libusb xcodegen

# Clone and build
git clone https://github.com/user/snaphaul.git
cd snaphaul/MediaIngestPro
swift build

# Run tests
swift test

# Lint
swiftlint
```

## How to contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Run `swift test` and `swiftlint` — fix any failures
5. Commit with a clear message describing what and why
6. Open a pull request against `main`

## What to work on

- Check the [Issues](https://github.com/user/snaphaul/issues) tab for open bugs and feature requests
- Items on the roadmap in README.md are fair game
- Small fixes (typos, docs, error messages) are always appreciated

## Code style

- Follow the existing patterns in the codebase
- Run `swiftlint` before committing
- Add the standard file header to new Swift files:

```swift
// SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0 — see LICENSE
//
```

## Commit messages

Keep them short and descriptive:

```
Fix MTP session timeout on Samsung devices
Add XXH3 checksum option to ingest profiles
Update README with Wi-Fi setup instructions
```

## Pull requests

- One logical change per PR
- Include a brief description of what changed and why
- Reference related issues (`Fixes #42`, `Closes #17`)
- Make sure tests pass before requesting review

## Licensing

By submitting a pull request, you agree that your contribution is licensed under the same GPLv3 license as the rest of the project. You retain copyright over your own code.

## Bug reports

When filing a bug, include:

- macOS version and chip (e.g., macOS 15.4, M2 Pro)
- Android device model and OS version
- Connection method (USB MTP, USB ADB, Wi-Fi)
- Steps to reproduce
- What happened vs. what you expected
- Relevant logs (run with `--test-mtp` or `--test-adb` for diagnostics)

## Questions

Open a Discussion or Issue. There are no dumb questions.
