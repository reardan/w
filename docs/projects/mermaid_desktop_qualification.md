# Mermaid editor: native Windows and macOS qualification

This is the checklist for qualifying `wmermaid_editor` on real Windows and
macOS machines (issue #822). Linux qualification runs in CI and containers
(`mermaid_editor_ui_test`, `mermaid_editor_atspi_test`,
`mermaid_editor_orca_test`; see [mermaid.md](mermaid.md)). The Windows build
is also qualified under wine on a Linux host with real input events (next
section). Wine is not a native run, though: it has no DWM, Explorer, real
IME, OneDrive or screen reader. Nothing below has been run on real Windows or
macOS yet. Record results in the tables at the end, and update the platform
rows in [mermaid.md](mermaid.md) and
[mermaid_compatibility.md](mermaid_compatibility.md) from them.

## Windows build under wine (done on Linux)

`./wbuild mermaid_editor_wine_test` (opt-in; needs wine, Xvfb, libX11 and
libXtst) runs `tools/mermaid_editor_wine_test.sh`. The script starts Xvfb and
a private wine prefix (`bin/mermaid-wine-prefix-<dpi>`; `~/.wine` is never
used), then drives `bin/wmermaid_editor_win.exe` with
`tools/mermaid_editor_ui_driver.w --wine`. That is the same XTest driver as
the Linux workflow, so the pointer and key events are real X11 input. Wine's
X11 driver turns them into Win32 messages (`WM_KEYDOWN`/`WM_CHAR`,
`WM_MOUSEMOVE`, button messages), so this exercises:
- the win32 window backend and WGL;
- the wide-character file API (see [windows.md](windows.md), "UTF-8 paths");
- the editor's compare-and-swap saves, as the Windows build runs them.

It runs every workflow twice: at 96 DPI (100%), and at 144 DPI (150%,
`LogPixels`) with every pointer coordinate scaled by 1.5. Both pass
(wine 9.0, 2026-10-26, about 150 s for both runs):

| Checklist step | Under wine |
| --- | --- |
| 1.1, 1.3 startup, rendering, `--screenshot` | pass (P6 at 1280x800; 1920x1200 at 150%) |
| 2.1–2.8 click, drag, Escape cancel, Move here, Link to, Tab/Shift+Tab, arrows, Delete, rename, undo/redo chains | pass, at both scales, in flowchart, ER, class, state, groups, multi-selection (Space, Ctrl+A, Shift+drag band), C4, block, kanban and the class-member inspector |
| 2.9 source typing | pass for ASCII; a real IME needs Windows |
| 2.10 clipboard | not implemented on any backend (#850) |
| 3.1–3.4 DPI | at 150%: logical layout unchanged, text rasterized at device resolution, hits land on the right node, screenshot at physical size. Per-monitor moves (`WM_DPICHANGED`) need two real monitors |
| 4.1–4.3 saves, CRLF, non-ASCII folder ("Qualification Ü"), path over 260 characters | pass |
| 4.4 read-only file | pass: the save is refused, the editor stays dirty, and the save succeeds once the file is writable |
| 4.5–4.8 external change, Keep mine, Reload, deletion | pass |
| 4.9–4.10 locked file, OneDrive, FAT | needs Windows |
| 5 Narrator/NVDA | needs Windows; `mermaid_canvas_uia_test` reads the canvas through wine's UIA client |

Running the wine workflow found three Windows bugs, all fixed:
- **ANSI file APIs.** The win64 runtime called `CreateFileA` and friends, and
  read argv through `GetCommandLineA`. A path outside the system code page
  ("Qualification Ü") could not be opened. The runtime now uses the wide API
  and the `\\?\` long-path form.
- **Read-only files were replaced.** A save replaces the file by rename, and
  both POSIX and Windows let a read-only file be renamed aside, so the save
  silently replaced it (reproduced on Linux). `mm_save_cas` now refuses to
  save over a file it cannot open for writing (`MM_SAVE_FAILED`, the editor
  stays dirty).
- **Bitmap-stretched windows.** The win32 backend was DPI-unaware, so Windows
  would have stretched the window at 150%/200%. It now declares per-monitor
  DPI awareness (v2 where available) and works in logical pixels with a
  device-pixel viewport, like the web backend. `gfx_window_pixel_ratio`
  reports DPI/96, the IME caret position and UI Automation bounds and hit
  tests are scaled to device pixels, and `--screenshot` writes the physical
  size.

Each step says what to do and what should happen. A step passes only when
everything under **Expect** happens. Note anything else under the step.

## Build and setup

On a Linux checkout (or `./wbuild --remote=w` from a Mac):

```sh
./wbuild mermaid_editor_platforms
# bin/wmermaid_editor_win.exe            Windows x64
# bin/wmermaid_editor_darwin             macOS arm64, no accessibility bridge
# bin/wmermaid_editor_darwin_voiceover   macOS arm64 with NSAccessibility
```

The VoiceOver build is the same program compiled with
`bin/wv2 arm64_darwin --import-root tools/mac/access_cocoa tools/wmermaid_editor.w`.
It loads `@executable_path/libwaccessibility.dylib` at startup. On the Mac, run
`tools/mac/build_accessibility.sh` (Xcode command line tools), which writes
`bin/libwaccessibility.dylib` and runs the companion's own tests. Keep the
dylib beside the executable. The compiler self-signs Mach-O output. If a
re-copied binary is killed at launch, copy it to a fresh file name first
(the vnode issue described in `tools/mac/run_darwin_tests.sh`).

Create a working folder with these two files (LF line endings, UTF-8):

`flow.mmd`

```
%% qualification
flowchart LR
subgraph S[Shop]
A[Alpha]
end
A -->|pays| B[Beta]
B --> C[Gamma]
```

`er.mmd`

```
erDiagram
CUSTOMER ||--o{ ORDER : places
ORDER ||--|{ LINE : contains
```

Also keep a copy of `flow.mmd` saved with CRLF line endings as `crlf.mmd`,
and a copy in a folder whose path contains a space and a non-ASCII letter
(for example `Qualification Ü/flow.mmd`). On Windows, also make one under a
path longer than 260 characters.

Shortcut names below use Ctrl. On macOS, check each with Cmd as well; both
are accepted where the backend reports them.

## 1. Startup and rendering (both platforms)

1. Launch `wmermaid_editor flow.mmd` from a terminal.
   **Expect:** a window titled "W Mermaid" within 2 s; the source on the left,
   the diagram on the right with a "Shop" group containing Alpha, edges
   labeled "pays" and an unlabeled one; status line text at the bottom; no
   console errors.
2. Resize the window from small (about 800x600) to maximized.
   **Expect:** the layout reflows, text stays sharp, nothing is clipped
   outside its pane, and the diagram stays centered after **Fit**.
3. Run `wmermaid_editor flow.mmd --frames 3 --screenshot shot.ppm`.
   **Expect:** exit status 0 and a non-empty `P6` image showing the editor.

## 2. Input

1. Click Beta. **Expect:** a blue selection outline on Beta; the inspector shows
   "Selected node", ID `B`, label `Beta`.
2. Drag Beta about 100 px right and release. **Expect:** edges follow while
   dragging; on release the source gains `%% @w-position "B" ...`; Ctrl+Z
   removes it in one step; Ctrl+Shift+Z and Ctrl+Y redo it.
3. Drag Beta, press Escape before releasing. **Expect:** Beta returns; source
   unchanged.
4. Drag the empty canvas. **Expect:** the view pans; the source is unchanged.
5. Mouse wheel and trackpad scroll over the canvas. **Expect:** zoom anchored
   under the pointer, in both directions, with no jumps. On a Mac trackpad,
   two-finger scroll zooms smoothly (pixel deltas).
6. Ctrl+D, then Tab, Tab, Shift+Tab. **Expect:** selection moves Alpha → Beta →
   Alpha (groups are skipped); arrows move the selected node 1 px, Shift+arrows
   10 px; each move is one undo step.
7. With a node selected on the canvas, Delete. **Expect:** the node and its
   edges disappear; Ctrl+Z restores the exact source.
8. Ctrl+R, type a new label, Ctrl+Enter. **Expect:** the label changes in the
   canvas and in the source, other bytes unchanged, one undo step. (Ctrl+A in
   the label field selects all first.)
9. Ctrl+E, type in the source, including a non-ASCII word via the platform
   input method (Windows: a Japanese or Chinese IME; macOS: the Japanese
   input source and the Option-e dead key for "é"). **Expect:** the
   composition shows underlined at the caret and commits correctly; the
   preview updates; continuous typing undoes as one step.
10. In the source, select text, copy (Ctrl+C), paste (Ctrl+V) elsewhere and into
    another application, and paste text from another application in.
    **Expect:** clipboard round trips both ways, including non-ASCII text.
11. Ctrl+Q with unsaved changes. **Expect:** the Unsaved prompt; Cancel keeps
    editing; Discard closes without writing.

## 3. DPI and Retina scaling

Windows: run each step at 100%, 150% and 200% display scaling (Settings >
System > Display), and once moving the window between two monitors with
different scaling. macOS: run on the built-in Retina display and on a
non-Retina external display, moving the window between them.

1. **Expect:** text and lines are sharp (no blurry bitmap scaling), the UI is
   the same logical size at every scale, and nothing overlaps.
2. Click exactly on the edge of a node and on an edge line. **Expect:** hit
   testing matches what is drawn at every scale (the right node or edge is
   selected; clicks just outside select nothing).
3. Drag a node at each scale. **Expect:** the node stays under the pointer.
4. Take a `--screenshot` at 200% / on Retina. **Expect:** the image has the
   physical pixel size and shows the whole window.
5. (Accessibility check, done with section 5's tools) **Expect:** node bounding
   rectangles reported to Inspect / Accessibility Inspector cover the drawn
   nodes at every scale. A mismatch at 150%/200% points at logical versus
   physical coordinates in the bridge; record the factor.

## 4. Filesystem and saving

Watch the folder in Explorer/Finder (show hidden files) during this section.

1. Edit and Ctrl+S. **Expect:** status "Saved."; reopening shows the edit;
   the folder never shows leftover `*.tmp.*` or `*.claim.*` files afterwards.
2. Open `crlf.mmd`, move a node, save. **Expect:** the original CRLF lines are
   byte-identical; only the inserted position line is added.
3. Open the file under the space/non-ASCII path, and on Windows the >260
   character path, edit and save. **Expect:** both open and save; failures are
   reported in the status line, never silently.
4. Make the file read-only (Windows: Properties > Read-only; macOS:
   `chmod a-w`), edit, save. **Expect:** a save failure message; the editor
   stays dirty; the file is unchanged.
5. While the editor has an unsaved edit, change the file in another editor
   (Notepad / TextEdit / VS Code) and save it there. **Expect:** within about
   2 s the editor shows "Changed on disk: Reload from disk / Keep mine" and
   explains both in the status line. Ctrl+S then refuses ("Not saved: the file
   changed on disk") and the other editor's content stays on disk.
6. Choose **Keep mine** (or Ctrl+K), then save. **Expect:** the editor's
   version replaces the file; the other editor now reports a changed file.
7. Change the file externally again, choose **Reload from disk** (or
   Ctrl+Shift+R). **Expect:** the editor shows the disk version; undo history
   starts there.
8. Delete the file in Explorer/Finder. **Expect:** "Deleted on disk"; Save
   refuses; **Keep mine** then Save recreates it.
9. Save while another program holds the file open: Windows, open it in an
   application that keeps a handle (e.g. `powershell -c "$f=[IO.File]::Open('flow.mmd','Open','Read','Read'); Read-Host"`);
   macOS, `tail -f flow.mmd`. **Expect (Windows):** a save failure or
   conflict message, never a partial file; after the handle closes, Save
   works. **Expect (macOS):** the save succeeds; `tail` keeps showing the old
   file (it follows the old inode).
10. Save in a OneDrive (Windows) or iCloud Drive (macOS) folder and on a network
    share or USB drive (FAT/exFAT). **Expect:** saves succeed or fail with a
    message; no stray files remain after sync. FAT has no hard links, so the
    save falls back to an exclusive copy; record whether it works.
11. **Save as** to an existing file name. **Expect:** refused ("Save as needs a
    new destination path"); the existing file is unchanged.
12. **SVG** export. **Expect:** `flow.mmd.svg` beside the source opens in a browser
    and matches the preview.

## 5. Screen readers

Use the VoiceOver build on macOS. Start the screen reader before launching the
editor, then repeat once starting it after the editor is already open.

### Windows: Narrator and NVDA

Start Narrator (Win+Ctrl+Enter), later NVDA. Inspect or Accessibility
Insights for Windows can show the tree alongside.

1. Launch on `flow.mmd`. **Expect:** the window is announced; Inspect shows a
   Pane root (framework `W`) with the buttons, text fields, a **List** named
   "Diagram canvas" and a status text. The list's items are ListItems Shop (a
   Group), Alpha, Beta, Gamma, "Alpha to Beta: pays" and "Beta to Gamma",
   each with HelpText such as "node B, 1 outgoing, 1 incoming, movable".
2. Ctrl+D, then Tab. **Expect:** focus moves to the canvas and the selected
   node is announced by name, then its description (e.g. "Alpha, node A in
   Shop, 1 outgoing, 0 incoming"); Inspect's focus tracking highlights the
   node's rectangle on screen.
3. Tab, Shift+Tab, arrows. **Expect:** each Tab/Shift+Tab announces the newly
   selected node; arrow moves keep it selected.
4. Delete, then Ctrl+Z. **Expect:** the item disappears from Inspect's tree and
   returns after undo; Narrator does not read stale names.
5. Narrator item navigation (Caps Lock+Right) or NVDA object navigation
   (NVDA+Numpad 6) inside the canvas. **Expect:** every node and edge is
   reachable and read with its description.
6. In Inspect, on the "Alpha to Beta: pays" item, use the SelectionItem pattern
   Select (Action menu). **Expect:** the edge is selected on the canvas within a
   frame and becomes the focused element; IsSelected becomes true.
7. Use Accessibility Insights' FastPass on the window. **Expect:** record the
   reported failures (the bridge has no Text pattern, so source-text checks are
   expected to fail; record which others appear).

### macOS: VoiceOver

Start VoiceOver (Cmd+F5). Accessibility Inspector (Xcode > Open Developer Tool)
shows the tree.

1. Launch `bin/wmermaid_editor_darwin_voiceover flow.mmd`. **Expect:** VoiceOver
   announces the window; Accessibility Inspector shows the content view's
   children, including "Diagram canvas" and its items with help text.
2. Ctrl+D (or Cmd+D), Tab. **Expect:** VoiceOver speaks the selected node's
   name and description; the VoiceOver cursor outline covers the node.
3. VO+Right / VO+Left through the canvas. **Expect:** every node and edge is
   reachable; VO+Space on an item selects it on the canvas.
4. Delete and Ctrl+Z. **Expect:** the item list updates; VoiceOver does not read
   removed items.
5. Retina: the VoiceOver cursor and Inspector frames line up with the drawn nodes.
6. Launch `bin/wmermaid_editor_darwin` (no companion). **Expect:** the editor runs;
   VoiceOver sees only the window (no bridge), as documented.

## Results

Record date, OS version, hardware, display scaling and screen reader version.

| Step | Windows 11 | macOS |
| --- | --- | --- |
| 1. Startup and rendering | pending | pending |
| 2. Input | pending | pending |
| 3. DPI / Retina | pending | pending |
| 4. Filesystem and saving | pending | pending |
| 5. Narrator / NVDA | pending | n/a |
| 5. VoiceOver | n/a | pending |

Known risks to look at first:
- Shift+Tab on Windows comes from `WM_CHAR` Tab with Shift held. It works
  under wine; on X11 it needed a fix, and on macOS backtab is mapped.
- UIA bounds at 150%/200% scaling. The bridge now scales them by the window's
  DPI, which was checked under wine but not with Inspect.
- `WM_DPICHANGED` when a window moves between monitors with different
  scaling.
- Windows claim-by-rename failing while another program holds the file
  without delete sharing (step 4.9).
- FAT/exFAT volumes without hard links (step 4.10).
- Retina on macOS: the Cocoa backend still reports a pixel ratio of 1.
