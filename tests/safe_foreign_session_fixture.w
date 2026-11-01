# The owner exists before a debugger expression introduces an attestation.
own int* session_identity(own int* value):
	return value


int main():
	own int* before = new int
	*before = 73
	debugger
	own int* after = session_identity(before)
	return *after - 73
