# Small external consumer: bounded resource loading plus independent HTML/CSS.
# Compile with an explicit W import root when this file is outside the checkout.
import lib.args
import libs.standard.web.content_decode
import libs.extras.compress.codecs
import libs.extras.html.html
import libs.extras.css.css


int resource_same_origin(void* context, URL* from, URL* to, int status):
	return url_same_origin(from, to)


int main(int argc, int argv):
	args_init(argc, argv)
	char* target = args_get(1)
	if (target == 0):
		println(c"usage: browser_resource http://host/document")
		return 1
	compress_codecs_register()
	http_client* client = http_client_new()
	http_req* request = http_req_new(c"GET", target)
	request.client = client
	request.total_timeout_ms = 10000
	request.approve_redirect = resource_same_origin
	http_req_add_header(request, c"Accept-Encoding", c"gzip, deflate")
	http_stream* stream = http_open(request)
	content_decoder* content = http_content_collect(stream, 1048576, 4194304)
	int code = 0
	if (content.status != content_decode_done):
		print_int(c"content error: ", content.status)
		print_string(c"transport error: ", stream.resp.error_message)
		code = 1
	else:
		print_string(c"final URL: ", stream.resp.final_url)
		html_document* document = html_parse(content.output, content.output_length)
		print_int(c"HTML failed: ", document.failed)
		html_document_free(document)
		char* style = c"body { color: #222; margin: 1em }"
		css_document* stylesheet = css_parse_stylesheet_n(style, strlen(style), 0)
		print_int(c"CSS rules: ", stylesheet.nodes.length)
		css_document_free(stylesheet)
	content_decoder_free(content)
	http_stream_close(stream)
	http_req_free(request)
	http_client_free(client)
	return code
