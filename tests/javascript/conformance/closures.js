function make(x) { return function(y) { x += y; return x; }; } const add = make(3); add(4); add(5);
