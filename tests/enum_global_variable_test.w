# A global variable of enum type holds a runtime value: unlike an enum
# constant (same type kind), reading it must load from memory and never
# fold to the initializer (or read the image at a code-stream address,
# which crashed the compiler once data and code were split).
# wbuild: x64
import lib.assert


enum eg_color:
	EG_RED
	EG_GREEN = 5
	EG_BLUE


eg_color eg_current = EG_GREEN
eg_color eg_unset
const eg_color eg_fixed = EG_BLUE


void eg_set(eg_color c):
	eg_current = c


int eg_read():
	return eg_current


int main():
	assert_equal(5, eg_read())
	eg_set(EG_RED)
	assert_equal(0, eg_read())
	assert_equal(EG_RED, eg_current)
	eg_set(EG_BLUE)
	assert_equal(6, eg_current + 0)
	assert_equal(0, eg_unset)
	eg_unset = EG_GREEN
	assert_equal(5, eg_unset)
	assert_equal(6, eg_fixed)
	assert_equal(6, EG_BLUE)
	return 0
