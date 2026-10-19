"""Exercise the public resource example in-tree and as an external dependency.

Run through ./wbuild browser_resource_consumer_test. Only loopback HTTP is used;
the temporary consumer has no checkout-relative imports or generated files.
"""
import gzip
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import zlib


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "examples/web/browser_resource.w"
DOCUMENT = b"<title>Consumer</title><style>p { color: red }</style><p>Hello &amp; W<p>EOF"


class ResourceHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("Accept-Encoding")))
        body = DOCUMENT
        encoding = "identity"
        status = 200
        location = None
        if self.path == "/redirect":
            status, location, body = 302, "./gzip?loaded#retained", b"skip"
        elif self.path == "/blocked":
            status, body = 302, b""
            location = f"http://localhost:{self.server.server_port}/unexpected"
        elif self.path.startswith("/gzip"):
            encoding, body = "gzip", gzip.compress(body, mtime=0)
        elif self.path == "/deflate":
            encoding, body = "deflate", zlib.compress(body)
        elif self.path == "/corrupt":
            encoding, body = "gzip", gzip.compress(body, mtime=0)[:-1]
        elif self.path == "/unsupported":
            encoding = "br"
        elif self.path == "/expanded-limit":
            encoding, body = "gzip", gzip.compress(b"x" * 4194305, mtime=0)
        elif self.path == "/html-limit":
            body = b"<div>" * 300
        self.send_response(status)
        self.send_header("Content-Encoding", encoding)
        self.send_header("Content-Length", str(len(body) + (10 if self.path == "/partial" else 0)))
        if location is not None:
            self.send_header("Location", location)
        self.end_headers()
        self.wfile.write(body)


def run(command, cwd, expected=0):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=30)
    if result.returncode != expected:
        raise AssertionError(
            f"{command}: expected exit {expected}, got {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    # W's print_int/print_string diagnostic helpers write to stderr.
    return result.stdout + result.stderr


def exercise(binary, cwd, server):
    base = f"http://127.0.0.1:{server.server_port}"
    for path in ("/identity", "/gzip", "/deflate", "/redirect", "/blocked"):
        server.requests.clear()
        output = run([str(binary), base + path], cwd)
        final = "/gzip?loaded#retained" if path == "/redirect" else path
        expected = f"final URL: {base}{final}\nHTML failed: 0\nCSS rules: 1\n"
        if output != expected:
            raise AssertionError(f"{binary} {path}: unexpected output {output!r}")
        paths = [request[0] for request in server.requests]
        if paths != ([path, "/gzip?loaded"] if path == "/redirect" else [path]):
            raise AssertionError(f"unexpected requests (redirect approval/fragments): {paths}")
        if any(encoding != "gzip, deflate" for _, encoding in server.requests):
            raise AssertionError("consumer did not advertise its registered encodings")
    for path, error in (("/corrupt", 4), ("/unsupported", 5),
                        ("/expanded-limit", 3), ("/partial", 7)):
        output = run([str(binary), base + path], cwd, expected=1)
        if not output.startswith(f"content error: {error}\n") or "HTML failed:" in output:
            raise AssertionError(f"{binary} {path}: invalid content reached parser: {output!r}")
    output = run([str(binary), base + "/html-limit"], cwd, expected=1)
    if "HTML failed: 1\n" not in output:
        raise AssertionError(f"HTML depth limit not reported: {output!r}")


def main():
    with HTTPServer(("127.0.0.1", 0), ResourceHandler) as server:
        server.requests = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="w browser consumer ") as directory:
                work = Path(directory)
                shutil.copyfile(SOURCE, work / "main.w")
                for arch, name in (([], "browser_resource_consumer"),
                                   (["x64"], "browser_resource_consumer_64")):
                    exercise(ROOT / "bin" / name, work, server)
                    binary = work / name
                    run([str(ROOT / "bin/wv2"), *arch, "--strict", "--import-root",
                         str(ROOT), "main.w", "-o", str(binary)], work)
                    exercise(binary, work, server)
        finally:
            server.shutdown()
            thread.join(timeout=5)
    print("browser resource consumers OK")


if __name__ == "__main__":
    main()
