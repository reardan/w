#!/bin/sh
# Run a command inside the w-dev Linux container (arm64 Ubuntu with binfmt
# emulation for the 32-bit x86 seed). The repo is bind-mounted at /w, so
# artifacts written to bin/ are immediately visible on the macOS host.
#
# Usage: tools/mac/wdev.sh ./wbuild verify
#        tools/mac/wdev.sh ./bin/wv2 arm64_darwin tests/hello.w -o bin/hello
#
# One-time setup (repeat the binfmt step after a Docker VM restart):
#   docker run --privileged --rm tonistiigi/binfmt --install 386,amd64
#   docker run -d --name w-dev -v "$(pwd)":/w -w /w ubuntu:24.04 sleep infinity
#   docker exec w-dev sh -c 'apt-get update && apt-get install -y qemu-user-static file'
set -e

if ! docker inspect -f '{{.State.Running}}' w-dev 2>/dev/null | grep -q true; then
	echo "wdev: starting w-dev container" >&2
	docker start w-dev >/dev/null 2>&1 || {
		echo "wdev: container missing; see setup comment in $0" >&2
		exit 1
	}
fi

exec docker exec -w /w w-dev "$@"
