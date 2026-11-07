# Clipboard: a cross-backend cut/copy/paste seam

Design note, 2026-08-09. Written during round 2 of issue #441
(`docs/projects/ui_widgets.md` §9) and deliberately **not** implemented
there — this records the shape so the editor project can pick it up
without re-deriving it. Implemented in 2026-11 by issue #850; §6 records
what landed and where it departs from this design.

Clipboard has been an explicit non-goal twice: `ui_widgets.md` §7 named
it as round 1's, and §9.5 names it again for round 2. The reason has
not changed — no platform clipboard binding exists on any backend, and
X11 selections, `NSPasteboard` and the browser's Clipboard API are
three genuinely different designs, one of which is asynchronous. But a
Sublime-Text-like editor cannot ship without it, so it needs a plan
rather than another deferral.

## 1. Why it is not just "a getter and a setter"

The three platforms disagree about who owns the data and when it is
produced.

**X11 has no clipboard.** It has *selections*: an application declares
itself the owner of an atom (`CLIPBOARD`, or `PRIMARY` for
middle-click), and when another application wants the text it asks the
owner for it, right then, over the wire. Copying is
`XSetSelectionOwner` plus a promise to answer `SelectionRequest` events
forever after; pasting is `XConvertSelection` followed by *waiting for
a `SelectionNotify` event* and then reading a window property. Both
halves are asynchronous, and the copy half means the process must keep
serving requests for as long as it holds the selection — which is why
X11 clipboards go empty when the source application exits.

`graphics/x11.w` binds `XInternAtom` (`x11.w:212`) and nothing else of
this: `XSetSelectionOwner`, `XConvertSelection`, `XGetWindowProperty`
and `XChangeProperty` all need adding, and `gfx_window_poll` needs to
grow handling for `SelectionRequest` and `SelectionNotify` alongside
the input events it already dispatches.

**Cocoa is the easy one.** `NSPasteboard generalPasteboard` is
synchronous, owns a copy of the data, and survives the process. It is
also the backend where this is currently unreachable for a different
reason: `window_cocoa.w` has no mouse events at all in v1
(`window_cocoa.w:17`), so there is nothing to select text *with*. The
pasteboard binding is easy; the backend it lands in is the least
usable.

**The browser is asynchronous and permission-gated.**
`navigator.clipboard.readText()` returns a Promise and may prompt or
reject outright; the synchronous `document.execCommand('copy')` path is
deprecated but still the only one that works without a permission
grant, and only inside a user-gesture handler. A wasm import cannot
block on a Promise, so a read cannot be a function call that returns
text.

## 2. The seam

The asynchronous platforms decide the API. A synchronous
`gfx_clipboard_get()` returning `char*` would be implementable on Cocoa
and nowhere else, so the seam is **write-synchronous, read-deferred**:

```
# graphics/clipboard.w
int  gfx_clipboard_set(gfx_window* win, char* text)
void gfx_clipboard_request(gfx_window* win)
int  gfx_clipboard_take(gfx_window* win, char* out, int cap)
```

- `gfx_clipboard_set` is synchronous everywhere. On X11 it copies the
  text into a backend-owned buffer and claims the selection; on Cocoa
  it writes the pasteboard; on the web it calls the host's copy import.
- `gfx_clipboard_request` asks for the text and returns immediately.
- `gfx_clipboard_take` returns 1 and fills `out` once the text has
  arrived, 0 while it has not. The caller polls it on subsequent
  frames.

A per-frame poll for a paste is not a compromise made for the browser;
it is what X11 needs regardless. Cocoa satisfies the request
immediately, so `take` succeeds on the very next call and the
"asynchronous" API costs it one extra frame at most.

The backend owns the pending buffer, which puts it in each backend's
own `gfx_window` struct — except on wasm, where `gfx_window` is
byte-frozen because the JS host writes it at hardcoded offsets
(`graphics/event.w:15-19`). There the pending text goes in a
module-level buffer the host fills through an import, the same shape as
the host-side event queue.

## 3. Widget-layer surface

`ui_textarea` (and `ui_textbox`) grow ctrl-C / ctrl-X / ctrl-V. The
modifier bits already arrive — `gfx_mod` and `gfx_event.mods` landed in
round 1 (`graphics/event.w:68`) — so this is widget code plus the seam,
with one wrinkle: **ctrl-C arrives as `GFX_EVENT_CHAR` with code 3**
(ASCII ETX), not as `'c'` with `GFX_MOD_CTRL`, on the backends that
translate control characters. Whichever way it lands, the widget should
key on the mods, and the backends should be made to agree — that
consistency check is part of the work, not an afterthought.

Paste is the interesting one, because it is the first widget action
that cannot complete in the frame it starts. `ui_textarea_state` gains
a `paste_pending` flag: ctrl-V sets it and calls
`gfx_clipboard_request`, and every subsequent frame calls
`gfx_clipboard_take` until it succeeds, then inserts at the caret
through the existing `ui_text_buffer_insert_text`
(`buffer.w:147`). Since the widget layer must not import
`graphics.window` for this, the cleanest shape is for the *caller* to
drive the pump and hand the widget the text — consistent with §9.3's
conclusion that UI code should not read clocks either.

## 4. Staging

1. `graphics/clipboard.w` with the three-function seam and a stub
   backend that round-trips through an in-process buffer — enough to
   make the widget layer testable headlessly, which is the same trick
   `ui_render_init_headless` plays.
2. X11: the four missing bindings plus `SelectionRequest` /
   `SelectionNotify` handling in the poll loop. This is the bulk of the
   work and the only backend where the design is genuinely hard.
3. Widget layer: ctrl-C/X/V in `ui_textarea` and `ui_textbox`, with the
   deferred-paste pump, tested against the stub backend.
4. Web: a host import pair in `tools/web/index.html` and
   `webgl_env.mjs`, with the copy path inside the gesture handler.
5. Cocoa: `NSPasteboard`, whenever the backend's mouse gap
   (`window_cocoa.w:17`) is closed and text selection is possible there
   at all.

Steps 1-3 are what the editor actually needs; 4 and 5 are the
"runs anywhere" claim being kept honest.

## 5. Non-goals

- **Rich content.** Text only, `text/plain;charset=utf-8`. No images,
  no HTML flavors, no file lists.
- **Clipboard history** and multiple named registers. Editor features
  built on top of this, not part of the seam.
- **The X11 `PRIMARY` selection** (middle-click paste). A separate
  atom on the same machinery; worth adding once `CLIPBOARD` works,
  not before.
- **INCR transfers.** X11's chunked protocol for large selections. A
  first version can refuse anything past a fixed size rather than
  implement it, provided it refuses *visibly*.

## 6. As implemented (#850, 2026-11)

All five stages landed together, with INCR.

**Seam.** Each window backend implements the three functions on its own
`gfx_window` (`graphics/window.w` lists them), over the shared
`gfx_clipboard_store` in `graphics/clipboard_store.w`. One change from §2:
`gfx_clipboard_take(win)` returns the text as a malloc'd, NUL-terminated
string that the caller frees, instead of filling a caller buffer. A paste
can be any size, and a fixed `cap` would have needed a second "how big"
call. A refused or empty read arrives as `""`, so a waiting caller always
stops. Every backend turns CR LF and lone CR into LF and drops NUL bytes,
so widgets see the same line ends everywhere. A null window uses an
in-process clipboard, and so does the x86 stub. That is §4 step 1's stub
backend, and the headless tests use it.

**X11** (`window_x11.w`). Copy claims `CLIPBOARD` with the last input
event's timestamp and answers `TARGETS`, `UTF8_STRING`,
`text/plain;charset=utf-8`, `STRING` and `TEXT`. Text larger than the
server's request limit goes out over INCR. Paste asks for `UTF8_STRING`,
falls back to `STRING` (Latin-1, converted to UTF-8), and reads INCR
replies chunk by chunk from `PropertyNotify`. Text the window owns
itself is pasted without a server round trip. `SelectionClear` drops the
claim. `PRIMARY` is still a non-goal.

**Win32** (`window_win32.w`) writes `CF_UNICODETEXT` with CR LF line ends
and reads it back synchronously. `OpenClipboard` is retried briefly while
another process holds the clipboard. **Cocoa** (`window_cocoa.w`) uses
`NSPasteboard generalPasteboard` with the plain-text UTI. It is
cross-compiled only; a run on a Mac is still needed.

**Web.** The host import set is `gfx_host_clipboard_write`, `_read`,
`_read_poll` and `_read_copy` (`tools/web/README.md`). The page answers
the Clipboard API's gesture and permission rules this way: the DOM
`copy`/`cut`/`paste` events that Ctrl/Cmd+C, X and V fire run W's frame
synchronously. So the copied text is set on `clipboardData`, and the
pasted text answers W's read, inside the user gesture. `navigator.clipboard`
is used only outside those events.

**Widgets.** The pump is not the caller's job, as §3 proposed:
`ui_begin_window` and `ui_end` call `ui_clipboard_pump`. `ui_end` gets the
window that `ui_begin_window` stored, so a copy reaches the platform in
the frame it happened. The browser needs that, because the copy event is
still on the stack. Widget code never touches the window. It calls
`ui_clipboard_copy`, `ui_clipboard_paste_request` and
`ui_clipboard_paste_take`, and headless tests play the platform with
`ui_clipboard_copied` and `ui_clipboard_deliver`. Commands are matched by
`ui_clipboard_command`, which looks at the modifier and accepts either
the control code (X11, Win32) or the letter (web, Cocoa's Command).
Ctrl+Alt counts as AltGr typing.

`ui_textbox` gained a selection (`anchor`): Shift with the arrows or
Home/End, Ctrl/Cmd+A, mouse drag and Shift+click, a highlight, and
forward Delete. Typing, Backspace and paste replace the selection. A
paste into a single line turns newlines and tabs into spaces.
`ui_textarea` already had keyboard selection; it gained drag (scrolling
at the edges), Shift+click and the clipboard. Both report the selection
to accessibility through `ui_access_set_caret`.

**Tests.** `graphics_ui_clipboard_test` (in `tests`, headless) covers
selection, all three shortcut encodings, the pump and the store.
`graphics_clipboard_x11_test` (opt-in, Xvfb) does real round trips:
between two X clients, over INCR both ways, and with `xclip`. The
`clipboard` workflow of `mermaid_editor_ui_test` and
`mermaid_editor_wine_test` drives the editor with real XTest keys.
`web_mobile_input_test` covers the browser host.

**Still open:** native runs on Windows and macOS (checklist step 2.10),
double-click word selection, `PRIMARY`, and rich content.
