/* Compiled separately: the checker must inspect these precompiled instructions. */
int wgrind_precompiled_load(unsigned char *address) {
    return *address;
}
