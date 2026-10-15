# Experimental Android native controls, backed by tools/android's JNI host.
# Call these only during exported wandroid_setup/event/lifecycle callbacks
# on the Activity's UI thread. Handles are one-based and reset on recreation.
c_lib "libwandroid.so"
extern int wandroid_label(char* text)
extern void wandroid_label_set(int handle, char* text)
extern int wandroid_button(char* text)
extern int wandroid_text_field(char* hint)
# Optional presentation roles. A section starts a new card; section_end
# returns to the page. Sections do not nest. Label roles work with label_set.
extern int wandroid_heading(char* text)
extern int wandroid_caption(char* text)
extern int wandroid_section(char* title)
extern void wandroid_section_end()
extern int wandroid_value(char* text)
extern int wandroid_secondary_button(char* text)
extern int wandroid_status(char* text)

const int android_event_click = 1
const int android_event_text = 2
const int android_phase_active = 1
const int android_phase_background = 2
