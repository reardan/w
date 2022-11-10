

inline asm int "this * integer"(int right):
	mov eax, [this]
	add eax, [right]


inline asm int "this / integer"(int right):
	mov eax, [this]
	idiv eax, [right]


inline asm int "this + integer"(int right):
	mov eax, [this]
	add eax, [right]


inline asm int "this - integer"(int right):
	mov eax,[ this]
	sub eax, [right]
