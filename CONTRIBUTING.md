# Building Longhand

## Build it

You need Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```
./scripts/build.sh
```

This writes `dist/Longhand.app`. `Longhand.xcodeproj` is generated from `project.yml`; edit that, not the project. `"dist/Longhand Test.app/Contents/MacOS/Longhand" --selftest /tmp/report.txt` runs the self-test against a temporary library.

## What's here

| Path | What it is |
| --- | --- |
| `src/Longhand` | The app (Swift, SwiftUI and AppKit) |
| `project.yml` | The project, for XcodeGen |
| `scripts/` | Build, screenshots, a demo library, library builders for tests and pictures |
| `DESIGN.md` | The design rules the interface follows |
| `docs/` | The website (GitHub Pages) |
| `third_party/` | Credits for theme colours and the one non-SF-Symbol icon |
