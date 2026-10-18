# FileFormatter — Product & UX Specification

**Working name:** FileFormatter  
**Status:** Draft v0.1 — for review  
**Date:** 18 October 2026  
**Platform:** macOS, native (SwiftUI, with AppKit where the platform requires it)

> A native Mac utility that batch-converts and cleans up files, built around a preview you can trust and a run you can undo.

---

## 1. Summary

FileFormatter takes a messy set of files, applies a reusable **recipe** — convert, resize, strip metadata, rename, normalize text — shows exactly what will happen to every file, and then does it. Every run is journaled and can be undone.

Five things define the product:

- **A preview, not a progress bar.** Before anything is written, every file has a visible outcome: new name, new format, estimated size, and any reason it cannot be processed.
- **Undo that actually works.** Generated files go to the Trash, replaced originals go to an app-managed recovery store, and a run can be undone for 30 days.
- **Recipes, not settings.** A recipe is a small ordered pipeline that can be saved, reused, and applied to hundreds of files with identical rules.
- **Local by default.** No uploads, no accounts, no network entitlement in v1.
- **Native to the bone.** Standard windows, sidebars, tables, inspectors, panels, menus, and keyboard behavior. It should feel like it shipped with macOS.

What it is **not**:

- Not a photo editor or retouching tool.
- Not an arbitrary workflow engine. Automator and Shortcuts exist for that; FileFormatter ships one opinionated, previewable pipeline.
- Not an online converter. Files never leave the Mac.
- Not a document-conversion suite. Word, Excel, and Keynote conversion is a different, much less forgiving product.

---

## 2. Problem and positioning

People who handle files in bulk — designers exporting assets, ops teams archiving scans, analysts cleaning CSV exports — repeatedly do the same small transformation to dozens or hundreds of files. Today they choose between four unsatisfying options:

| Option | What it gets right | Where it fails |
|---|---|---|
| Preview, Quick Look, Finder | Already installed, no upload | One file at a time; no rename rules or metadata stripping |
| Shortcuts, Automator, shell scripts | Powerful, repeatable | Requires building a workflow; little or no preview; easy to make a destructive mistake |
| Online converters | Zero install | Privacy risk, upload time, file-size limits, no batch naming |
| Single-purpose converters | Focused | Opaque; usually irreversible; one format family only |

The gap is a **trustworthy batch tool for people who don't want to script**: more capable than Finder, safer and friendlier than a script, and private by construction.

### 2.1 Who it's for

| Persona | Context | Job to be done | Success looks like |
|---|---|---|---|
| **Maya**, freelance brand designer | 40–80 client assets a week, mostly HEIC and PNG exports | "Give the client web-ready WebP files at the right size, consistently named, without leaking location data." | Drag folder → confirm preview → done in under two minutes, every time |
| **Dan**, operations lead | Scanned contracts and receipts, often 50+ PDFs per batch | "Shrink these and name them consistently so they're findable." | No lost originals; obvious before/after; a repeatable preset |
| **Priya**, analyst / developer-adjacent | CSV and text exports with mixed encodings and line endings | "Make these files behave the same way before I import them." | A dry run she can inspect; no silent changes |
| **Not for** | Pro retouchers, video editors, teams needing scripted pipelines with conditional logic | | |

### 2.2 Positioning statement

For Mac users who process files in bulk, FileFormatter is a native batch converter and cleaner that previews every change and can undo any run. Unlike online converters, it never uploads your files; unlike scripts and Shortcuts, it shows you exactly what will happen before it happens.

---

## 3. Product principles

1. **Nothing changes until you press Run.** The preview is the primary interface, not a confirmation dialog. If a file's outcome can't be shown, it isn't ready to run.
2. **Every run can be undone.** "Undo Run" is a first-class action, available from the completion sheet and from run history for 30 days.
3. **One recipe, many files.** A recipe applies uniformly. The only per-file exceptions in v1 are *Skip* and *Remove*. Predictability beats cleverness.
4. **Silence is success.** Rows that are ready look calm and neutral. Color and badges are reserved for exceptions. A wall of green checkmarks is noise.
5. **Be a good Mac citizen.** Use the system panels, sidebar, inspector, menus, shortcuts, and accessibility APIs. No custom-drawn controls where a native one exists.

---

## 4. Scope

### 4.1 v1 format families

| Family | Read | Write | Operations |
|---|---|---|---|
| **Images** | HEIC, JPEG, PNG, TIFF, WebP, GIF (first frame) | JPEG, PNG, HEIC, TIFF, WebP, PDF | Convert, quality, resize (long edge or percent), don't enlarge, strip metadata (GPS only / all), preserve or convert color profile, apply orientation |
| **PDF** | Unlocked PDF; images as input to PDF | PDF | Compress (Light / Balanced / Aggressive), strip document metadata, images → one PDF per image |
| **Text** | TXT, MD, CSV, TSV, JSON, XML, SRT, LOG | Same | Encoding → UTF-8 (with detected source + override), line endings LF/CRLF, strip BOM, trim trailing whitespace, ensure final newline |

**Cross-cutting:** rename patterns, output destination, collision handling, per-file skip, presets, run history, undo.

### 4.2 Deferred (not v1)

| Feature | Why it's deferred |
|---|---|
| Audio (M4A, MP3, WAV, FLAC) | A second pipeline UI and progress model; MP3 itself is royalty-free since the patents expired |
| Video (MP4/MOV) | Long-running jobs, large files, different progress and disk-space semantics |
| Duplicate detection | A promising cleanup feature, but destructive decisions need their own review UI |
| Combine PDFs / one-to-many outputs | Breaks the one-input/one-output mental model and complicates undo |
| Per-file recipe overrides | Adds a second layer of state; v1 keeps recipes uniform |
| Finder Sync contextual menu | Extra extension target, entitlement, and review cost; Services and Shortcuts cover v1 |
| Preset import/export | Useful for teams; not needed to prove the core loop |
| Folder watching / automation | Turns a utility into an agent; needs scheduling, permissions, and failure UX |
| JSON/XML pretty-print | Belongs to a developer-focused release, not the core cleanup story |

### 4.3 Non-goals

- Editing image content (crops, retouching, filters), OCR, or PDF page editing.
- Cloud storage integrations or sync.
- Windows or Linux.
- Uploading, emailing, or sharing files.
- A plugin or scripting API.
- Being the default handler for every file type.

---

## 5. Core concepts

```
  Recipe (reusable)                    Run (one batch)
  ┌──────────────────────────┐         ┌──────────────────────────────────┐
  │ 1  Convert  HEIC → WebP  │         │ 24 items                         │
  │ 2  Resize   ≤ 2400 px    │ applied │   each: planned output + status  │
  │ 3  Metadata strip GPS    │────────▶│ Journal: source ↔ output ↔ backup│
  │ 4  Rename   web-{index}  │         │ Undoable for 30 days             │
  └──────────────────────────┘         └──────────────────────────────────┘
```

| Concept | Definition |
|---|---|
| **Recipe** | An ordered list of enabled steps, saved as a preset. Built-in or user-created. |
| **Preset** | A named recipe plus its destination defaults (suffix, collision policy). Applying a preset updates the inspector. |
| **Run** | One execution of a recipe over a batch. Immutable once started: it stores a snapshot of the recipe used. |
| **Item** | One input file in the queue, with its plan, status, and result. |
| **Plan** | The computed outcome for an item: output path, estimated bytes, warnings. Recomputed whenever the recipe or destination changes. |
| **Journal** | The durable record of every write: source, output, recovery location, hashes, status. Powers Undo and crash recovery. |
| **Recovery store** | App-managed folder holding originals that were replaced by a run. Lives in Application Support, scoped to the run. |

### 5.1 Invariants

- No file is written that did not appear in the preview with a concrete output path.
- The preview is revalidated at write time. If the destination changed since planning (a new collision, lost permission, missing source), the item stops with a stated status rather than silently writing a different name.
- Input originals are never deleted by the app. They are either untouched or moved to the recovery store. Existing files at a destination are only moved to the Trash by an explicit Replace policy.
- Every write is atomic: temp file in the destination folder, then an atomic replace. A crash never leaves a half-written output at a user-visible path.
- A run's recipe snapshot never changes, even if the preset is edited later.
- Undo is itself recorded, so the journal always describes the current state of the world.

---

## 6. Information architecture

```
FileFormatter
├── Main window
│   ├── Sidebar: Built-in presets · My presets · Recent runs
│   ├── Queue: summary strip, file table, filter field
│   ├── Inspector: recipe steps + step editors
│   └── Bottom bar: destination mode · save as preset
├── Completion sheet (after a run)
├── Recent run detail (sheet)
├── Settings (⌘,)
├── Menu bar extra (progress + quick actions)
└── System surfaces: Services menu, Shortcuts actions, notifications, Dock drop
```

- **Recipes live in the sidebar.** Selecting one updates the inspector and recomputes the preview. Nothing is applied until Run.
- **The queue is the workspace.** It is always the center pane, never replaced by a full-screen setup wizard.
- **The inspector edits the recipe in place.** It can be collapsed (⌥⌘I) for a wider queue.
- **Destination is global to the batch**, so it sits in the bottom bar where it is always visible, rather than inside the recipe.

---

## 7. Primary flows

### Flow A — Planned batch (the core loop)

1. User drops files or a folder onto the window, or presses ⌘O / ⇧⌘O.
2. The queue appears immediately. File metadata (kind, dimensions, size, encoding) loads incrementally in the background.
3. The last-used preset is applied. Rows show planned output names and approximate sizes.
4. Blocking issues are surfaced in a banner above the table (collisions, unwritable destination, insufficient space). Non-blocking issues (unsupported, skipped, not downloaded) are marked in the row and do not block.
5. User resolves issues inline or adjusts the recipe in the inspector. The affected rows update live.
6. User presses **Run 22** (⌘↩). If a blocking issue remains, the app focuses the first one instead of running.
7. The toolbar becomes a progress indicator. Rows update as each file completes. The app stays fully responsive.
8. Completion sheet: counts, bytes saved, failures, **Reveal in Finder**, **Undo Run**, **Done**.
9. The run is listed in Recent Runs with its recipe snapshot and undo availability.

**Done when:** every file that can be processed has an output, every file that can't has a stated reason, and the user can undo the whole thing.

### Flow B — Quick action from Finder

1. User selects files in Finder and chooses **Services → Format with FileFormatter**, or runs the equivalent Shortcuts action.
2. The last-used preset is applied. A compact progress panel appears with the preset name and a Cancel button; if the user has no preset yet, the main window opens instead.
3. On completion, a notification offers **Reveal** and **Undo**.
4. The run is recorded in history like any other run.

**Done when:** the user never has to see the main window for a repeat operation.

### Flow C — Save a reusable preset

1. User configures steps in the inspector.
2. ⌘S or **Save as Preset…** in the bottom bar.
3. Sheet: name, optional keyboard shortcut (⌘1–⌘9), destination defaults (suffix, collision policy), **Save**.
4. Preset appears under **My Presets**; selecting it applies it to the current queue without clearing files.

**Done when:** the same transformation can be reapplied in two clicks.

### Flow D — Undo a run

1. From the completion sheet or Recent Runs, choose **Undo Run**.
2. Confirmation states exactly what will happen, with counts for generated files and restored originals (for example: "22 generated files will move to the Trash. 22 replaced originals will be restored." When originals were kept, only the first sentence appears.)
3. Undo proceeds item by item, with progress. Failures are listed with a reason and a **Reveal** action.
4. The run is marked **Undone** in history. It cannot be undone again, but the trashed outputs can be recovered from the Finder Trash.

**Done when:** the pre-run state is restored, or the user knows precisely which files could not be restored and why.

---

## 8. Screen specifications

> Wireframes show structure, hierarchy, and state — not final visual polish. Native controls replace the bracketed placeholders in the real build.

### 8.1 Main window anatomy

- **Default size** 1080 × 680 pt; minimum 880 × 560 pt.
- **Toolbar (unified):** sidebar toggle, title "FileFormatter", flexible space, **Add Files** (＋), **Run** (prominent, accent). During a run, Run is replaced by a circular progress control and the count.
- **Sidebar** 240 pt, collapsible:
  - `PRESETS` — built-in recipes, each with a shortcut hint.
  - `MY PRESETS` — user recipes.
  - `RECENT RUNS` — last 10, with date, file count, and a small undo affordance in the detail view.
  - Footer: **＋ New Preset**.
  - Built-in presets are read-only. Context menu: **Duplicate**, **Assign Shortcut**; user presets add **Rename** and **Delete**.
- **Queue** — summary strip, issue banner, table, empty/filter states.
- **Queue persistence:** an unfinished queue is restored on next launch with its preset and destination intact. After a completed run, rows remain until the user clears them or adds files, so **Run Again** is always available.
- **Inspector** 320 pt, toggle ⌥⌘I: recipe header, ordered steps, **＋ Add Step**, live example.
- **Bottom bar** 32 pt: destination mode and suffix on the left; **Save as Preset…** (⌘S) on the right.

### 8.2 Empty state

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ◀ ▶   FileFormatter                                  [＋ Add Files]   [▶ Run]     │
├──────────────────┬────────────────────────────────────────────────────────────────┤
│ PRESETS          │                                                                │
│ Web Images    ⌘1 │                                                                │
│ Compress PDF  ⌘2 │                              ↓                                 │
│ Clean Text    ⌘3 │                                                                │
│ Photo Archive    │                     Drop files to format                       │
│                  │                                                                │
│ ＋ New Preset     │             See every change before it happens.                │
│                  │                     Originals stay safe.                       │
│ RECENT RUNS      │                                                                │
│  No runs yet     │            [ Choose Files… ]   [ Choose Folder… ]              │
│  —               │                                                                │
│                  │          Try a preset:  Web Images · Compress PDFs             │
│                  │                         · Clean Text                           │
│                  │                                                                │
│                  │             No uploads. Nothing leaves this Mac.               │
│                  │                                                                │
└──────────────────────────────────────────────────────────────────────────────────┘
```

- Headline: **Drop files to format** (`.title2`, semibold).
- Subhead: **See every change before it happens. Originals stay safe.**
- Primary action **Choose Files…**, secondary **Choose Folder…**.
- Preset shortcuts act as a teaching device: choosing one populates the inspector and leaves the queue empty, with a hint "Drop files to apply this preset."
- Run is disabled until there is at least one actionable item.
- Recent activity appears in the sidebar once a run exists; the center stays a drop target.

### 8.3 Review state

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ◀ ▶   FileFormatter                                       [＋ Add Files]   [▶ Run 22] │
├──────────────────┬────────────────────────────────────────────┬──────────────────────┤
│ PRESETS          │ 24 files · 1.24 GB  →  ≈412 MB             │ FORMAT               │
│ Web Images    ⌘1 │                                            │ 1  Convert      [on] │
│ Compress PDF  ⌘2 │     File              Size   →  Becomes    │    HEIC → WebP       │
│ Clean Text    ⌘3 │ ────────────────────────────────────────── │    Quality 80%       │
│ Photo Archive    │ ☑   IMG_4821.HEIC   2.4 MB  →  web-01.webp │                      │
│                  │ ☑   IMG_4822.HEIC   2.1 MB  →  web-02.webp │ 2  Resize       [on] │
│ ＋ New Preset     │ ☐   scan_final.pdf   —         skipped     │    Long edge 2400    │
│                  │ !   IMG_4824.HEIC   2.9 MB  →  web-04.webp │    Don't enlarge     │
│ RECENT RUNS      │ ☑   IMG_4825.HEIC   3.0 MB  →  web-05.webp │                      │
│ Today 09:41   24 │ ☑   NY_0124.HEIC    4.1 MB  →  web-06.webp │ 3  Metadata     [on] │
│ Yesterday      8 │                                            │    Strip GPS + info  │
│ Mon           36 │ !  1 name collision · 1 skipped            │                      │
│                  │    Resolve before running                  │ 4  Rename       [on] │
│                  │                                            │    web-{index:02}    │
│                  │                                            │    → web-01.webp     │
├──────────────────┴────────────────────────────────────────────┴──────────────────────┤
│ Keep originals · Same folder, “-web” suffix                      Save as Preset…  ⌘S │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

- **Summary strip:** "24 files · 1.24 GB → ≈412 MB". Sizes use tabular figures. The estimate is prefixed ≈ until the run completes. Issues are summarized as a button: "1 name collision · 1 skipped".
- **Table columns:** include checkbox · original name (with kind glyph) · size · → · output name · status. The output name is where a rename preview lives; changed substrings get a subtle accent tint so patterns are scannable. Color is never the only signal — the full name is also in the VoiceOver label and the row detail.
- **Run count** reflects items that will actually be processed. If blockers remain, pressing it selects the first blocker and scrolls it into view rather than running.
- **Issue banner** appears above the table when blockers exist: one line, an action to review, and a "Keep both / Replace / Skip" choice applied to all. It does not use a modal alert.
- **Rows are calm by default.** Ready rows show no badge. Only exceptions (`skipped`, `name exists`, `unsupported`, `failed`) carry text and color.
- **Per-row actions** (context menu): Reveal in Finder, Quick Look, Skip/Include, Remove from Queue, Copy Output Path.
- **Filter field** (⌘F) filters by name or status once the queue exceeds 20 items.

### 8.4 Recipe inspector

| Step | Editor | Default |
|---|---|---|
| **Convert** | Format popup, quality slider (JPEG/WebP/HEIC), preserve animation (disabled in v1 for animated inputs) | Image: WebP 80; PDF: PDF; Text: UTF-8 |
| **Resize** | Long edge px, percentage, "Don't enlarge" checkbox | Long edge 2400, don't enlarge on |
| **Metadata** | Keep all / Strip GPS / Strip all; color profile preserve vs sRGB | Strip GPS; preserve profile |
| **Rename** | Pattern field with token menu, live example, case control, optional find & replace | `{preset}-{index:02}` |
| **Clean text** | Encoding, line endings, BOM, trailing whitespace, final newline | UTF-8, LF, strip BOM, trim, ensure newline |
| **PDF** | Compression level, strip metadata | Balanced, strip metadata on |

- Steps are reorderable by dragging the handle. Order is meaningful: convert before resize, rename last.
- A step can be disabled without deleting it. Disabled steps stay visible but dimmed.
- Each enabled step shows one collapsed line of parameters; clicking expands the editor inline (one expanded at a time).
- The footer shows a live example for the first file in the queue: `IMG_4821.HEIC → web-01.webp · 380 KB`.
- Adding an incompatible step (e.g., Resize on a PDF) is prevented: the step menu disables it with an explanation.
- **＋ Add Step** opens a grouped menu: Convert, Resize, Metadata, Rename, Clean Text, PDF.
- Editing any step recomputes the affected rows within 150 ms; a slow estimate may show a subtle placeholder that resolves, never a modal spinner.

### 8.5 Running and cancel

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ◀  FileFormatter                          ● 12 of 24 · 00:18 left                │
├──────────────────────────────────────────────────────────────────────────────────┤
│ 24 files · 1.24 GB                     [ Cancel ]                                │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░                        │
│                                                                                  │
│ ✓  IMG_4821.HEIC  →  web-01.webp                  380 KB                         │
│ ✓  IMG_4822.HEIC  →  web-02.webp                  340 KB                         │
│ ●  IMG_4823.HEIC  →  web-03.webp               converting…                       │
│ ·  IMG_4824.HEIC  →  web-04.webp                  waiting                        │
│ ·  IMG_4825.HEIC  →  web-05.webp                  waiting                        │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

- Progress is determinate and weighted by input bytes, not file count, so a 200 MB video (in a later release) doesn't finish "instantly."
- ETA appears after 5% and is smoothed; it is hidden rather than wildly wrong.
- Cancel stops scheduling immediately; the in-flight item finishes its atomic write. The completion sheet is titled **Stopped** and reports exactly how many files were processed.
- The window stays interactive: the user can inspect rows, open the output folder, or copy paths.
- Idle sleep is prevented during a run. If the Mac sleeps anyway, the run resumes and verifies each temp file before continuing.
- If the app quits or crashes, the journal marks the run **Interrupted**. Next launch shows a banner: "A run was interrupted. 12 of 24 files were formatted." Actions: **Review** and **Undo**.

### 8.6 Completion sheet

```
┌────────────────────────────────────────────────────────────┐
│                                                            │
│                   ✓  Formatting complete                   │
│                                                            │
│       22 files formatted              1.18 GB saved        │
│                   1 skipped  ·  1 failed                   │
│                                                            │
│    [ Reveal in Finder ]   [ Undo Run ]          [ Done ]   │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

- The success line never overstates: if zero files were processed, it says **Nothing was formatted** and offers the failure reasons.
- "Saved" is only shown when the total output is smaller than the input; otherwise show the new total instead.
- Failures expand into a list with file name, reason, and **Retry** / **Reveal** actions.
- **Undo Run** is available even after a partial or stopped run.
- **Done** returns to the queue, which now shows completed rows and a **Run Again** button.

### 8.7 Recent run detail

A read-only sheet showing:

- Run date, duration, preset name, and recipe snapshot (steps as they were).
- Counts: formatted, skipped, failed, undone.
- A table of items with source path, output path, before/after size.
- **Reveal in Finder**, **Undo Run** (if eligible), **Copy Report** (Markdown table), and **Delete Recovery Files** (destructive, confirmed).
- If recovery files have been evicted or deleted, Undo is disabled with the reason shown inline.

### 8.8 Settings

| Tab | Contents |
|---|---|
| **General** | Default preset; show menu bar item; notifications; confirm before quitting with an active run |
| **Images** | Default output format and quality; preserve color profile; strip metadata default |
| **Output** | Default destination mode; suffix; collision default; preserve folder structure |
| **Recovery** | Retention (7 / 30 / 90 days), size cap, open recovery folder, clear all recoveries |
| **Advanced** | Concurrency, stop on first error, reset warnings, diagnostics export |

No account tab. No "upgrade" tab in a paid app.

### 8.9 Menu bar extra

- Default **off**; offered once after the first successful run ("Keep FileFormatter in the menu bar for quick drops?").
- Shows a progress ring during a run. Clicking opens a small menu: run status, **Cancel**, **Open FileFormatter**, **Recent Runs**, **Hide Menu Bar Icon**.
- The icon is monochrome and template-rendered; it must read at 18 pt.

### 8.10 Notifications

- One notification per completed run, never per file.
- Title: **22 files formatted**. Body: **1.18 GB saved · 1 skipped, 1 failed**.
- Actions: **Reveal**, **Undo**. Respect Focus and the user's notification settings; do not notify for runs under 2 seconds while the app is frontmost.

### 8.11 Onboarding

No carousel, no account, no permissions wall. The first launch is the empty state, which teaches the whole product in one screen: drop files, preview, run. After the first run, one optional tip points at presets and the menu bar. A "Try with sample files" link generates six small demo images in a temporary folder so the user can feel the preview without risking real files; the folder is deleted when the run is undone or after 24 hours.

---

## 9. Components and content

### 9.1 Status taxonomy

| Status | Meaning | Presentation | Available action |
|---|---|---|---|
| **Ready** | Will be processed | Neutral; no badge | — |
| **Skipped** | Excluded by the user | Dimmed, "Skipped" | Include |
| **No change** | Recipe produces an identical file | Dimmed, "No change" | — |
| **Name exists** | Output path already exists | Orange "Name exists" | Keep both / Replace / Skip |
| **Duplicate output** | Two items map to the same output | Orange "Same output" | Keep both / Skip |
| **Not downloaded** | iCloud placeholder | Blue "Not downloaded" | Download |
| **Unsupported** | Format not handled in v1 | Orange "Unsupported" | Remove |
| **Password-protected** | Locked PDF | Orange "Locked" | Remove |
| **No space** | Preflight failed | Red "Not enough space" | Choose destination |
| **Changed on disk** | Source modified since import | Orange "Changed" | Re-scan |
| **Not processed** | Run stopped before this item | Dimmed | Run again |
| **Failed** | Error during processing | Red "Failed" + reason | Retry / Reveal |
| **Formatted** | Completed successfully | Green check, plain label | Reveal / Undo |

Rules:

- Every status has a text label; color is supplementary.
- Only exceptions and completions get color. A queue of ready files is visually quiet.
- Row detail (click or ⌘I) explains *why* a status occurred and what to do next.

### 9.2 Rename engine

| Token | Meaning | Example |
|---|---|---|
| `{name}` | Original base name | `IMG_4821` |
| `{index}` / `{index:02}` | Position in queue, optionally zero-padded | `7` / `07` |
| `{date}` | Capture date if present, else modified date (ISO 8601) | `2026-10-18` |
| `{folder}` | Parent folder name | `Nova Branding` |
| `{preset}` | Preset slug | `web` |
| `{width}` / `{height}` | Output pixel dimensions | `2400` / `1600` |
| `{ext}` | Output extension, without dot | `webp` |

Rules:

- Filenames are always preserved in their original script; no transliteration by default.
- Illegal characters (`/`, `:`, NUL) are replaced; leading dots and trailing spaces are trimmed.
- The 255-byte name limit is enforced per component, with a warning rather than a silent cut.
- Case options: keep, lowercase, Title Case, UPPERCASE. Find & replace is literal, case-sensitive by default, with a toggle.
- The preview is authoritative: if the engine and the preview disagree, that is a release blocker.
- `.DS_Store`, hidden files, symlinks, aliases, and packages are ignored by default, with an explanation in the import summary.

### 9.3 Collision policy

| Policy | Behavior |
|---|---|
| **Keep both** (default) | Append ` 2`, ` 3`, … to the output name; preview shows the exact result |
| **Replace** | Existing file moves to the Trash, then the new output is written atomically; originals in replace mode go to the recovery store |
| **Skip** | Leave the existing file untouched; mark the item skipped |

- The policy is chosen per batch in the issue banner or bottom bar, and saved per preset.
- Replace is never silent and is never the default.
- Case-insensitive volumes are handled explicitly: `A.jpg` and `a.JPG` collide on macOS by default.
- Before each write, the destination is re-checked. A collision that appeared after planning stops that item as **Name exists**; it is never resolved by silently numbering at write time.

### 9.4 Destination modes

1. **Same folder, suffix** (default): `IMG_4821.HEIC` → `IMG_4821-web.webp`; originals untouched.
2. **Same folder, "Formatted" subfolder**: keeps the source folder tidy.
3. **Chosen folder**: preserve the relative folder structure when a folder was dropped (toggle on by default); collision policy still applies.

The bottom bar always shows the effective mode and suffix, and the row detail shows the full output path.

**Folder drops are recursive.** Hidden files, packages, symlinks, and aliases are skipped, with a summary in the import banner. When writing to a chosen folder, the structure relative to the dropped folder is preserved by default; the toggle lives in the destination popover. Empty folders are not recreated.

### 9.5 Progress and error copy

- Buttons name the action: **Run 22**, **Cancel**, **Undo Run**, **Reveal in Finder** — never "OK" or "Submit".
- Errors follow: **what happened → why → what to do.**  
  Example: "IMG_4824.HEIC couldn't be converted. Its color profile is damaged. Try opening it in Preview, or skip it."
- Estimates are labeled ≈. Totals use `ByteCountFormatter` with tabular figures.
- Empty states say what to do, not just what's missing.
- No exclamation-mark alerts for recoverable problems; use the issue banner and row status.

---

## 10. Design language

**Overall:** current native macOS, calm and utilitarian. The queue is the protagonist; chrome recedes.

- **Type:** SF Pro throughout. `.title2` semibold for the empty-state headline, `.headline` for section labels, `.body` for content, `.caption` for secondary metadata. Byte sizes and before/after values use monospaced digits. SF Mono only for paths and rename tokens in advanced contexts.
- **Layout:** 8 pt spacing grid (4 pt for tight groups); 32 pt table rows; standard system control heights. Sidebar 240 pt, inspector 320 pt, both resizable within limits.
- **Color:** system accent for selection and the primary button. Status colors are the system orange/red/green/blue, always paired with text. Never a custom background wash behind status. Test both appearances and Increase Contrast.
- **Materials:** system sidebar material and standard window background; no custom blur, no translucent cards over content, no heavy shadows. Depth comes from the split view, not from decoration.
- **Shape:** system corner radii and continuous curves. The app uses no "cards"; steps and rows are separated by dividers.
- **Iconography:** SF Symbols, consistent weight and scale. Format glyphs carry meaning (photo, doc, text.alignleft); the warning glyph is reserved for blocking issues.
- **Motion:** 120–180 ms ease-out for row insertion and status changes; no bounce. Progress updates are throttled to 10 Hz. Reduce Motion swaps slides for crossfades.
- **App icon:** a single sheet of paper with three misaligned bars snapping into a neat column, one bar in the accent color. No text, no gloss, legible at 16 pt, works on light and dark backgrounds.
- **Dark mode:** first-class. No pure-black surfaces; images and thumbnails get a subtle hairline border so transparent PNGs remain visible.

---

## 11. Accessibility and localization

- **Keyboard:** every action is reachable without a pointer; the queue supports arrow navigation, Space for Quick Look, and ⌘⌫ to remove.
- **VoiceOver:** each row announces `"IMG_4821.HEIC, 2.4 megabytes, will become web-01.webp, about 380 kilobytes, ready."` Status changes are announced once per batch transition, not per file.
- **Color independence:** Verify with Differentiate Without Color. Status text always accompanies color.
- **Motion and contrast:** respect Reduce Motion and Increase Contrast; meet 4.5:1 for all status text in both appearances.
- **Hit targets:** use system control sizes; never shrink a button below the platform minimum.
- **Text scaling:** no fixed-height labels that clip when the user increases system text size.
- **Localization:** all strings externalized, base English. RTL layouts mirror the split view and toolbar. Filenames are never translated or transliterated. `{date}` tokens use ISO 8601 by default with a locale-aware option. Byte counts and numbers use system formatters.
- **Voice Control:** stable names for **Run**, **Add Files**, **Undo Run**, and **Restore**.

---

## 12. Edge cases and resilience

| Situation | Behavior |
|---|---|
| Two inputs produce the same output name | Blocking banner; Keep both / Skip; preview shows the numbered result |
| Output file already exists | Per collision policy; Replace moves the old file to the Trash |
| Source changed after import | Re-stat before processing; mark **Changed on disk** and skip rather than applying a stale plan |
| Source deleted mid-run | Mark **Failed — file no longer exists**, continue with the rest |
| iCloud file not downloaded | Mark **Not downloaded**; explicit **Download** action; never download silently |
| Destination is read-only | Preflight blocks Run; message names the folder and offers **Choose Another Folder…** |
| Disk space insufficient | Preflight requires estimated output × 1.2; block before writing anything |
| Disk fills mid-run | Stop cleanly, mark remaining items **Not processed**, keep the journal valid |
| App crash or forced quit | Journal marks the run interrupted; next launch offers Review and Undo |
| System sleep | Prevent idle sleep; on wake, verify temp files and resume |
| 5,000+ files | Virtualized table, background metadata, estimate warning above 1,000 files; UI remains responsive |
| File has no extension or wrong type | Sniff with UTType; show detected kind; warn if it disagrees with the extension |
| Name is too long or contains illegal characters | Sanitize, show the warning in the preview, never silently truncate |
| Case-insensitive collision on APFS | Detect and treat as a collision |
| Corrupt or zero-byte file | Mark Failed with a concrete reason; continue the batch |
| Password-protected PDF | Mark **Locked**; skip; never prompt for a password mid-batch |
| Symlink, alias, or package | Ignored by default; import summary explains why |
| Animated GIF/WebP/HEIC | v1 takes the first frame and badges the row; animation preservation is deferred |
| Wide-gamut image converted to sRGB | Warn once in the step editor; default is to preserve the profile |
| External or network volume ejected | Stop the run, mark affected items failed, keep journal consistent |
| Extremely large image | Memory guard fails gracefully instead of swapping the machine; reason explains the limit |
| Output moved or edited after a run | Undo detects the missing or modified file, skips it with a reason, and restores the rest; a modified output is never overwritten silently |
| Folder contains a symlink loop | Skipped during the scan; no traversal |

---

## 13. Keyboard and menus

| Shortcut | Action |
|---|---|
| ⌘O | Add files |
| ⇧⌘O | Add folder |
| ⌘⌫ | Remove selected from queue |
| Space | Quick Look selected item |
| ⌘↩ | Run |
| ⌘. | Cancel run |
| ⌘S | Save as preset |
| ⌘F | Filter queue |
| ⌥⌘I | Show/hide inspector |
| ⌘1–⌘9 | Apply preset |
| ⇧⌘R | Reveal output in Finder |
| ⌘, | Settings |
| ⌘? | Help |

Menu bar: **File** (Add Files, Add Folder, Save as Preset, Close), **Edit** (standard, plus Remove from Queue), **View** (Sidebar, Inspector, Filter), **Format** (Run, Cancel, Skip/Include, Reveal, Undo Run), **Window**, **Help**.

Undo/Redo remain reserved for text editing. **Undo Run** deliberately does not use ⌘Z: undoing a batch is a deliberate, confirmable action, not an accidental keystroke.

---

## 14. Technical feasibility and risks

**Recommended shape**

- SwiftUI shell with AppKit bridges for the file table where needed, Quick Look (`QLPreviewPanel`), open panels, and the menu bar extra.
- Target the previous major macOS release (N−1) at launch; build with the current SDK and adopt current system design language with availability checks.
- Swift Concurrency pipeline: planning actor, a bounded execution pool (`min(activeProcessorCount − 1, 8)`), per-item cancellation, atomic writes via a temp file in the destination volume followed by an atomic replace.
- ImageIO for decode/encode, Core Image for resize and color conversion, PDFKit/Core Graphics for PDFs, `NSString` encoding detection plus heuristics for text.
- Journal in SQLite (WAL) under Application Support; recovery store on the same volume as the destination when possible so originals can be moved, not copied.
- Security-scoped bookmarks for the chosen destination; no Full Disk Access required.
- App Intents and Services for the quick action; Finder Sync is a later target.
- No network entitlement in v1.

**Risks**

| Risk | Impact | Mitigation |
|---|---|---|
| Preview doesn't match execution | Breaks the core promise | Single planning engine used by both; golden-fixture tests comparing plan to output |
| PDF compression rasterizes text | Quality regression users will notice | Downsample embedded images only; if that slips, defer compression to v1.1 and ship images → PDF |
| WebP encode is not available through ImageIO | WebP output silently missing | Bundle libwebp (BSD); AVIF and HEIC are native on current macOS |
| Bundling a GPL codec build (e.g. Homebrew FFmpeg) | Copyright exposure if shared | Build LGPL-only; never ship the Homebrew binary; use VideoToolbox/AudioToolbox for H.264/HEVC/MP3/AAC |
| Users fear irreversible changes | Low trust, low trial | Default "keep originals", 30-day undo, explicit confirmation copy, no silent Replace |
| Very large batches | Perceived slowness | Incremental metadata, virtualization, byte-weighted progress, honest estimates |
| Recovery store grows unbounded | Disk pressure | 10 GB cap with oldest-first eviction and a visible setting |

**Test strategy:** table-driven tests for the rename engine; plan-vs-output golden tests for every format family; restore round-trip tests; sandbox and external-volume matrix; 5,000-item performance test; accessibility audit with VoiceOver and keyboard only.

---

## 15. Privacy and trust

- No network requests in v1. No accounts, no analytics SDK, no crash-report upload without opt-in.
- Files are processed locally; metadata stripping is explained in context ("Removes GPS location and camera identity").
- Recovery files are stored in plaintext on disk, like any file; the app explains this and offers **Delete Recovery Files** per run and **Clear All Recoveries** in Settings.
- No filename or path ever leaves the device. If opt-in metrics ship later, they are aggregate counters only (see §16).
- App Store privacy label: **Data Not Collected** while telemetry is off by default.

---

## 16. Success metrics

Targets are hypotheses to validate, not commitments.

| Metric | Target | Notes |
|---|---|---|
| Time to first successful batch | < 90 s median | From first drop to completion |
| Preview accuracy | 100% | Every executed change matches the plan |
| Undo success | ≥ 99.9% | Verified by round-trip tests and production journal |
| Crash-free sessions | ≥ 99.5% | |
| Preset reuse | ≥ 40% of runs use a saved preset | Signal that recipes are the right abstraction |
| Batch size | Median ≥ 10 files | Confirms the batch use case |
| Support contacts | < 5 per 1,000 runs | |

If telemetry is enabled (opt-in, anonymous): `run_started`, `run_completed` with counts and format family, `preset_created`, `undo_completed`, `issue_shown` by status type. No filenames, paths, sizes, or per-file data.

---

## 17. Release plan

| Release | Contents |
|---|---|
| **v1.0** | Images, PDFs, text; recipes and presets; preview; atomic runs; journal and undo; recent runs; menu bar progress; Services and Shortcuts quick action; notifications; Settings |
| **v1.1** | Audio; duplicate detection; per-file overrides; preset import/export; Finder Sync; JSON/XML formatting; combine PDFs |
| **v1.2** | Video; folder watching; improved PDF compression options |
| **Later** | Team preset sharing; CLI companion; AppleScript/Shortcuts automation recipes |

Indicative build for v1.0: 8–12 weeks for one experienced macOS developer, including tests and accessibility. The riskiest item is PDF compression; keep it behind a scope gate.

---

## 18. Acceptance criteria

**Preview**

- [ ] Every queued file shows original name, kind, size, planned output name, and status without opening a detail view.
- [ ] Changing any step updates affected rows within 150 ms and never blocks the main thread.
- [ ] A blocking issue prevents a run and points to the first actionable row.
- [ ] Non-blocking issues are visible but do not require interaction.

**Run**

- [ ] No write occurs outside the planned output paths.
- [ ] Cancelling leaves no temp files, and completed outputs remain valid.
- [ ] Crash or quit mid-run produces an **Interrupted** record and a clear recovery path.
- [ ] Disk-space and permission preflights block before the first write.

**Undo**

- [ ] Undo restores the pre-run state for every successful item in both keep-originals and replace-originals modes.
- [ ] Undo after a partial or cancelled run restores exactly the files that were written.
- [ ] Undo is unavailable, with a stated reason, when recovery files have been evicted.
- [ ] Trashed outputs are recoverable from the Finder Trash.

**Accessibility**

- [ ] All actions are reachable by keyboard alone.
- [ ] VoiceOver reads each row's name, size, planned output, estimated size, and status.
- [ ] Status is understandable with color removed.
- [ ] Reduce Motion and Increase Contrast are respected.

**Performance**

- [ ] 500 files import and render in under 500 ms on a base Apple-silicon Mac (metadata may continue loading).
- [ ] The UI does not block for more than 100 ms during a run.

---

## 19. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Is v1 limited to images, PDFs, and text? | **Yes.** Audio and video are v1.1 and should not delay the core loop. |
| D2 | Default for originals: keep or replace? | **Keep originals**, with a suffix. Replace is available and explicitly chosen. |
| D3 | Default collision policy | **Keep both**; never silent replace. |
| D4 | Recovery retention and cap | **30 days / 10 GB**, oldest-first eviction with a visible warning. |
| D5 | Distribution | **Mac App Store first** (sandboxed, trust, easy updates); notarized direct download later if needed. |
| D6 | Minimum macOS | **Previous major release (N−1)** at launch. |
| D7 | Pricing | **One-time purchase** ($19–29) with paid major upgrades; utilities resist subscriptions. |
| D8 | App name | **Verify trademark and App Store availability before branding.** "FileFormatter" is descriptive and may already be in use. |
| D9 | Sample files on first run | **Yes**, six generated images in a temp folder, clearly labeled and auto-deleted. |
| D10 | Telemetry | **Off by default**; opt-in anonymous aggregates only. |

---

## 20. Recommended next step

This document defines the product and the interaction model. Two good ways to continue:

1. **High-fidelity UI mockups** of the empty, review, running, completion, and Settings states — useful for validating table density and the inspector before writing code.
2. **A SwiftUI scaffold** with the planning engine and rename tests stubbed against the spec — useful for validating the risky parts (preview accuracy, atomic writes, journal/undo) early.

Recommendation: mockups first, limited to the review state and the run/undo loop, then build the planning engine against those fixtures.
