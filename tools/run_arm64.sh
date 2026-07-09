#!/bin/sh
# Run an aarch64-Linux binary: natively when the host is arm64 Linux
# (the w-dev container), otherwise under qemu. Replaces the Makefile's
# `QEMU_ARM64 ?= qemu-aarch64-static -cpu max`; set the QEMU_ARM64
# environment variable to override the emulator command.
if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "aarch64" ]; then
	exec "$@"
fi
exec ${QEMU_ARM64:-qemu-aarch64-static -cpu max} "$@"
