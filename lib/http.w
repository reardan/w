import lib.lib


void http_write_response_headers(int file, int status_code, char* reason, char* content_type, int content_length, char* connection):
	write_string(file, "HTTP/1.1 ")
	write_string(file, itoa(status_code))
	write_string(file, " ")
	write_string(file, reason)
	write_string(file, "\x0d\x0a")
	write_string(file, "Server: whttp\x0d\x0a")
	write_string(file, "Content-Type: ")
	write_string(file, content_type)
	write_string(file, "\x0d\x0a")
	write_string(file, "Content-Length: ")
	write_string(file, itoa(content_length))
	write_string(file, "\x0d\x0a")
	write_string(file, "Connection: ")
	write_string(file, connection)
	write_string(file, "\x0d\x0a\x0d\x0a")


void http_write_ok_headers(int file, char* content_type, int content_length):
	http_write_response_headers(file, 200, "OK", content_type, content_length, "close")
