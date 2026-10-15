# Native Android controls and W state; build with tools/android/build.py.
# wbuild: target=android_app_test tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_android --shared --strict graphics/android/demo.w -o bin/libandroid_demo.so"
# wbuild: step="python3 tools/android/check_elf.py bin/libandroid_demo.so"
import lib.lib
import graphics.android.ui

int android_taps
int android_count_label
int android_name_label
int android_name_field
int android_tap_button
int android_status_label

export void wandroid_setup():
	android_taps = 0
	wandroid_label(c"A native Android app written in W")
	android_name_field = wandroid_text_field(c"Your name")
	android_name_label = wandroid_label(c"Type above to exercise the software keyboard.")
	wandroid_label(c"Tap count")
	android_count_label = wandroid_label(c"0")
	android_tap_button = wandroid_button(c"Tap me")
	android_status_label = wandroid_label(c"Starting")

# value is borrowed UTF-8, valid only during this callback.
export void wandroid_event(int handle, int kind, char* value):
	if (handle == android_tap_button && kind == android_event_click):
		android_taps = android_taps + 1
		char* text = itoa(android_taps)
		wandroid_label_set(android_count_label, text)
		free(text)
	else if (handle == android_name_field && kind == android_event_text):
		wandroid_label_set(android_name_label, value)

export void wandroid_lifecycle(int phase):
	if (phase == android_phase_active): wandroid_label_set(android_status_label, c"Active")
	else if (phase == android_phase_background): wandroid_label_set(android_status_label, c"Background")
