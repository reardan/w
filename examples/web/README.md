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

`http_server` and `http_proxy` each handle one request and then exit. This keeps
the examples easy to run from scripts while still showing the complete request,
response, and proxy flow.
