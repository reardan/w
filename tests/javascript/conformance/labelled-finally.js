var total=0; outer: while(total<3) { inner: while(true) { try { break outer; } finally { total++; continue outer; } } } total;
