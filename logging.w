import lib


char *logging_filename
int logging_file


# Put time string into buffer
char* get_time_string():
	return "2022-03-07 08:51:67"


void log(char* str):
	int i = 0
	# Write time
	# Write string


# logging_init("/var/log/whttp/")
void logging_init(char* directory):
	# Make directory if it doesnt exist
	int err = mkdir(directory, 511)
	

	# Get Time
	char* time_string = get_time_string()
	char* dir_joined = strjoin(directory, "/")
	logging_filename = strjoin(dir_joined, time_string)
	free(dir_joined)

	# Open Log File (O_APPEND=0x2000=8192)
	logging_file = open(logging_filename, 8192)


int main(int argc, int argv):
	logging_init("log")
	log("Hi there!\x0a")
	close(logging_file)
	return 0

