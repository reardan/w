# No local AF_UNIX VM transport on this port. Sandbox requests fail closed.
import lib.process


process_result* wvm_client_cell_run(char* socket_path, char* image, int template_id, char** argv, char* input, int timeout_ms):
	return 0
