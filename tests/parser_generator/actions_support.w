/*
Host module for tests/parser_generator/actions_sample.pg (issue #329
milestone 4). The grammar's "import tests.parser_generator.actions_support"
directive makes the generator add this module to the generated parser's own
imports, so the action/predicate code it splices in (emit_push(text(1)),
&{ actions_prefer_call() }, ...) resolves against real functions instead of
undeclared symbols. generated_actions_test.w imports this module too, to
seed actions_prefer_call_flag before parsing and read back actions_emitted
afterwards.
*/
import lib.lib
import lib.container
import structures.string


list[char*] actions_emitted
int actions_prefer_call_flag


void actions_reset():
	actions_emitted = new list[char*]
	actions_prefer_call_flag = 0


void actions_emit_push(char* text):
	string_builder* out = string_new()
	string_append(out, c"PUSH ")
	string_append(out, text)
	actions_emitted.push(out.data)
	free(out)


void actions_emit_push_name(char* text):
	string_builder* out = string_new()
	string_append(out, c"PUSHN ")
	string_append(out, text)
	actions_emitted.push(out.data)
	free(out)


void actions_emit_call(char* text):
	string_builder* out = string_new()
	string_append(out, c"CALL ")
	string_append(out, text)
	actions_emitted.push(out.data)
	free(out)


void actions_emit_op(char* name):
	actions_emitted.push(strclone(name))


int actions_prefer_call():
	return actions_prefer_call_flag
