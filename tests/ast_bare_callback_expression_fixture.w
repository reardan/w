type ast_bare_hook = fn(int) -> void

struct ast_bare_hooks:
	ast_bare_hook after

int ast_bare_seen
void ast_bare_write(int value): ast_bare_seen = value

int ast_forward_use(): return ast_forward_pick[int](12, 7)
T ast_forward_pick[T](T a, T b): return a < b ? a : b

int main():
	ast_bare_hooks hooks
	hooks.after = 0
	if (hooks.after != 0): return 1
	hooks.after = cast(ast_bare_hook, ast_bare_write)
	ast_bare_hook hook = hooks.after
	hook(42)
	if (ast_bare_seen != 42): return 2
	ast_bare_hook copy = hook
	copy(7)
	if (ast_bare_seen != 7): return 3
	if (cast(int, copy) != cast(int, hook)): return 4
	if (ast_forward_use() != 7): return 5
	return 0
