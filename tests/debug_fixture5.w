# Debuggee with UTF-8 names for the wdbg print command (#287): a local
# and a global the debugger must read as whole words.
import lib.lib

int zähler = 5


int main(int argc, int argv):
	int größe = 3
	größe = größe + 4
	zähler = zähler + größe
	debugger
	println(c"after breakpoint")
	return größe
