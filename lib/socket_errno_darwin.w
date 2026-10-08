# Pure native-Darwin to portable-status errno mapping, split out so the
# collision cases can also be tested on a Linux host. This value is only
# for io_status_from_errno; callers preserve the original native errno.
int socket_darwin_status_errno(int err):
	if (err == 0): return 0
	if (err == 4): return 4     # EINTR
	if (err == 28): return 28   # ENOSPC
	if (err == 35): return 11   # EAGAIN
	if (err == 60): return 110  # ETIMEDOUT
	if (err == 89): return 125  # ECANCELED
	if ((err == 45) || (err == 102)): return 95 # ENOTSUP/EOPNOTSUPP
	if (err == 78): return 38   # ENOSYS
	if (err == 69): return 122  # EDQUOT
	return 5 # generic I/O error; never reinterpret another native errno
