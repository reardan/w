import lib.lib


void http_write_response_headers(int file, int status_code, char* reason, char* content_type, int content_length, char* connection):
	write_string(file, c"HTTP/1.1 ")
	write_string(file, itoa(status_code))
	write_string(file, c" ")
	write_string(file, reason)
	write_string(file, c"\x0d\x0a")
	write_string(file, c"Server: whttp\x0d\x0a")
	write_string(file, c"Content-Type: ")
	write_string(file, content_type)
	write_string(file, c"\x0d\x0a")
	write_string(file, c"Content-Length: ")
	write_string(file, itoa(content_length))
	write_string(file, c"\x0d\x0a")
	write_string(file, c"Connection: ")
	write_string(file, connection)
	write_string(file, c"\x0d\x0a\x0d\x0a")


void http_write_ok_headers(int file, char* content_type, int content_length):
	http_write_response_headers(file, 200, c"OK", content_type, content_length, c"close")
