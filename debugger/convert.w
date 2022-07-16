/*
tool for converting between various formats
*/


/*
objdump -d ~/git/net/tcp | ./bin/convert

/home/w/git/net/tcp:     file format elf32-i386


Disassembly of section .text:

08049000 <_start>:
 8049000:	b8 66 00 00 00       	mov    $0x66,%eax
 8049005:	bb 01 00 00 00       	mov    $0x1,%ebx
 804900a:	31 d2                	xor    %edx,%edx
 804900c:	89 e1                	mov    %esp,%ecx
 804900e:	83 c1 04             	add    $0x4,%ecx
 8049011:	cd 80                	int    $0x80
 8049013:	c3                   	ret 
*/
import lib.lib
import compiler.tokenizer
import structures.list


int main_args(int argc, int argv):
	int i = 1
	while (i < argc):
		int arg = argv + i * 4
		print_string("arg: ", *arg)
		i = i + 1
	return 0


int get_char():
	return getchar(0)


void setup_tokenizer():
	filename = "stdin"
	file = 0
	line_number = 0
	tab_level = 0
	nextc = get_character()
	get_token()


void read_until_start():
	while (accept("_start") == 0):
		get_token()


int is_hex_char(int c):
	if (c >= '0' & c <= '9'):
		return 1
	if (c >= 'a' & c <= 'f'):
		return 1
	return 0


int push_all_tokens():
	while(token[0] != 0):
		# huge hack lol but it works:
		if (strlen(token) == 2):
			if (is_hex_char(token[0]) & is_hex_char(token[1])):
				char* delimiter = ""
				delimiter = "\x5cx"
				push(strjoin(delimiter, token))
		get_token()


int main(int argc, int argv):
	setup_tokenizer()
	read_until_start()
	push_all_tokens()

	print("emit(")
	print(itoa(length))
	print(", \x22") /* quotes */
	print(join(""))
	println("\x22)")
	return 0
