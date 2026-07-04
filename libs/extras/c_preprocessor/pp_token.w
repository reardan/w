/*
Preprocessing token lists and hide sets for the C preprocessor.
*/
import lib.lib


struct cpp_hideset:
	char* name
	cpp_hideset* next


struct cpp_token:
	int kind
	char* text
	char* filename
	int line
	int has_space
	int at_bol
	cpp_hideset* hideset
	cpp_token* next


int cpp_token_ident():
	return 1


int cpp_token_number():
	return 2


int cpp_token_string():
	return 3


int cpp_token_char():
	return 4


int cpp_token_punct():
	return 5


int cpp_token_other():
	return 6


int cpp_token_eof():
	return 7


int cpp_token_placemarker():
	return 8


cpp_hideset* cpp_hideset_new(char* name, cpp_hideset* next):
	cpp_hideset* set = new cpp_hideset()
	set.name = strclone(name)
	set.next = next
	return set


int cpp_hideset_contains(cpp_hideset* set, char* name):
	while (set != 0):
		if (strcmp(set.name, name) == 0):
			return 1
		set = set.next
	return 0


cpp_hideset* cpp_hideset_add(cpp_hideset* set, char* name):
	if (cpp_hideset_contains(set, name)):
		return set
	return cpp_hideset_new(name, set)


cpp_hideset* cpp_hideset_union(cpp_hideset* left, cpp_hideset* right):
	cpp_hideset* result = right
	while (left != 0):
		result = cpp_hideset_add(result, left.name)
		left = left.next
	return result


cpp_hideset* cpp_hideset_intersection(cpp_hideset* left, cpp_hideset* right):
	cpp_hideset* result = 0
	while (left != 0):
		if (cpp_hideset_contains(right, left.name)):
			result = cpp_hideset_add(result, left.name)
		left = left.next
	return result


cpp_token* cpp_token_new(int kind, char* text, char* filename, int line, int has_space, int at_bol):
	cpp_token* token = new cpp_token()
	token.kind = kind
	token.text = strclone(text)
	token.filename = filename
	token.line = line
	token.has_space = has_space
	token.at_bol = at_bol
	token.hideset = 0
	token.next = 0
	return token


cpp_token* cpp_token_clone_one(cpp_token* token):
	cpp_token* copy = cpp_token_new(token.kind, token.text, token.filename, token.line, token.has_space, token.at_bol)
	copy.hideset = token.hideset
	return copy


cpp_token* cpp_token_clone_list(cpp_token* token):
	cpp_token head
	head.next = 0
	cpp_token* tail = &head
	while (token != 0):
		if ((token.kind == cpp_token_eof()) & (token.next == 0)):
			break
		tail.next = cpp_token_clone_one(token)
		tail = tail.next
		token = token.next
	tail.next = 0
	return head.next


void cpp_token_add_hideset(cpp_token* token, cpp_hideset* set):
	while (token != 0):
		token.hideset = cpp_hideset_union(set, token.hideset)
		token = token.next


void cpp_token_append(cpp_token* head, cpp_token* token):
	while (head.next != 0):
		head = head.next
	head.next = token


cpp_token* cpp_token_last(cpp_token* token):
	if (token == 0):
		return 0
	while (token.next != 0):
		token = token.next
	return token


int cpp_token_text_equals(cpp_token* token, char* text):
	if (token == 0):
		return 0
	return strcmp(token.text, text) == 0


int cpp_token_is_ident(cpp_token* token, char* text):
	if (token == 0):
		return 0
	return (token.kind == cpp_token_ident()) & (strcmp(token.text, text) == 0)


int cpp_token_is_punct(cpp_token* token, char* text):
	if (token == 0):
		return 0
	return (token.kind == cpp_token_punct()) & (strcmp(token.text, text) == 0)


int cpp_token_list_length(cpp_token* token):
	int count = 0
	while (token != 0):
		if (token.kind == cpp_token_eof()):
			return count
		count = count + 1
		token = token.next
	return count
