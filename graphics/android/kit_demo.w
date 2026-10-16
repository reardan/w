# Example of graphics/android/kit.w: tabs, screens, lists, text views, a text
# area, a dialog, HTTP and secure storage. Launched with the data URI
# "wkit:smoke?URL" it also runs tools/android/kit_smoke.py's device self-test.
# wbuild: target=android_kit_test tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_android --shared --strict graphics/android/kit_demo.w -o bin/libandroid_kit_demo.so"
# wbuild: step="python3 tools/android/check_elf.py bin/libandroid_kit_demo.so"
# wbuild: step="python3 tools/android/check_bridge.py"
import lib.lib
import lib.str
import graphics.android.kit

int kit_tab_files
int kit_tab_text
int kit_list
int kit_rows
int kit_add
int kit_details
int kit_log
int kit_area
int kit_send
char* kit_message
char* kit_smoke_url
int kit_timer
int kit_http_ok
int kit_http_down
int kit_http_pending
int kit_dialog
int kit_failed
int kit_area_echo

void kit_check(int ok, char* what):
	if (ok): return
	kit_failed = 1
	wandroid_log(strjoin(c"kit smoke: FAILED ", what))

void kit_files():
	wandroid_screen_clear()
	wandroid_tab_select(kit_tab_files)
	wandroid_screen(c"Files", 0)
	kit_details = wandroid_action(c"About")
	kit_list = wandroid_list(0)
	wandroid_list_add(kit_list, c"README.md", c"Modified · tap to open")
	wandroid_list_add(kit_list, c"graphics/android/kit.w", c"")
	wandroid_list_add(kit_list, c"世界 😀.txt", c"Untracked")
	kit_rows = 3
	wandroid_row()
	kit_add = wandroid_button(c"Add row")
	wandroid_style(kit_add, android_role_primary)
	wandroid_row_end()

void kit_text():
	wandroid_screen_clear()
	wandroid_tab_select(kit_tab_text)
	wandroid_screen(c"Text", 0)
	wandroid_text_view(c"diff --git a/kit.w b/kit.w\n@@ -1,2 +1,2 @@\n context\n-old line\n+new line 😀\n", android_text_diff)
	kit_log = wandroid_text_view(c"", android_text_wrap | android_text_tail | android_text_proportional)
	wandroid_text_append(kit_log, c"Agent\n", android_role_heading)
	wandroid_text_append(kit_log, c"Messages you send appear here.\n\n", 0)
	wandroid_row()
	kit_area = wandroid_text_area(c"Message", 0)
	kit_send = wandroid_button(c"Send")
	wandroid_style(kit_send, android_role_primary)
	wandroid_row_end()

void kit_open(int index):
	char* title = itoa(index)
	wandroid_screen(c"Row", android_screen_scroll)
	int label = wandroid_label(strjoin(c"Opened row ", title))
	wandroid_style(label, android_role_title)
	wandroid_label(c"Back or the arrow returns to the list.")
	free(title)

void kit_smoke_done():
	if (kit_failed == 0): wandroid_log(c"kit smoke: ok")

# Synchronous checks, then a timer starts the asynchronous chain.
void kit_smoke_begin():
	kit_check(wandroid_screen_depth() == 1, c"initial depth")
	wandroid_screen(c"Second", android_screen_scroll)
	kit_check(wandroid_screen_depth() == 2, c"push")
	wandroid_screen_pop()
	kit_check(wandroid_screen_depth() == 1, c"pop")
	kit_check(wandroid_list_add(kit_list, c"four", c"4") == 3, c"list add")
	wandroid_list_set(kit_list, 0, c"README.md", c"Staged")
	kit_check(wandroid_list_add(0, c"x", c"") < 0, c"invalid list")
	char[64] buffer
	kit_check(wandroid_secure_put(c"kit_smoke", c"tok 😀") == 1, c"secure put")
	kit_check(wandroid_secure_get(c"kit_smoke", &buffer[0], 64) == strlen(c"tok 😀"), c"secure length")
	kit_check(strcmp(&buffer[0], c"tok 😀") == 0, c"secure value")
	wandroid_secure_delete(c"kit_smoke")
	kit_check(wandroid_secure_get(c"kit_smoke", &buffer[0], 64) == -1, c"secure delete")
	kit_text()
	wandroid_text_set(kit_area, c"set by W")
	kit_check(kit_area_echo == 0, c"area set must not echo")
	kit_check(wandroid_text_get(kit_area, &buffer[0], 4) == 8, c"text_get length")
	kit_check(strcmp(&buffer[0], c"set") == 0, c"text_get truncates")
	kit_timer = wandroid_timer(30, 0)

void kit_smoke_event(int handle, int kind, char* value):
	if ((kind == android_event_timer) && (handle == kit_timer)):
		kit_http_ok = wandroid_http(c"GET", kit_smoke_url, c"Accept: text/plain\nX-Kit: 1", c"")
		kit_http_down = wandroid_http(c"POST", c"http://127.0.0.1:9/", c"", c"{}")
		kit_http_pending = 2
	else if (kind == android_event_http):
		char* body = value
		int at = index_of(value, c"\n")
		if (at >= 0): body = value + at + 1
		if (handle == kit_http_ok):
			kit_check(atoi(value) == 200, c"http status")
			kit_check(strcmp(body, c"kit-http-ok") == 0, c"http body")
		else if (handle == kit_http_down): kit_check(atoi(value) == 0, c"refused connection")
		kit_http_pending = kit_http_pending - 1
		if (kit_http_pending == 0):
			kit_open(7)
			wandroid_log(c"kit smoke: press back")
	else if (kind == android_event_back):
		wandroid_screen_pop()
		kit_check(wandroid_screen_depth() == 1, c"back pops")
		kit_dialog = wandroid_dialog(c"Allow edit?", c"The agent wants to edit kit.w.", c"Allow\nDeny\nAlways")
		wandroid_log(c"kit smoke: dismiss dialog")
	else if ((kind == android_event_dialog) && (handle == kit_dialog)):
		kit_check(strcmp(value, c"-1") == 0, c"dialog dismissed")
		wandroid_log(c"kit smoke: send deep link")
	else if (kind == android_event_uri):
		kit_check(strcmp(value, c"wkit:ping") == 0, c"deep link")
		# Built without --notifications: no service to start, and an undeclared
		# permission is refused through android_event_permission.
		kit_check(wandroid_background(c"Working") == 0, c"background work needs the service")
		wandroid_background(c"")
		int asked = wandroid_permission(c"android.permission.CAMERA")
		kit_check(asked != 1, c"undeclared permission is not granted")
		if (asked == 0): kit_smoke_done()
	else if (kind == android_event_permission):
		kit_check(strcmp(value, c"0") == 0, c"undeclared permission refused")
		kit_smoke_done()

export void wandroid_setup():
	kit_message = strclone(c"")
	kit_tab_files = wandroid_tab(c"Files")
	kit_tab_text = wandroid_tab(c"Text")
	kit_files()
	char[512] uri
	int length = wandroid_intent_uri(&uri[0], 512)
	if ((length > 11) && (length < 512) && starts_with(&uri[0], c"wkit:smoke?")):
		free(kit_smoke_url)
		kit_smoke_url = strclone(&uri[0] + 11)
		kit_smoke_begin()

# value is borrowed UTF-8, valid only during this callback.
export void wandroid_event(int handle, int kind, char* value):
	if (kind == android_event_text):
		if (handle == kit_area):
			kit_area_echo = kit_area_echo + 1
			free(kit_message)
			kit_message = strclone(value)
		return
	if (kit_smoke_url != 0):
		kit_smoke_event(handle, kind, value)
		return
	if (kind == android_event_back): wandroid_screen_pop()
	else if (kind == android_event_item): kit_open(atoi(value))
	else if ((kind == android_event_click) && (handle == kit_tab_files)): kit_files()
	else if ((kind == android_event_click) && (handle == kit_tab_text)): kit_text()
	else if ((kind == android_event_click) && (handle == kit_add)):
		kit_rows = kit_rows + 1
		char* number = itoa(kit_rows)
		wandroid_list_add(kit_list, strjoin(c"Row ", number), c"Added by W")
		free(number)
	else if ((kind == android_event_click) && (handle == kit_details)):
		wandroid_dialog(c"W kit", c"Native Android controls driven by W.", c"OK")
	else if ((kind == android_event_click) && (handle == kit_send) && (kit_message[0] != 0)):
		wandroid_text_append(kit_log, c"You\n", android_role_heading)
		wandroid_text_append(kit_log, kit_message, 0)
		wandroid_text_append(kit_log, c"\n\n", 0)
		wandroid_text_set(kit_area, c"")
		free(kit_message)
		kit_message = strclone(c"")

export void wandroid_lifecycle(int phase):
	return
