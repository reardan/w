# W web examples

These examples demonstrate the low-level socket helpers, the HTTP response
header helper, and the JSON parser/serializer.

Build them from the repository root:

```
mkdir -p bin
make build
./bin/wv2 examples/web/http_server.w -o ./bin/http_server
./bin/wv2 examples/web/http_client.w -o ./bin/http_client
./bin/wv2 examples/web/http_proxy.w -o ./bin/http_proxy
./bin/wv2 examples/web/web_file_server.w -o ./bin/web_file_server
```

Run the JSON HTTP server and client in separate terminals:

```
./bin/http_server --port=8080
./bin/http_client --port=8080 --path=/hello
```

Run the proxy in front of the server in separate terminals:

```
./bin/http_server --port=8080
./bin/http_proxy --port=8081 --upstream-port=8080
./bin/http_client --port=8081 --path=/through-proxy
```

Run the static file server from the directory you want to serve:

```
./bin/web_file_server --port=8082
curl http://127.0.0.1:8082/README.md
```

`web_file_server` serves paths relative to the current directory. It strips the
leading `/`, maps `/` to `index.html`, and rejects any path containing `..` with
`403 Forbidden` so parent directories cannot be used.

`http_server`, `http_proxy`, and `web_file_server` each handle one request and
then exit. This keeps the examples easy to run from scripts while still showing
the complete request, response, proxy, and file-serving flows.
