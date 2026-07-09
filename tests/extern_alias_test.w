# Extern alias test: '= "symbol"' binds a library symbol under a different
# W name, so one C symbol can be declared once per call signature (the
# pattern objc_msgSend needs on the darwin backend).

c_lib "libc.so.6"

extern int libc_puts(char* s) = "puts"
# Same symbol again under another name and signature: each alias gets its
# own shim and GOT slot, both bound to the one library symbol.
extern int libc_puts2(char* s) = c"puts"
extern int getppid()
extern int libc_getppid() = "getppid"
extern int fflush(int stream)


int _main():
	int rc = 0
	if (libc_puts(c"extern alias puts") < 0):
		rc = 1
	if (libc_puts2(c"extern alias prefixed-string puts") < 0):
		rc = 1
	# An aliased symbol and the plain declaration of the same function
	# must agree.
	if (libc_getppid() != getppid()):
		libc_puts(c"FAIL: aliased getppid disagrees with plain getppid")
		rc = 1
	if (rc == 0):
		libc_puts(c"extern alias OK")

	fflush(0)
	return rc
