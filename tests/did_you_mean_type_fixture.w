# A misspelled type name gets the closest declared type as '= help'
# (#377); a name nothing resembles gets no help line at all.
# expect_fail
# expect_stderr: error: unknown type name: 'Vectr'
# expect_stderr:    = help: did you mean 'Vector'?
import lib.lib


struct Vector:
	int x
	int y


int length_squared(Vectr* v):
	return v.x * v.x + v.y * v.y
