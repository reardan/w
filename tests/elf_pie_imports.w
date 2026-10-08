# An unused declaration still emits the GOT and dynamic relocations.
c_lib "libc.so.6"
extern int puts(char* text)
