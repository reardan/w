import lib.lib
import lib.utf8

int ast_template_order
int ast_template_mark(int n):
	ast_template_order = ast_template_order * 10 + n
	return n

int main():
	int n = 42
	char* name = c"world"
	string inner = s"text"
	if (strcmp(cstr(f"hello {name}: {n}"), c"hello world: 42") != 0): return 1
	if (f"{inner}" != s"text"): return 2
	if (f"outer {f"inner {n}"}" != s"outer inner 42"): return 3
	if (f"{{x}}={n} {{}}" != s"{x}=42 {}"): return 4
	if (f"" != s""): return 5
	if (f"plain" != s"plain"): return 6
	if (f"{ast_template_mark(1)}{ast_template_mark(2)}" != s"12"): return 7
	if (ast_template_order != 12): return 8
	if (f"{c"inline"}/{s"wide"}" != s"inline/wide"): return 9
	if (f"{-7}/{true}/{'A'}" != s"-7/1/65"): return 10
	if (f"{n + 1}/{n << 1}" != s"43/84"): return 11
	map[char*, int] counts = new map[char*, int]
	counts[c"key"] = 9
	if (f"k={counts[c"key"]}" != s"k=9"): return 12
	if (f"{1.5}" != s"1.5"): return 13
	string escaped = f"a\0b\n\t\r\x41\u00e9\"\\"
	if (escaped.length != 11): return 14
	if (escaped.data[0] != 'a' || escaped.data[1] != 0 || escaped.data[2] != 'b'): return 15
	if (escaped.data[3] != 10 || escaped.data[4] != 9 || escaped.data[5] != 13): return 16
	if (escaped.data[6] != 'A' || escaped.data[9] != '"' || escaped.data[10] != 92): return 17
	if (f"{n:04d}" != s"0042"): return 18
	if (f"{n:x}/{n:X}/{n:o}/{n:b}/{65:c}" != s"2a/2A/52/101010/A"): return 19
	if (f"[{name:*>8s}]/[{inner:^8}]" != s"[***world]/[  text  ]"): return 20
	if (f"{-7:04d}" != s"-007"): return 21
	if (f"{1.5:.2f}/{1.5:8.1}/{1.5:<6.0}" != s"1.50/     1.5/2     "): return 22
	if (f"{n:}" != s"42"): return 23
	if (f"outer {f"{n:04}"} {n:x}" != s"outer 0042 2a"): return 24
	ast_template_order = 0
	if (f"{ast_template_mark(1):02}/{ast_template_mark(2):02}" != s"01/02"): return 25
	if (ast_template_order != 12): return 26
	return 0
