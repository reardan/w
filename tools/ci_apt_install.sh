#!/bin/sh
# Install Ubuntu packages on a CI runner without letting one bad mirror
# eat the job's whole timeout. .github/actions/apt-install wraps this
# with a .deb cache; call it through that action.
#
# usage: tools/ci_apt_install.sh [--i386] package...
#
# The runner's mirror sometimes stops sending bytes in the middle of
# apt-get update or a download (a shard once sat 30 minutes there until
# the job was cancelled), and sometimes trickles at 40-60 kB/s for every
# download (26 MB of packages took 7.5 minutes, and wine's 105 MB never
# finished inside 15). So:
#
# - W_APT_ARCHIVES, when set, is the directory apt keeps its .deb files
#   in (Dir::Cache::Archives). The action restores it from the Actions
#   cache before the install and saves it after, so a warm cache needs
#   no package downloads at all. apt checks every cached .deb against
#   the signed index's hash and re-downloads any that do not match, so
#   a stale or foreign file can only cost a download. autoclean drops
#   versions the index no longer lists, so the cache does not grow.
# - Each update/install attempt runs under its own timeout, apt drops
#   connections idle for 30s and retries each fetch itself, and the
#   whole attempt is repeated up to three times. Partial downloads carry
#   over to the next attempt.
# - Before each retry the Azure mirror is moved to the end of the
#   runner's mirror list (/etc/apt/apt-mirrors.txt, tried in priority
#   order), so a retry does not just ask the same slow mirror again.
#
# The step's timeout-minutes in the workflow bounds the total.
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
archives="${W_APT_ARCHIVES:-}"
if [ -n "$archives" ]; then
	mkdir -p "$archives/partial"
	# Root downloads straight into the runner-owned cache directory; the
	# _apt sandbox user cannot reach it under the runner's home.
	apt_opts="$apt_opts -o Dir::Cache::Archives=$archives -o APT::Sandbox::User=root"
	echo "apt cache: $(find "$archives" -maxdepth 1 -name '*.deb' | wc -l) .deb files restored"
fi

mirrors="${W_APT_MIRRORS_FILE:-/etc/apt/apt-mirrors.txt}"  # overridable for testing

attempt=1
while :; do
	# shellcheck disable=SC2086 # apt_opts is a word list
	if sudo timeout --kill-after=15s 120s apt-get $apt_opts update &&
		sudo timeout --kill-after=15s 360s apt-get $apt_opts install --yes --no-install-recommends "$@"; then
		if [ -n "$archives" ]; then
			# shellcheck disable=SC2086
			sudo apt-get $apt_opts autoclean > /dev/null || true
			# The Actions cache save runs as the runner user.
			sudo chown -R "$(id -u):$(id -g)" "$archives"
		fi
		exit 0
	fi
	if [ "$attempt" -ge 3 ]; then
		echo "::error::apt-get failed after $attempt attempts"
		exit 1
	fi
	echo "::warning::apt-get attempt $attempt failed or timed out; retrying"
	if [ -f "$mirrors" ] && grep -q 'azure\.archive\.ubuntu\.com.*priority:' "$mirrors"; then
		sudo sed -i -E '/azure\.archive\.ubuntu\.com/ s/priority:[0-9]+/priority:9/' "$mirrors"
		echo "apt mirrors now:"
		sed 's/^/    /' "$mirrors"
	fi
	attempt=$((attempt + 1))
	sleep 10
done
