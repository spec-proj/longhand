# Building Longhand

I am open to pretty much anything in terms of feature suggestions, as long as it’s in the spirit of the app, mainly:  
- Features/changes must be writer-forward.
- Features/changes must not add unneeded complexity. Please simplify Longhand where possible.
- Vibe coding is allowed, but please be rigorous and run tests.

## Build it

You need Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```
./scripts/build.sh
```

This writes `dist/Longhand.app`. `Longhand.xcodeproj` is generated from `project.yml`; edit that, not the project. `"dist/Longhand Test.app/Contents/MacOS/Longhand" --selftest /tmp/report.txt` runs the self-test against a temporary library.

## Contents

| Path | Info |
| --- | --- |
| `src/Longhand` | The app (Swift, SwiftUI and AppKit) |
| `project.yml` | The project, for XcodeGen |
| `scripts/` | Build, screenshots, a demo library, library builders for tests and pictures |
| `DESIGN.md` | The design rules the interface follows |
| `docs/` | The website (GitHub Pages) |
| `third_party/` | Credits for theme colours and the one non-SF-Symbol icon |
