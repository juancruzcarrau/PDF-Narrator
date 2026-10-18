# PDF Narrator: developer notes

User-facing docs are in [README.md](README.md). This file is for people (and Claude sessions) working on the code.

## Layout

| Path | What it is |
|---|---|
| `Sources/PDFNarrator.swift` | The whole app: a single SwiftUI/AppKit file, split into `// MARK:` sections |
| `Tools/MakeIcon.swift` | Draws the app icon PNG at build time |
| `Info.plist` | Bundle info. `CFBundleShortVersionString` is the version the updater compares |
| `build.sh` | Builds a universal (arm64 + x86_64) `build/PDF Narrator.app` with only the Xcode Command Line Tools (`swiftc`, no Xcode project) and ad-hoc signs it |
| `package.sh` | `build.sh` + wraps the app in `build/PDF-Narrator.dmg` (with `INSTALL.txt` as "Read Me First.txt") |
| `release.sh` | Publishes a GitHub release (see below) |
| `INSTALL.txt` | Plain-text install guide shipped inside the DMG; keep it in sync with the README |

`build/` is git-ignored.

### Sections of `PDFNarrator.swift`

- **Text model / Extraction (`Extractor`)**: pulls lines from PDFKit with font size, family, boldness and color, works out
  the document's body style, and drops anything that isn't main text (margins, running headers, page numbers, headings,
  small text, footnotes, exhibit pages, back matter, boilerplate, text on figures). Then it joins lines into paragraphs,
  which keeps the voice's intonation across line breaks. Every skipped line gets a reason string.
- **Figures**: walks each page's content stream with `CGPDFScanner` to find placed images (`Do`/inline images) and
  clusters of painted vector paths (charts, diagrams, bordered tables). Text inside a figure is skipped unless it
  looks like prose: if the median line width is at least 60% of the region's width, it's kept.
  Images are tested one by one, so a slide's own callouts placed between pictures are kept.
- **Outline**: reads the PDF's bookmarks and maps each one to the first paragraph that is read at or after it.
- **Text repair**: uses `NSSpellChecker` to re-join line-break hyphens and restore missing `fi`/`ffi` ligatures.
- **Voices / Reader**: speech with `AVSpeechSynthesizer`, or `NSSpeechSynthesizer` for "System Voice", because Siri
  voices can't be picked via AVSpeech. Also handles media keys and the time estimate: a first guess of ~165 words/min
  at the default speed, replaced by the measured gaps between word callbacks.
- **Updates (`Updater`)**: see below.
- **Text view / Main window / App**: the SwiftUI UI.

## Build and debug

```sh
./build.sh                                    # → build/PDF Narrator.app
./package.sh                                  # → build/PDF-Narrator.dmg
```

The binary has a debug mode that prints what would be read, what gets skipped (with reasons) and how the chapters map:

```sh
B="build/PDF Narrator.app/Contents/MacOS/PDFNarrator"
"$B" --dump file.pdf            # main text only
"$B" --dump file.pdf --all      # with "Main text only" off
"$B" --dump file.pdf --lines 3  # raw lines of page 3: size, position, font, bold (B), on a figure (FIG), color; plus figure regions
```

PDFKit logs noise to stderr (`attributedStringScaled …`), so add `2>/dev/null`.

**Testing changes to extraction:** save `--dump` output from the old binary for a few real PDFs, rebuild, and diff the
`=== READ ALOUD ===` sections. Make sure no real prose disappears. To see what a figure region covers, render the page
to a PNG with PDFKit and draw the `--lines` figure rectangles on top.

## Releasing

```sh
git commit -am "…"          # the script refuses to run with uncommitted changes
./release.sh 1.5 "What changed, in user-friendly words"
```

`release.sh` does the following:

1. Bumps `CFBundleShortVersionString` to the given version and increments `CFBundleVersion`.
2. Runs `package.sh`, then zips the app with `ditto -c -k --keepParent` into `build/PDF-Narrator.zip`.
3. Commits "Release vX.Y", tags `vX.Y` and pushes.
4. Runs `gh release create` with both the `.zip` and the `.dmg`.

The release notes are shown to users as the tooltip of the update bar, so write them for users.

## How the in-app updater works

- On launch, and from ⋯ / app menu → Check for Updates…, it calls
  `https://api.github.com/repos/juancruzcarrau/PDF-Narrator/releases/latest` (no auth; needs the repo to stay **public**).
- If the tag (with the leading `v` stripped) is numerically newer than the running version, and the release has an
  asset named exactly **`PDF-Narrator.zip`**, the "Version X is available" bar appears.
  `Updater.repo` and `Updater.assetName` are the constants to change if the repo or asset is renamed.
- **Update** downloads the zip with `URLSession`. Files downloaded that way get no quarantine flag, so no Gatekeeper
  prompt. It then:
  1. Unzips with `ditto`.
  2. Checks the bundle identifier matches and runs `codesign --verify`.
  3. Starts a detached `/bin/sh` that waits for the app's PID to exit, swaps the bundle (keeping a `.old` backup until
     the move succeeds), strips quarantine and `open`s the new app.
  4. Quits the app.
- It refuses to update when running translocated, e.g. straight from Downloads (`/AppTranslocation/` in the path),
  or when the folder isn't writable.
- Copies built before v1.1 have no updater. Users on those must install a DMG manually once.

## Signing

The app is ad-hoc signed (`codesign -s -`), not with a paid Developer ID, so first-time users go through
System Settings → Privacy & Security → Open Anyway (see README). Notarization would need an Apple Developer account.

## Environment notes for Claude sessions

- The git remote is HTTPS (`gh auth setup-git`). SSH to GitHub isn't set up on this machine.
- The sandbox can't click UI (no accessibility permission) or take screenshots, so UI changes can't be checked
  visually from a session. Verify logic with `--dump` and offline renders, then ask the user to try the build.
- `say -o file.aiff "…"` + `afinfo` measures voice speed without playing audio.
- Opening some PDFs is slow (e.g. ~15 s for a 20-page HBS note). That's PDFKit text extraction, not figure detection.
