# wdrive — driving native W graphics programs

`tools/wdrive.w` (`./wbuild wdrive` → `bin/wdrive`) lets an agent, a test
or a person steer a real, unmodified W graphics program: inject pointer,
wheel, key and text input, step frames, read pixels, take PNG
screenshots and read the graphics.ui accessibility tree — on a desktop
or headless under a private Xvfb. It is the native counterpart of a
browser-automation tool: where the web demos are driven through the DOM,
a native window is driven through an in-process control channel,
`graphics/control.w`, that every native window backend links.

Before this, screenshots existed only at exit (`--frames N --screenshot`
in `graphics/ui/demo.w` and `tools/wmermaid_editor.w`), and input
injection needed a per-app XTest driver
(`tools/mermaid_editor_ui_driver.w`).

## Quick start

```sh
./wbuild wdrive wdrive_fixture
bin/wdrive run --out /tmp/shots --steps '[
  {"cmd":"click_node","role":"button","name":"Paint"},
  {"cmd":"click_node","role":"textbox"},
  {"cmd":"text","text":"hello"},
  {"cmd":"assert_a11y","role":"textbox","value":"hello"},
  {"cmd":"screenshot","path":"after.png"}
]' -- bin/wdrive_fixture
```

Any program that opens a `graphics.window` works the same way, e.g.
`bin/wv2 x64 graphics/ui/demo.w -o bin/graphics_ui_demo` and then
`bin/wdrive run ... -- bin/graphics_ui_demo`.

## Architecture

```
wdrive ──listens── /tmp/wdrive-XXXX/control.sock ◄──connects── program
  │  spawns Xvfb :N (when there is no DISPLAY, or --xvfb)          │
  │  spawns PROGRAM with W_GFX_CONTROL=<socket> [DISPLAY=:N]       │
  │  NDJSON requests ───────────────────────────────────────────►  gfx_window_poll: input → gfx_input_queue
  │  NDJSON responses ◄─────────────────────────────────────────── gfx_window_swap: steps, glReadPixels, PNG
```

- **Activation.** The first `gfx_window_open` reads `W_GFX_CONTROL`;
  when it names a unix-domain socket path, the program connects to it as
  a client (the driver listens). Unset, `gfx_control_active()` is one
  pointer test per poll and swap and nothing else runs.
- **Backends.** `graphics/window_x11.w` (x64/arm64 Linux, tested for real
  under Xvfb), `graphics/window_win32.w` and `graphics/window_cocoa.w`
  (compile-checked: `bin/wv2 win64|arm64_darwin graphics/ui/demo.w`)
  call `gfx_control_open` in open, `gfx_control_poll` at the end of poll
  and `gfx_control_swap` before presenting. The socket transport is per
  target (`graphics/__arch__/<arch>/control_transport.w`): AF_UNIX through
  `lib/net.w` on Linux and Darwin, Winsock AF_UNIX (Windows 10 1803+) on
  win64. The x86 stub (`window_stub.w`) opens no window, so it never
  connects; the wasm backend (`window_web.w`) is not hooked — browser
  apps are driven by browser tooling instead.
- **Injected input is real input.** Events go into the window's
  `gfx_input_queue` exactly as the backend's own (`graphics/event.w`
  kinds, codes and mods), and `mouse_x` / `mouse_y` / `mouse_buttons`
  follow, so programs need no changes. MOUSE_DOWN carries its click count
  like the native backends do.
- **Frame phases.** Requests run strictly in order. Each expands into
  operations that run at the *poll phase* (input, replies) or the *swap
  phase* (frame barriers, step counts, pixel reads, screenshots — taken
  from the back buffer just before it is presented). A click is mouse
  down, a frame, mouse up, a frame, then the reply, so a following
  screenshot shows the frame after the click took effect. Reads are
  zero-timeout polls: with nothing pending the program runs its loop as
  usual (wdrive never blocks the app; the app is never paused either —
  it keeps rendering between requests).
- **Accessibility tree.** `graphics/control_hooks.w` holds two globals
  shared with graphics.ui (so graphics/ never imports ui). On an
  `a11y_tree` request the next `ui_begin_window` captures that frame's
  snapshot (`graphics/ui/accessibility.w`) unless the program already
  captures its own, and `ui_end` serializes it with
  `graphics/ui/accessibility_json.w`. A program that does not draw with
  graphics.ui answers with an error after three frames.
- **Driver gone.** When the control connection reaches EOF the program
  closes its window as if the user had (gfx_window_poll returns 0).

## Protocol (version 1)

NDJSON over the socket: one request per line, one response per line.

```
→ {"id":3,"cmd":"click","x":40,"y":60}
← {"id":3,"ok":true}
← {"id":4,"ok":false,"error":"unknown cmd: frob"}
```

Coordinates are logical window pixels, origin top-left (the space
gfx_window's `mouse_x`/`mouse_y` and the a11y bounds use). `x`/`y`
default to the current pointer position. Number members accept ints or
floats.

| cmd | members | reply (besides `id`, `ok`) | when |
|---|---|---|---|
| `hello` | — | `protocol`, `title`, `backend` (`x11`/`win32`/`cocoa`), `width`, `height`, `pixel_width`, `pixel_height`, `frame` | next poll |
| `move` | `x`, `y` | — | after 1 frame |
| `click` | `x`, `y`, `button` (1 left, 2 middle, 3 right; default 1), `count` (1–15, double/triple click), `mods` | — | after 2×count frames |
| `mouse_down` / `mouse_up` | `x`, `y`, `button`, `mods` | — | after 1 frame |
| `wheel` | `notches` (+ up / − down, one SCROLL event each), `pixels` (one SCROLL_PIXELS, + down), `x`, `y` | — | after 1 frame |
| `key` | `name` or `key` (see below), or `code` (a Unicode scalar as CHAR); `mods`; `keycode` (also queue KEY_DOWN/KEY_UP with that backend-native code); `repeat` | — | after 1 frame per repeat |
| `text` | `text` (UTF-8; `\n` types Return) | — | after ⌈n/32⌉ frames (the queue's per-frame CHAR budget) |
| `resize` | `w`, `h` (or `width`, `height`) | `width`, `height`, `pixel_width`, `pixel_height`; `ok:false` if the window did not reach the size within 30 frames | after the configure event |
| `step` | `frames` (default 1) | `frame` | after that many swaps |
| `screenshot` | `path` (written by the program; relative to its cwd) | `path`, `width`, `height` (framebuffer pixels), `frame` | next swap |
| `pixel` | `x`, `y` | `x`, `y`, `rgba` [r,g,b,255], `frame` | next swap |
| `a11y_tree` | — | `tree` (see below), `frame` | after the next graphics.ui frame |
| `close` | — | — | next poll; then the window closes |

`frame` counts swaps since the program connected. Screenshots are 8-bit
RGBA PNG (`graphics/image/png.w`), alpha forced opaque.

**Keys.** `name` is case-insensitive: `Left Right Up Down Home End
PageUp PageDown Delete` (NAV events), `Enter`/`Return` (13), `Tab` (9),
`Backspace` (8), `Escape`/`Esc` (27), `Space`, or one character. A
`Ctrl+Shift+Tab`-style prefix adds modifiers. As on the native
backends, Shift capitalises a letter and Ctrl turns it into its control
code (`Ctrl+S` → CHAR 19 with GFX_MOD_CTRL). `mods` is a gfx_mod bitmask
(1 shift, 2 ctrl, 4 alt, 8 super), a string `"ctrl+shift"`, or an array
`["ctrl","shift"]`; `cmd`/`meta` mean super, `option` means alt.

**Accessibility tree.** One JSON object per node:

```json
{"id":1,"role":"button","name":"Paint","bounds":[8,48,61,32],
 "states":["focusable"],"focused":true,"value":"…","description":"…",
 "caret":4,"selection":[0,4],"level":1,"range":[min,now,max],
 "children":[…]}
```

`role` is one of document, group, text, heading, link, button,
checkbox, textbox, image, list, list_item, table, row, cell, radio,
switch, combobox, tab_list, tab, progress, dialog, slider; `states` uses
disabled, checked, selected, expanded, readonly, hidden, focusable,
multiselectable, header. Optional members appear only when set.

## CLI

```
wdrive run   [options] [--script FILE | --steps JSON] -- PROGRAM [ARGS...]
wdrive serve [options] -- PROGRAM [ARGS...]

  --xvfb          always start a private Xvfb (default: only when DISPLAY is unset)
  --screen WxH    the Xvfb screen size (default 1280x1024)
  --size WxH      resize the program's window before the handshake
  --out DIR       directory for relative and default screenshot paths (created)
  --timeout-ms N  per-step and connect timeout (default 10000)
  --keep-going    run: continue after a failed step
```

wdrive picks the first free display from `:90` (by its lock file and
socket), waits until Xvfb accepts connections, starts PROGRAM (looked up
on PATH unless it contains a `/`) in its own process group with
`W_GFX_CONTROL` and `DISPLAY` set, and waits for it to connect. The
program's stdout and stderr are forwarded to wdrive's **stderr**; wdrive's
stdout carries only result lines. At the end it sends `close`, waits a
second, then kills the program's process group and its Xvfb and removes
its temporary directory.

**Output.** One NDJSON line per step: `{"step":N,"cmd":"…",…}` followed
by the program's reply members (without its `id`). Step 0 is the
handshake `hello`. In serve mode a step's own `id` (any JSON value) is
echoed as `"id"`.

**Steps** are protocol requests plus driver-side commands. Any step may
carry `timeout_ms`.

| step | members | result |
|---|---|---|
| any protocol cmd | as above | the reply |
| `screenshot` | `path` optional: default `shot-<step>.png`; relative paths go under `--out` (or the cwd); made absolute before it reaches the program | `path` is absolute |
| `wait_ms` | `ms` | — (keeps forwarding program output meanwhile) |
| `assert_pixel` | `x`, `y`, `rgba` as `[r,g,b]`, `[r,g,b,a]`, `"#rrggbb"` or `"#rrggbbaa"`, `tolerance` (per channel, default 0) | `rgba`, `expected`; `ok:false`, `"error":"pixel mismatch"` |
| `assert_a11y` | selectors (below), `count` (exact number of matches), `absent:true` | `matches`, `node` (first match without children, plus `children_count`) |
| `click_node` | selectors, `button`, `count_clicks` | clicks the centre of the first match's bounds; `x`, `y`, `node` |

Selectors: `role`, `name`, `name_contains`, `value`, `value_contains`,
`focused` (bool), `state` (one state name). All given selectors must
match.

**Exit status.** run: 0 when every step passed, 1 when one failed or
timed out, 2 usage, 3 environment (Xvfb missing or not starting, the
program not starting, exiting or not connecting — e.g. no GL). serve: 0
at the end of stdin or after a successful `close` step, 1 if the program
died unasked, 2/3 as for run; failed steps only produce `ok:false` lines.

`--script FILE` holds a JSON array of steps or NDJSON (one step per line).

### Serve mode for agent tools

`wdrive serve` keeps one session open: write a step line to its stdin,
read one result line from its stdout. A tool wrapper only needs to spawn
`bin/wdrive serve [--xvfb] [--out DIR] -- PROGRAM`, read the step-0
hello, then exchange lines; closing stdin ends the session.

```sh
printf '%s\n' '{"id":"a","cmd":"a11y_tree"}' '{"cmd":"close"}' |
  bin/wdrive serve --xvfb -- bin/wdrive_fixture
```

## Tests

- `graphics_control_test` / `graphics_control_64_test` — protocol unit
  test of `graphics/control.w` against a fake window target (no socket,
  display or GL): request parsing and errors, partial lines, click/key/
  text/wheel expansion across frames, step counting, pixel and
  screenshot (PNG round trip) through a fake readback, resize, the
  a11y hand-off, close, and the inactive path.
- `wdrive_xvfb_test` (`tests_x64`) — builds `bin/wdrive` and
  `bin/wdrive_fixture` (`tests/wdrive_fixture.w`), then drives the
  fixture under a private Xvfb: pixel asserts before and after clicking
  the "Paint" button by its a11y node, typing into the textbox, a11y
  value and focus asserts, PNG screenshots, `serve` with `--size`, an id
  echo and a failing step, and the 1 / 3 exit statuses. SKIPs (via
  `lib/ci_skip.w`) when Xvfb or libGL.so.1 is missing.

## Limitations and next steps

- Linux/X11 is the only backend run for real. Win32 and Cocoa are wired
  and compile, but unexercised: wdrive itself spawns Xvfb and uses
  POSIX process APIs, so a Windows/macOS driver (and a run of the
  Winsock AF_UNIX transport) is future work. Cocoa windows are fixed
  size, so `resize` answers `ok:false` there.
- One control session per process (the first window that opens).
- The program is never paused: it keeps rendering between requests, so
  time-based animation advances in wall-clock time. Deterministic
  stepping would need a frame clock the app reads through the channel.
- Injected input bypasses the platform: IME preedit, clipboard contents
  and window-manager behaviour are not simulated (use the per-app XTest
  driver for those). KEY_DOWN/KEY_UP are queued only when `keycode` is
  given, since raw keycodes are backend-specific.
- `a11y_tree` needs graphics.ui (`ui_begin_window`/`ui_end`); other
  programs only get pixels and screenshots.
- The x86 stub has no window and is not driven; an in-memory window for
  it was out of scope.
