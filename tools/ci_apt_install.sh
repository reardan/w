#!/bin/sh
# Install Ubuntu packages on a CI runner without letting one bad mirror
# eat the job's whole timeout.
#
# usage: tools/ci_apt_install.sh [--i386] package...
#
# The runner's mirror sometimes stops sending bytes in the middle of
# apt-get update or a download (a shard once sat 30 minutes there until
# the job was cancelled) and sometimes trickles at ~60 kB/s (26 MB of
# packages took 7.5 minutes). Each update/install attempt therefore runs
# under its own timeout, apt drops connections idle for 30s and retries
# each fetch itself, and the whole attempt is repeated up to three
# times. Partial downloads stay in /var/cache/apt/archives/partial, so a
# slow attempt that times out still advances the next one. The step's
# timeout-minutes in the workflow bounds the total.
set -u

if [ "${1:-}" = "--i386" ]; then
	shift
	sudo dpkg --add-architecture i386
fi
if [ "$#" -eq 0 ]; then
	echo "usage: $0 [--i386] package..." >&2
	exit 2
fi

apt_opts="-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"

attempt=1
while :; do
	# shellcheck disable=SC2086 # apt_opts is a word list
	if sudo timeout --kill-after=15s 120s apt-get $apt_opts update &&
		sudo timeout --kill-after=15s 360s apt-get $apt_opts install --yes --no-install-recommends "$@"; then
		exit 0
	fi
	if [ "$attempt" -ge 3 ]; then
		echo "::error::apt-get failed after $attempt attempts"
		exit 1
	fi
	echo "::warning::apt-get attempt $attempt failed or timed out; retrying"
	attempt=$((attempt + 1))
	sleep 10
done
