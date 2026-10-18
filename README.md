# PDF Narrator

A small floating macOS player that reads the main text of a PDF aloud with macOS's built-in voices,
meant to sit next to Preview while you read.

- Shows the extracted text; click any word to start reading from there. The spoken word is highlighted.
- Shows the estimated reading time, then the time left; it learns the voice's real speed as it reads.
- Chapter sidebar from the PDF's own bookmarks: click a chapter to start reading there.
- "Main text only" skips headers/footers, page numbers, headings, pull quotes, decks/bylines, captions,
  text on charts, diagrams and pictures, exhibit pages, footnotes, endnotes and copyright boilerplate.
- Joins the lines of a paragraph before speaking, so the voice keeps its intonation across line breaks.
- Repairs line-break hyphens and missing "fi/ffi" ligatures using the system spell checker.

Build: `./build.sh` → `build/PDF Narrator.app`
Debug what gets read/skipped: `"build/PDF Narrator.app/Contents/MacOS/PDFNarrator" --dump file.pdf [--all] [--lines N]`

## Releases and updates

The app checks GitHub for a newer release when it launches (and from ⋯ → Check for Updates…).
When one exists, an **Update** bar appears: one click downloads it, replaces the app and relaunches.

To publish a new version: commit your changes, then run `./release.sh 1.2 "What changed"`.
It bumps the version, builds, tags, and uploads `PDF-Narrator.zip` (used by the updater) and
`PDF-Narrator.dmg` (for first-time installs) to a GitHub release.
