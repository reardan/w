# Native Android controls and W state; build with tools/android/build.w.
# wbuild: target=android_app_test dep=android_check_elf tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64_android --shared --strict graphics/android/demo.w -o bin/libandroid_demo.so"
# wbuild: step="bin/android_check_elf bin/libandroid_demo.so"
import lib.lib
import graphics.android.ui

int android_taps
int android_count_label
int android_name_label
int android_name_field
int android_tap_button
int android_reset_button
int android_status_label

export void wandroid_setup():
	android_taps = 0
	wandroid_caption(c"W  /  PLAYGROUND")
	wandroid_heading(c"Hello, Android.")
	wandroid_label(c"Make it yours with a name and a tap.")
	wandroid_section(c"01  /  MAKE IT YOURS")
	android_name_field = wandroid_text_field(c"Your name")
	android_name_label = wandroid_label(c"Hello, friend.")
	wandroid_section(c"02  /  EVERY TAP COUNTS")
	android_count_label = wandroid_value(c"0")
	wandroid_label(c"Taps this session")
	android_tap_button = wandroid_button(c"Add a tap")
	android_reset_button = wandroid_secondary_button(c"Start fresh")
	wandroid_section_end()
	android_status_label = wandroid_status(c"Starting")

# value is borrowed UTF-8, valid only during this callback.
export void wandroid_event(int handle, int kind, char* value):
	if (handle == android_tap_button && kind == android_event_click):
		android_taps = android_taps + 1
		char* text = itoa(android_taps)
		wandroid_label_set(android_count_label, text)
		free(text)
	else if (handle == android_reset_button && kind == android_event_click):
		android_taps = 0
		wandroid_label_set(android_count_label, c"0")
	else if (handle == android_name_field && kind == android_event_text):
		if (value[0] == 0): wandroid_label_set(android_name_label, c"Hello, friend.")
		else: wandroid_label_set(android_name_label, value)

export void wandroid_lifecycle(int phase):
	if (phase == android_phase_active): wandroid_label_set(android_status_label, c"Active")
	else if (phase == android_phase_background): wandroid_label_set(android_status_label, c"Background")
