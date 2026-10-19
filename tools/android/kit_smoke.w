# wbuild: binary=android_kit_smoke tag=tests
import tools.host_tools
import lib.str
import lib.net
import libs.standard.cli.argparse

char* aks_serial
char* aks_port
int aks_server

process_result* aks_run(list[char*] args, int check = 1):
	list[char*] command = ht_argv(c"adb", c"-s", aks_serial)
	for char* arg in args: command.push(arg)
	process_result* result = ht_run(command, 0, 0, 60000)
	if (check): ht_success(result)
	return result

void aks_cleanup():
	if (aks_port != 0): aks_run(ht_argv(c"reverse", c"--remove", aks_port), 0)
	if (aks_server > 0):
		kill(aks_server, 9)
		wait4(aks_server, 0, 0, 0)

void aks_serve(int listener):
	while (1):
		int client = socket_accept_connection(listener)
		if (client < 0): continue
		string_builder* header = string_new()
		char ch = 0
		while (header.length < 16384 && read(client, &ch, 1) == 1):
			string_append_char(header, ch)
			if (contains(header.data, c"\r\n\r\n")): break
		char* body = c"missing header"
		if (contains(header.data, c"X-Kit: 1\r\n") || contains(header.data, c"x-kit: 1\r\n")): body = c"kit-http-ok"
		char* response = strjoin(strjoin(c"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: ", itoa(strlen(body))), strjoin(c"\r\n\r\n", body))
		io_result result
		io_write_all(client, response, strlen(response), &result)
		close(client)
		string_free(header)

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"android_kit_smoke")
	argparse_arg_required(argparse_add_option(parser, c"--serial", c"SERIAL", c"adb device serial"))
	argparse_arg_default(argparse_add_option(parser, c"--package", c"ID", c"application"), c"org.wlang.kitdemo")
	argparse_arg_default(argparse_add_option(parser, c"--apk", c"FILE", c"APK"), c"bin/android/kit/WApp.apk")
	argparse_arg_default(argparse_add_option(parser, c"--screenshot", c"FILE", c"PNG output"), c"bin/android/kit/preview.png")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	aks_serial = argparse_get(args, c"serial")
	int listener = socket_tcp_ipv4()
	ht_require(listener >= 0 && socket_bind_ipv4(listener, 0x7f000001, 0) == 0 && socket_listen(listener, 8) == 0, c"cannot start loopback HTTP fixture")
	sockaddr_in address
	ht_require(socket_getsockname_ipv4(listener, &address) == 0, c"cannot discover HTTP port")
	char* port = itoa(net_htons(address.port))
	aks_port = strjoin(c"tcp:", port)
	aks_server = fork()
	ht_require(aks_server >= 0, c"cannot fork HTTP fixture")
	if (aks_server == 0):
		aks_serve(listener)
		exit(0)
	close(listener)
	ht_on_cleanup = aks_cleanup
	char* package = argparse_get(args, c"package")
	char* activity = strjoin(package, c"/org.wlang.androiddemo.WActivity")
	aks_run(ht_argv(c"install", c"--no-incremental", c"-r", argparse_get(args, c"apk")))
	aks_run(ht_argv(c"reverse", aks_port, aks_port))
	aks_run(ht_argv(c"shell", c"am", c"force-stop", package))
	char* since = strip(aks_run(ht_argv(c"shell", c"date '+%m-%d %H:%M:%S.000'")).stdout_text)
	aks_run(ht_argv(c"shell", c"am", c"start", c"-W", c"-n", activity, c"-d", strjoin(strjoin(c"wkit:smoke?http://127.0.0.1:", port), c"/kit")))
	list[char*] markers = ht_split(c"kit smoke: press back|kit smoke: dismiss dialog|kit smoke: send deep link", '|')
	set[char*] done = new set[char*]
	int deadline = process_monotonic_ms() + 60000
	char* logs = c""
	while (process_monotonic_ms() < deadline):
		logs = aks_run(ht_argv(c"logcat", c"-d", c"-T", since, c"-s", c"WAndroid:I", c"AndroidRuntime:E", c"*:S")).stdout_text
		if (contains(logs, c"kit smoke: FAILED") || contains(logs, c"FATAL EXCEPTION")): break
		if (contains(logs, c"kit smoke: ok")):
			char* screenshot = argparse_get(args, c"screenshot")
			ht_mkdir(path_dirname(screenshot))
			process_result* result = aks_run(ht_command(c"exec-out screencap -p"))
			ht_write(screenshot, result.stdout_text, result.stdout_length)
			ht_cleanup()
			println(c"Android kit screens, lists, text, secrets, timer, HTTP, back, dialog, deep link, permission: OK")
			println(screenshot)
			return 0
		for i in range(markers.length):
			if (!contains(logs, markers[i]) || markers[i] in done): continue
			done.add(markers[i])
			process_sleep_ms(500)
			if (i < 2): aks_run(ht_command(c"shell input keyevent 4"))
			else: aks_run(ht_argv(c"shell", c"am", c"start", c"-a", c"android.intent.action.VIEW", c"-d", c"wkit:ping", package))
		process_sleep_ms(500)
	println2(c"Android kit smoke failed or timed out:")
	print2(logs)
	ht_cleanup()
	return 1
