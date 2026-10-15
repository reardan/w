# Optional IDE-companion controls for native Android W apps, implemented by
# tools/android/{kit.c,WKit.java}. Same rules as graphics/android/ui.w: call
# only from wandroid_setup/event/lifecycle on the UI thread. Handles share
# ui.w's one-based space; timer, dialog and HTTP ids form a second space
# and are distinguished by their event kind. Text is UTF-8 (char*).
import graphics.android.ui
c_lib "libwandroid.so"

# Screen stack with a top bar (title, Up arrow, actions) and optional bottom
# tabs. Pushing a screen makes it the target for new controls, including
# wandroid_label/button/text_field. Fixed screens (flags 0) give lists, text
# views and fill areas the free height; android_screen_scroll scrolls a form.
# The result is the title's label handle (wandroid_label_set renames it).
extern int wandroid_screen(char* title, int flags)
extern void wandroid_screen_pop()
extern void wandroid_screen_clear()
extern int wandroid_screen_depth()
# Text action in the current screen's top bar; tapping sends a click event.
extern int wandroid_action(char* label)
# Persistent bottom tab; tapping sends a click. tab_select highlights one.
extern int wandroid_tab(char* label)
extern void wandroid_tab_select(int tab)
# Controls between row and row_end share one line in equal widths.
extern int wandroid_row()
extern void wandroid_row_end()

# Two-line list rows (detail may be ""). A tap sends android_event_item
# whose value is the decimal row index. list_add returns the new index.
extern int wandroid_list(int flags)
extern void wandroid_list_clear(int list)
extern int wandroid_list_add(int list, char* title, char* detail)
extern void wandroid_list_set(int list, int index, char* title, char* detail)

# Read-only, selectable text: monospace unless android_text_proportional.
# Without android_text_wrap long lines scroll sideways. android_text_diff
# colors unified-diff lines; android_text_tail keeps appended text in view.
extern int wandroid_text_view(char* text, int flags)
# Multi-line editable text; edits send android_event_text with the content.
extern int wandroid_text_area(char* hint, int flags)
# Works on labels, buttons, fields, text views and areas. Setting an area's
# text programmatically does not echo a text event.
extern void wandroid_text_set(int handle, char* text)
# Text views only; role is 0 or an android_role_* emphasis (heading, title,
# secondary, error). Older text is trimmed beyond about 200,000 characters.
extern void wandroid_text_append(int handle, char* text, int role)
# Copies at most capacity-1 bytes plus NUL; returns the full length or -1.
extern int wandroid_text_get(int handle, char* buffer, int capacity)
extern void wandroid_enable(int handle, int enabled)
extern void wandroid_show(int handle, int visible)
# Restyle a label, button or field with an android_role_* constant.
extern void wandroid_style(int handle, int role)
extern void wandroid_focus(int handle)
extern void wandroid_keyboard_hide()

# Alert with one to three newline-separated buttons (first is the default
# action, then negative, then neutral). android_event_dialog carries the
# chosen index, or -1 when dismissed. choose shows a list of items instead.
extern int wandroid_dialog(char* title, char* message, char* buttons)
extern int wandroid_choose(char* title, char* items)
extern void wandroid_toast(char* text)
extern void wandroid_log(char* text)

# android_event_timer after milliseconds, repeatedly if repeat is nonzero.
# Timers stop when the Activity is destroyed; recreate them in setup.
extern int wandroid_timer(int milliseconds, int repeat)
extern void wandroid_timer_cancel(int timer)

# Background HTTP(S) request. headers are "Name: value" lines. Redirects are
# not followed. android_event_http's value is "STATUS\nBODY": status 0 means
# no response (BODY explains), bodies are capped at 8 MiB and end at a NUL.
# Results reach the current Activity, even one recreated meanwhile.
extern int wandroid_http(char* method, char* url, char* headers, char* body)

# Small secrets encrypted with an AES-GCM AndroidKeyStore key. get copies like
# text_get and returns -1 when the key is missing or cannot be decrypted.
extern int wandroid_secure_put(char* key, char* value)
extern int wandroid_secure_get(char* key, char* buffer, int capacity)
extern void wandroid_secure_delete(char* key)
# The launching Intent's data URI (length; 0 when none). Later deep links
# arrive as android_event_uri. Recreation reports the original URI again.
extern int wandroid_intent_uri(char* buffer, int capacity)

const int android_event_back = 32
const int android_event_item = 33
const int android_event_dialog = 34
const int android_event_timer = 35
const int android_event_http = 36
const int android_event_uri = 37

const int android_screen_scroll = 1
const int android_text_wrap = 1
const int android_text_diff = 2
const int android_text_tail = 4
const int android_text_proportional = 8
const int android_area_monospace = 1
const int android_area_fill = 2
const int android_area_plain = 4

const int android_role_body = 1
const int android_role_title = 2
const int android_role_secondary = 3
const int android_role_error = 4
const int android_role_monospace = 5
const int android_role_primary = 6
const int android_role_destructive = 7
const int android_role_url = 8
const int android_role_secret = 9
const int android_role_heading = 10
