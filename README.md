# Longhand

A writing app for fiction, essays and more, saved as .md files and tracked with Git. Free, for Mac (macOS 26 or later).

**Download:** [the latest release](https://github.com/spec-proj/longhand/releases/latest) · **Website:** [spec-proj.github.io/longhand](https://spec-proj.github.io/longhand/)

Longhand isn't from the App Store, so macOS asks before opening it the first time. Open it once, then choose System Settings › Privacy & Security › Open Anyway.

## What it does

- **Stories, chapters and scenes.** Each scene is a plain Markdown file in a folder you choose, named and ordered so the folder reads like the book. Your writing never depends on Longhand.
- **A chapter reads like a book**, and you can write in it directly. Comments and notes sit in the margin.
- **Git, in plain words.** Commits, branches for rewrites, Compare with changes marked word by word, and push to GitHub, any Git server or a folder.
- **Clear Desk, focus and typewriter scrolling**, themes, and export to Word, PDF, a print-ready book PDF and EPUB.

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

## Credits

Theme colours come from the projects listed in `third_party/THEMES.md`. The website's photographs are from NASA on The Commons. Its screenshots show Jane Austen's novels, from Project Gutenberg.

## Licence

MIT. See [LICENSE](LICENSE).
