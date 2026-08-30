# DeDuP

iOS/iPadOS app for finding and reviewing duplicate photos in the user's photo library, using perceptual image hashing ([CocoaImageHashing](https://github.com/ameingast/cocoaimagehashing)) to group visually similar assets.

## Requirements

- Xcode with iOS 17.4+ SDK support
- [Homebrew](https://brew.sh)

## Setup

```bash
brew install swiftlint swiftformat
./scripts/setup-hooks.sh
```

Then open `DeDuP.xcodeproj` in Xcode.

## Tooling

### SwiftLint

Enforces code style and catches common mistakes. Configured in [.swiftlint.yml](.swiftlint.yml) and runs automatically as an Xcode build phase ("SwiftLint") — violations show up inline in the Issue Navigator. `force_cast` is treated as an error and fails the build; other rules are warnings.

Run manually:

```bash
swiftlint
```

### SwiftFormat

Automatically reformats Swift files to a consistent style (4-space indent, sorted imports, no redundant `self`, 130-char line width — see [.swiftformat](.swiftformat)). Runs automatically as an Xcode build phase ("SwiftFormat") before SwiftLint, rewriting files in place on every build.

Run manually:

```bash
swiftformat .
```

### Git pre-commit hook

Before each commit, staged `.swift` files are automatically formatted with SwiftFormat (and re-staged) and checked with SwiftLint; the commit is blocked if SwiftLint reports a serious violation (e.g. `force_cast`).

The hook lives in [scripts/git-hooks/pre-commit](scripts/git-hooks/pre-commit) — git doesn't track hooks itself, so after cloning the repo you need to install it once:

```bash
./scripts/setup-hooks.sh
```

## Tests

```bash
xcodebuild test -project DeDuP.xcodeproj -scheme DeDuP -destination 'platform=iOS Simulator,name=iPhone 15'
```
