typedef unsigned long size_t;

typedef struct point {
	int x;
	int y;
} point;

enum color {
	red,
	green = 4,
	blue
};

extern int puts(const char *s);
