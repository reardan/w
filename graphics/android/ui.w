# Experimental Android native controls, backed by tools/android's JNI host.
# Call these only during exported wandroid_setup/event/lifecycle callbacks
# on the Activity's UI thread. Handles are one-based and reset on recreation.
c_lib "libwandroid.so"
extern int wandroid_label(char* text)
extern void wandroid_label_set(int handle, char* text)
extern int wandroid_button(char* text)
extern int wandroid_text_field(char* hint)

const int android_event_click = 1
const int android_event_text = 2
const int android_phase_active = 1
const int android_phase_background = 2
