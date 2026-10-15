# Target pointer width, set by the compiler driver for the selected arch.
# A leaf module so libraries that only read it (the C preprocessor's
# predefined macros) need not import the whole code emitter.
int word_size
int word_size_log2
