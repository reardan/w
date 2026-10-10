# Native W app: state and event handlers run in W machine code; UIKit owns
# safe-area layout, scrolling, keyboard/IME, Dynamic Type and accessibility.
import lib.lib
import graphics.ios.ui

int ios_taps
int ios_count_label
int ios_name_field
int ios_name_label

int ios_tap():
	ios_taps = ios_taps + 1
	char* count = itoa(ios_taps)
	wios_label_set(ios_count_label, count)
	print(c"ios demo tap: ")
	println(count)
	free(count)
	return 0

int ios_name_changed():
	wios_label_set(ios_name_label, wios_text_value(ios_name_field))
	return 0

int ios_setup():
	wios_label(c"A native iPhone app written in W")
	wios_label(c"Your name")
	ios_name_field = wios_text_field(c"Name", cast(void*, ios_name_changed))
	ios_name_label = wios_label(c"Type above to exercise the software keyboard.")
	wios_label(c"Tap count")
	ios_count_label = wios_label(c"0")
	wios_button(c"Tap me", cast(void*, ios_tap))
	return 0

int main(int argc, int argv):
	return wios_run(argc, argv, c"W on iPhone", cast(void*, ios_setup), 0)
