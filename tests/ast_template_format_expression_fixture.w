int ast_format_order
int ast_format_mark(int n):
	ast_format_order = ast_format_order * 10 + n
	return n

int main():
	string padded = f"{ast_format_mark(1):04d}/{ast_format_mark(2):#>3}"
	if (padded != s"0001/##2" || ast_format_order != 12): return 1
	string nested = f"[{f"{15:04x}":*>6}]"
	if (nested != s"[**000f]"): return 2
	string empty_spec = f"{3:}/{4:02}/{5}"
	if (empty_spec != s"3/04/5"): return 3
	string branch = f"{true ? c"yes" : c"no":>5}"
	if (branch != s"  yes"): return 4
	string grouped = f"{(false ? 2 : 3):04x}"
	if (grouped != s"0003"): return 5
	list[int] values = list[int]{4, 5}
	string indexed = f"{values[1]:03}"
	if (indexed != s"005"): return 6
	string sliced = f"{s"abcd"[1:3]:>4}"
	if (sliced != s"  bc"): return 7
	var dynamic = 7
	string text = f"{dynamic:*>3s}"
	if (text != s"**7"): return 8
	float32 real = 1.5
	string decimal = f"{real:06.2f}"
	if (decimal != s"001.50"): return 9
	return 0
