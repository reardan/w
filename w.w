/*
Wesley Reardan based on work by Edmund GRIMLEY EVANS <edmundo@rano.org>
W Language
A self-compiling compiler for a small subset of C.

TODO
====
test:
	&, *, ! for char + int
operators:
	for
	in
	range
	yield
	and
	or
	not
	import

features:
	generators
	repl
	debugging
	symbols
	import

types:
	float

Data Structures:
	List
		String
		Map
			Set
			Object
		Stack
		Queue
		Heap
			PriorityQueue
		Node
		Edge
		Tree
			Trie
		Graph
		Collection
		SSTable

	List
		append
		appendleft
		clear
		copy
		count
		extend
		extendleft
		index
		insert
		pop
		popleft
		remove
		reverse
		rotate

		LinkedList
		DoublyLinkedList
		ArrayList
		RingBuffer
		FlatList

	File
	Stream
*/
import lib
import tokenizer
import codegen
import symbol_table
import grammar


void compile(char* fn):
	filename = fn
	file = open(filename, 0, 511)
	line_number = 0
	tab_level = 0
	nextc = get_character()
	get_token()
	program()


void compile_save(char* fn):
	char* old_filename = filename
	int old_file = file
	int old_line_number = line_number
	int old_tab_level = old_tab_level

	compile(fn)
	close(file)

	filename = old_filename
	file = old_file
	line_number = old_line_number
	tab_level = old_tab_level
	nextc = get_character()
	get_token()

	if (verbosity > 0):
		print_error("switching back to '")
		print_error(filename)
		print_error("'\x0a")


int link(int argc, int argv):
	last_global_declaration = malloc(8000)
	be_start()

	int i = 1
	while (i < argc):
		int arg = argv + i * 4
		print_error("compiling '")
		print_error(*arg)
		print_error("'\x0a")
		compile(*arg)
		i = i + 1

	emit_debugging_symbols()
	be_finish()


int main(int argc, int argv):
	verbosity = 0
	link(argc, argv)
	return 0

