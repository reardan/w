# expect_fail
# expect_stderr: member 'sum' on non-struct type 'int'
# '.member' on a non-struct expression used to be silently ignored, so a
# method chained onto a non-struct call result (here: int) compiled into
# a call through a garbage receiver and crashed at runtime. It must be
# rejected at compile time (docs/projects/struct_methods.md).


struct chain_err_point:
	int x


int chain_err_point_sum(chain_err_point* self):
	return self.x


int main():
	chain_err_point p
	p.x = 1
	return p.sum().sum()
