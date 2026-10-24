#!/bin/sh
# Stand-in for ssh in tests/wexec_remote_exec_test.w (WEXEC_REMOTE_SSH):
# drops the host and runs the command string here, the way sshd hands it
# to the remote login shell. WEXEC_FAKE_SSH_LOG, when set, records one
# line per connection.
if [ -n "${WEXEC_FAKE_SSH_LOG:-}" ]; then
	echo "$1" >> "$WEXEC_FAKE_SSH_LOG"
fi
shift
exec sh -c "$1"
