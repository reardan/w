/*
Pseudo-terminal helpers for x86 and x86-64 Linux (the Unix98 /dev/ptmx
interface, no libc):

	pty_open(&master, &slave)  allocate a pty pair: open /dev/ptmx, unlock
	                           it (TIOCSPTLCK), look up its number
	                           (TIOCGPTN) and open /dev/pts/N. Both fds are
	                           O_RDWR | O_NOCTTY | O_CLOEXEC. Returns 0 or a
	                           negative errno.
	pty_login_tty(slave)       child-side, after fork: start a new session
	                           (setsid), make slave its controlling
	                           terminal (TIOCSCTTY) and dup2 it onto fds
	                           0, 1 and 2 -- what login_tty(3) does.
	pty_setsid()               the setsid syscall (x86 66, x86-64 112).

grantpt(3) has nothing to do on a devpts system (the kernel creates the
slave with the caller's uid), so unlocking is the only step before
opening the slave. The parent must close its copy of the slave after
forking: reads on the master only report EOF (EIO) once every slave fd
is closed. Used by tools/pty_drive.w.
*/
import lib.lib


# O_RDWR | O_NOCTTY | O_CLOEXEC (identical on i386 and x86-64).
int pty_open_flags():
	return 2 | 256 | 524288


int pty_setsid():
	if (__word_size__ == 8):
		return syscall(112, 0, 0, 0)
	return syscall(66, 0, 0, 0)


int pty_open(int* master_out, int* slave_out):
	int master = open(c"/dev/ptmx", pty_open_flags(), 0)
	if (master < 0):
		return master
	# Both ioctls take a pointer to a 32-bit int; the word is pre-zeroed,
	# so TIOCSPTLCK reads 0 (unlock).
	char* word = malloc(8)
	save_word(word, 0)
	# TIOCSPTLCK = _IOW('T', 0x31, int)
	int err = sys_ioctl(master, 0x40045431, cast(int, word))
	if (err == 0):
		# TIOCGPTN = _IOR('T', 0x30, unsigned int); bit 31 sign-extends
		# on x86-64, which the kernel's unsigned int cmd truncates away.
		err = sys_ioctl(master, cast(int, 0x80045430), cast(int, word))
	int number = load_int32(word)
	free(word)
	if (err != 0):
		close(master)
		return err
	char* digits = itoa(number)
	char* name = strjoin(c"/dev/pts/", digits)
	int slave = open(name, pty_open_flags(), 0)
	free(name)
	if (slave < 0):
		close(master)
		return slave
	*master_out = master
	*slave_out = slave
	return 0


# Returns 0 or the first negative errno; the caller normally exits on
# failure since it runs in a freshly forked child.
int pty_login_tty(int slave):
	int err = pty_setsid()
	if (err < 0):
		return err
	# TIOCSCTTY (0x540E), arg 0: do not steal a terminal owned elsewhere.
	err = sys_ioctl(slave, 0x540e, 0)
	if (err < 0):
		return err
	dup2(slave, 0)
	dup2(slave, 1)
	dup2(slave, 2)
	if (slave > 2):
		close(slave)
	return 0
