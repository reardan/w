grammar UnsafeLoop;
root: A EOF;
A: 'a' Optional*;
fragment Optional: 'b'?;
