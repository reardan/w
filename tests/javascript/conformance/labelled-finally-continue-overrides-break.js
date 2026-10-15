let n = 0; a: while (n < 3) { try { break a; } finally { n++; continue a; } } n;
