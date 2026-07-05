# JSON-RPC 2.0 server over stdio using Content-Length framing — the same
# wire format as the MCP server in tools/mcp/w_toolchain_mcp.w.
#
# Build and try it:
#   ./bin/wv2 examples/web/json_rpc_server.w -o ./bin/json_rpc_server
#   printf 'Content-Length: 55\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"add","params":[40,2]}' | ./bin/json_rpc_server
import lib.lib
import lib.json_rpc


json_value* rpc_ping(json_value* params, void* ctx):
	return json_string(c"pong")


json_value* rpc_add(json_value* params, void* ctx):
	if (params == 0):
		return 0
	if (params.type != json_type_array()):
		return 0
	int sum = 0
	int i = 0
	while (i < json_array_length(params)):
		json_value* item = json_array_get(params, i)
		if (item.type != json_type_int()):
			return 0
		sum = sum + item.int_value
		i = i + 1
	return json_int(sum)


json_value* rpc_shutdown(json_value* params, void* ctx):
	jsonrpc_stop(cast(jsonrpc_server*, ctx))
	return json_bool(1)


# Typed params via the to_json/from_json builtins: params like
# {"x":3,"y":4} decode straight into a struct, and the struct result
# encodes back to JSON.
struct move_params:
	int x
	int y


json_value* rpc_move(json_value* params, void* ctx):
	move_params* p = from_json(move_params, params)
	if (p == 0):
		return 0
	move_params moved
	moved.x = p.x + 1
	moved.y = p.y + 1
	free(cast(char*, cast(int, p)))
	return to_json(moved)


int main(int argc, int argv):
	jsonrpc_server* s = jsonrpc_server_new()
	s.context = cast(void*, s)
	jsonrpc_register(s, c"ping", rpc_ping)
	jsonrpc_register(s, c"add", rpc_add)
	jsonrpc_register(s, c"move", rpc_move)
	jsonrpc_register(s, c"shutdown", rpc_shutdown)
	int status = jsonrpc_serve_blocking(s, 0, 1)
	jsonrpc_server_free(s)
	return 0 - status
