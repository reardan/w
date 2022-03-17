/*
read
eval
print
loop
*/
import compiler
import assert


int history_filename
int history_file


int main(int argc, int argv):
	verbosity = 1

	# Open history file
	# todo: use date /Y_M_D_h_m_s.w
	history_filename = "~/.w/sessions/session1.w"
	history_file = open(history_filename, 0, 511)

	while (1):
		# Read
		# Eval
		# Print

	exit_w(0)