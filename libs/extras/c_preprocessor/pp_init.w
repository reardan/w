/*
Predefined macro setup.
*/
import lib.lib
import structures.hash_map
import code_generator.code_emitter
import libs.extras.c_preprocessor.pp_token
import libs.extras.c_preprocessor.pp_lexer
import libs.extras.c_preprocessor.pp_macro


cpp_token* cpp_init_number_body(int value):
	char* text = itoa(value)
	cpp_token* token = cpp_token_new(cpp_token_number(), text, "<builtin>", 0, 0, 0)
	free(text)
	token.next = cpp_token_new(cpp_token_eof(), "", "<builtin>", 0, 0, 0)
	return token


void cpp_init_define_number(hash_map* macros, char* name, int value):
	cpp_macro_define_object(macros, name, cpp_init_number_body(value))


void cpp_init_define_empty(hash_map* macros, char* name):
	cpp_macro_define_object(macros, name, cpp_token_new(cpp_token_eof(), "", "<builtin>", 0, 0, 0))


int cpp_target_word_size():
	if (word_size != 0):
		return word_size
	return __word_size__


void cpp_init_predefined_macros(hash_map* macros):
	cpp_init_define_number(macros, "__STDC__", 1)
	cpp_init_define_number(macros, "__STDC_VERSION__", 199901)
	cpp_init_define_number(macros, "__STDC_HOSTED__", 1)
	cpp_init_define_number(macros, "__CHAR_BIT__", 8)
	cpp_init_define_number(macros, "__ORDER_LITTLE_ENDIAN__", 1234)
	cpp_init_define_number(macros, "__BYTE_ORDER__", 1234)
	cpp_init_define_number(macros, "__SIZEOF_CHAR__", 1)
	cpp_init_define_number(macros, "__SIZEOF_SHORT__", 2)
	cpp_init_define_number(macros, "__SIZEOF_INT__", cpp_target_word_size())
	cpp_init_define_number(macros, "__SIZEOF_LONG__", cpp_target_word_size())
	cpp_init_define_number(macros, "__SIZEOF_POINTER__", cpp_target_word_size())
	cpp_init_define_number(macros, "__linux__", 1)
	cpp_init_define_number(macros, "__linux", 1)
	cpp_init_define_number(macros, "linux", 1)
	cpp_init_define_number(macros, "unix", 1)
	if (cpp_target_word_size() == 8):
		cpp_init_define_number(macros, "__x86_64__", 1)
		cpp_init_define_number(macros, "__LP64__", 1)
		cpp_init_define_number(macros, "_LP64", 1)
	else:
		cpp_init_define_number(macros, "__i386__", 1)
		cpp_init_define_number(macros, "__ILP32__", 1)
	cpp_macro_define_builtin(macros, "__FILE__", cpp_macro_builtin_file())
	cpp_macro_define_builtin(macros, "__LINE__", cpp_macro_builtin_line())
