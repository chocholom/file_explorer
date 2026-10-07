# FileExplorer

A dual-pane file manager for macOS in the spirit of Total Commander, with the
**file-type filter bar** that started it: chips for the categories present in the
current folder (Images, Video, Documents, …) with counts. Click one or more to filter
the listing; an active category expands into exact-extension chips (`.jpg`, `.png`, …).

Built with SwiftUI, no dependencies. Requires macOS 14+.

## Run

```sh
./make-app.sh --install                       # release build, icon, copy to /Applications
./make-app.sh && open dist/FileExplorer.app   # or just build and run from ./dist
swift run                                     # or straight from the package
```

Or open the folder in Xcode (`open Package.swift`) and hit Run.

> Note: when launched from a terminal, macOS attributes permission prompts for
> Downloads/Desktop/Documents to the terminal app — grant access once when asked.
> F-keys need either the Fn key or "Use F1, F2, etc. keys as standard function keys"
> in System Settings ▸ Keyboard; every F-key action also has a ⌘ shortcut or menu item.

## Commander layer (v0.2)

- **Function-key bar** at the bottom: F2 Rename · F3 View · F4 Edit · F5 Copy · F6 Move ·
  F7 New Folder · F8 Delete. ⇧F4 new file, ⇧F6 rename, ⇧F8 delete permanently.
- **Copy / move to the other pane** (F5 / F6): Commander-style dialog with the
  destination prefilled from the other pane, editable (`~`, relative paths), with a
  conflict policy (Ask / Replace / Skip / Keep Both). Works in single-pane mode too.
- **Background operations with progress and Cancel.** Copies run off the main thread
  with a byte-accurate progress bar; folders are copied file by file so one unreadable
  file doesn't abort the folder.
- **Conflict dialog**: Replace (existing goes to the Trash, so it's undoable) · Keep Both ·
  Skip · Merge (folders) · Cancel, with "apply to all". Drag & drop and paste use it too.
- **Keyboard**: Return opens / enters, Backspace goes to the parent (and selects the
  folder you left), Tab switches panes, ⌘1/⌘2 list/grid, ⇧⌘] / ⇧⌘[ next/previous tab.
- **Mark menu**: Select by Pattern (⌘+), Unselect by Pattern (⌘−), Invert Selection (⌘*),
  Select All with Same Extension (⌥⌘+). Patterns: `*.jpg; IMG_*`, plain text matches anywhere.
- **Compare Directories** (⇧⌘C): marks files missing on the other side, newer than their
  counterpart, or of different size — in both panes.
- **Panes menu**: Swap Panes (⌘U), Show This Folder in Other Pane (⌘→),
  Go to Other Pane's Folder (⌘←).
- **Go menu**: Back/Forward/Enclosing (⌘[ ⌘] ⌘↑), Home (⇧⌘H), Go to Folder… (⇧⌘G), and
  your **favorites**: drag a folder into the sidebar (between the rows or onto the
  "Favorites" header), click the ★ in the header to add the current folder, or use
  "Add to Favorites" in a folder's or the path bar's context menu. Reorder by dragging,
  remove via the context menu. Dropping files *onto* a favorite copies/moves them there.
- **Sortable column headers** (Name / Size / Date / Kind), in sync with the Sort menu.
- **Status bar**: "3 of 40 selected · 12 MB of 1.2 GB · 120 GB free".
- **Session restore**: tabs, panes, folders, view mode and sort order come back on launch.
- **Open With** submenu, **Edit** in your editor (VS Code, Sublime, BBEdit or TextEdit —
  override with `defaults write local.mirek.FileExplorer editorBundleID com.example.editor`),
  **New File**, **Delete Immediately…** (⌥⌘⌫, with confirmation).
- Jump panel (⇧⌘O) also completes typed paths: `~/Dow` lists `~/Downloads`, `~/Documents`.
- If the folder you're viewing is deleted or unmounted, the pane climbs to the nearest
  existing parent instead of showing an error.

## Archives as folders (v0.3)

- **Enter any archive like a folder**: Return or double-click on a `.zip`, `.jar`, `.tar`,
  `.tgz`, `.tbz2`, `.txz`, `.7z`, `.rar` or `.iso` lists its contents in the pane, with the
  same filters, search (recursive search works inside), sorting, breadcrumbs and status bar.
  Backspace walks back out and selects the archive. ZIPs are indexed natively from the
  central directory (ZIP64 included); the rest goes through macOS's built-in `bsdtar`.
- **Copy out** with F5, drag & drop, or Copy/Paste: entries are extracted on demand through
  the same progress bar and conflict dialog as any other copy. Quick Look, Open, Open With,
  Get Info with checksum and Edit work on entries too (via a cache in `~/Library/Caches`).
- **ZIP archives are writable**: copy or move files *into* them (F5/F6 with the archive or
  a folder inside it as the target, drop onto the archive file or into the pane, paste),
  create folders (F7), rename, and delete entries. Conflicts offer Replace / Keep Both /
  Skip; adding is undoable with ⌘Z. Moving into a ZIP sends the source to the Trash.
- **Extract Archive…** (⌥⌘E, also in the context menu) unpacks an archive into a folder
  named after it in the other pane's folder (or next to it in single-pane mode).
- tar, 7z, rar and iso are read-only; deleting entries from an archive is permanent
  (archives have no Trash), so it asks first.

## Filtering & search

- Type-filter bar: category chips with counts → extension chips when a category is active;
  custom type filters ("3D Assets: fbx, obj, blend") via the "+" button
- Date and size presets, name filter, **recursive search** (toggle in the search field)
  showing relative paths — all combinable
- Fuzzy jump to folders and files (⇧⌘O): `dowwall` → ~/Downloads/Wallpapers

## File operations

- Multi-select, Rename (sheet selects the name without the extension), Batch Rename
  (find & replace, numbering, case) with live preview, New Folder (⇧⌘N), Duplicate (⌘D),
  Move to Trash (⌘⌫)
- Cut/Copy/Paste files (⌘X/⌘C/⌘V); cut items render dimmed, paste moves them
- Drag & drop between panes, onto folders, sidebar items, path-bar crumbs and to/from Finder
  (same volume moves, across volumes copies)
- **Undo** (⌘Z) for move, copy, replace, rename, batch rename, trash, duplicate, convert, compress
- Convert images (HEIC/WebP/AVIF/RAW/… → JPG/PNG), Compress to ZIP, Get Info (⌘I) with SHA-256
- Quick Look (space or F3), hover previews, large thumbnails in list view, async folder sizes
- Open in Terminal (iTerm if installed), Reveal in Finder, Copy Path(s) (⌥⌘C)

## Views

- Tabs (⌘T / ⌘W), dual pane (⇧⌘D) with the active pane marked by an accent line;
  a click in a pane makes it active
- List view (sortable columns) and grid view with Quick Look thumbnails; folders always first
- Sidebar with Favorites (built-in + yours) and mounted volumes (refreshes on mount/unmount)
- Show hidden files (⇧⌘.), command palette (⇧⌘A) with every action

## Tests

```sh
swift test
```

## Known gaps

- Writing into tar/7z/rar archives isn't supported (ZIP only); encrypted archives can be
  listed but not extracted. No FTP/SFTP.
- Dragging a *folder* out of an archive to Finder isn't possible (use F5); single files
  up to 64 MB can be dragged.
- Edits made to an entry opened with Edit are not written back into the archive.
- No per-file progress inside a single huge file (progress advances per file).
- Function-key bar isn't customisable yet.
