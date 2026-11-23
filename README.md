# InkNote 1.1

A handwritten note-taking app for iPad and iPhone, built with SwiftUI and PencilKit.
Apple Pencil pressure, tilt, palm rejection and double-tap are all supported.

## What is inside

| Area | What it does |
| --- | --- |
| Writing tools | Pen, highlighter, pencil, stroke or pixel eraser, lasso, 10 colours plus a colour picker, adjustable thickness |
| Shapes | Line, arrow, rectangle and ellipse, with full undo and redo |
| Typing | Text boxes you can drag, resize, recolour, bold and scale. Apple Pencil Scribble works inside them |
| Pictures | Add photos from your library, then move and resize them |
| PDF annotation | Import a PDF (the + button, or "Open in InkNote" from Files, Mail or Safari) and write straight on the pages |
| Organisation | Folders (nested), notebooks, covers from presets or your own photo (crop, zoom, optional title), multi-select to move, export or delete, move, duplicate, delete |
| Paper | Blank, lined, grid, dotted, Cornell and weekly planner, in white, cream, mint or sky, portrait or landscape |
| Handwriting to text | Vision reads your ink on the device. Convert a page to text, or leave it to index in the background |
| Search | One search box covers notebook titles, handwriting, typed text and PDF text |
| Audio | Record while you write, replay recordings from the notebook |
| Export | Whole notebook as PDF, or a page as PNG, through the share sheet |
| Bulk export (1.1) | Tap **Select** in the library, tick notebooks and folders, then export as one PDF each, one merged PDF, PNG pages, or an `.inknote` backup. Optional folder structure and audio. Share it or save it to Files |
| Backup and import (1.1) | `.inknote` files hold everything editable. Import them (and several PDFs at once) from the + menu, or open them from Files |

Everything is stored in `Documents/InkNote`, which shows up in the Files app under "On My iPad / InkNote".

## Getting the .ipa without a Mac

An `.ipa` can only be compiled on macOS, so the repository ships with a GitHub Actions workflow that does it on a hosted Mac.

1. Create a new GitHub repository and push this folder to it.
2. Open the **Actions** tab, choose **Build unsigned IPA**, then **Run workflow**.
3. When it finishes (about 5 to 10 minutes), download **InkNote-unsigned-ipa** from the run page.
4. If the build fails, download **build-log** and send it to Claude to fix.

The result is `InkNote-unsigned.ipa`. iOS will not run unsigned code, so sign it on install:

* **Sideloadly or AltStore**: sign with a free Apple ID. The install lasts 7 days, then you refresh it.
* **Your own Mac**: open the project in Xcode instead (next section) and press Run.
* **TestFlight or the App Store**: needs the paid Apple Developer Program. Build a signed archive in Xcode.

## Building on a Mac

```bash
brew install xcodegen
xcodegen generate
open InkNote.xcodeproj
```

Pick your iPad as the destination, set your team under *Signing & Capabilities*, then press Run.
The app needs iOS 16 or later. Handwriting needs a real device to judge properly, and the Simulator has no Apple Pencil.

## Using it

* **Pencil only** (the pencil icon in the tool bar): fingers scroll and pinch to zoom, the Pencil draws. It is on by default on iPad and off on iPhone. Switch it off on iPad if you want to draw with a finger.
* **Double-tap the Pencil** to jump to the eraser and back.
* **Text tool (A)**: tap the page to add a box. Tap a box or picture to select it, then drag the handles.
* **Pages button**: thumbnails, reorder, duplicate and delete.
* **Menu (…)**: add or duplicate a page, change the paper, handwriting to text, export.

## Project layout

```
project.yml                   XcodeGen description (generates InkNote.xcodeproj)
.github/workflows/            Cloud build that produces the unsigned .ipa
tools/make_icon.py            Draws the app icon
InkNote/
  App/                        App entry point and navigation root
  Models/                     Notebook, page, cover and colour types
  Services/                   Storage, PDF, paper drawing, export, handwriting, audio
  Views/Library/              Home screen, covers, new notebook sheet, search results
  Views/Editor/               Canvas, tools, text boxes, pictures, pages, audio sheets
  Assets.xcassets/            App icon and accent colour
```

## Not included yet

* **iCloud sync.** It needs the iCloud entitlement, which needs a paid developer account and a signed build. Until then, the Files app and PDF export move notes between devices.
* **Audio playback synced to strokes.** Recordings are attached to the notebook and replay on their own.
* **Handwriting search for languages Vision does not read as handwriting.** Typed text and PDF text are always searchable.
