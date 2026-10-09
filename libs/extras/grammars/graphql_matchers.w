/* Generated lexer matchers from antlr_to_pg -- do not edit. */

int pg_lexer_matcher_g_graphql_BLOCK_STRING(char* input, int index):
	int _start = index
	int _ok = 1
	int _best0 = -1
	int _as0 = index
	index = _as0
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '"') | (input[index + 1] != '"') | (input[index + 2] != '"')):
			_ok = 0
		else:
			index = index + 3
	if (_ok):
		while (_ok):
			int _s2 = index
			if (_ok):
				if (input[index] == 0):
					_ok = 0
				else:
					index = index + 1
			if (_ok == 0):
				index = _s2
				_ok = 1
				break
			if (index == _s2):
				break
	if (_ok):
		if ((input[index + 0] != '"') | (input[index + 1] != '"') | (input[index + 2] != '"')):
			_ok = 0
		else:
			index = index + 3
	if (_ok):
		if ((index - _as0) > _best0):
			_best0 = index - _as0
	if (_best0 < 0):
		index = _as0
		_ok = 0
	else:
		index = _as0 + _best0
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_g_graphql_frag_HEX(char* input, int index):
	int _start = index
	int _ok = 1
	int _best5 = -1
	int _as5 = index
	index = _as5
	_ok = 1
	if (_ok):
		if ((((input[index] >= '0') & (input[index] <= '9') | (input[index] >= 'a') & (input[index] <= 'f') | (input[index] >= 'A') & (input[index] <= 'F'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as5) > _best5):
			_best5 = index - _as5
	if (_best5 < 0):
		index = _as5
		_ok = 0
	else:
		index = _as5 + _best5
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_UNICODE(char* input, int index):
	int _start = index
	int _ok = 1
	int _best7 = -1
	int _as7 = index
	index = _as7
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 'u')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		int _n9 = pg_g_graphql_frag_HEX(input, index)
		if (_n9 < 0):
			_ok = 0
		else:
			index = index + _n9
	if (_ok):
		int _n10 = pg_g_graphql_frag_HEX(input, index)
		if (_n10 < 0):
			_ok = 0
		else:
			index = index + _n10
	if (_ok):
		int _n11 = pg_g_graphql_frag_HEX(input, index)
		if (_n11 < 0):
			_ok = 0
		else:
			index = index + _n11
	if (_ok):
		int _n12 = pg_g_graphql_frag_HEX(input, index)
		if (_n12 < 0):
			_ok = 0
		else:
			index = index + _n12
	if (_ok):
		if ((index - _as7) > _best7):
			_best7 = index - _as7
	if (_best7 < 0):
		index = _as7
		_ok = 0
	else:
		index = _as7 + _best7
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_ESC(char* input, int index):
	int _start = index
	int _ok = 1
	int _best13 = -1
	int _as13 = index
	index = _as13
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 92)):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		int _best16 = -1
		int _as16 = index
		index = _as16
		_ok = 1
		if (_ok):
			if ((((input[index] == '"') | (input[index] == 92) | (input[index] == '/') | (input[index] == 'b') | (input[index] == 'f') | (input[index] == 'n') | (input[index] == 'r') | (input[index] == 't'))) == 0):
				_ok = 0
			else:
				index = index + 1
		if (_ok):
			if ((index - _as16) > _best16):
				_best16 = index - _as16
		index = _as16
		_ok = 1
		if (_ok):
			int _n18 = pg_g_graphql_frag_UNICODE(input, index)
			if (_n18 < 0):
				_ok = 0
			else:
				index = index + _n18
		if (_ok):
			if ((index - _as16) > _best16):
				_best16 = index - _as16
		if (_best16 < 0):
			index = _as16
			_ok = 0
		else:
			index = _as16 + _best16
			_ok = 1
	if (_ok):
		if ((index - _as13) > _best13):
			_best13 = index - _as13
	if (_best13 < 0):
		index = _as13
		_ok = 0
	else:
		index = _as13 + _best13
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_CHARACTER(char* input, int index):
	int _start = index
	int _ok = 1
	int _best19 = -1
	int _as19 = index
	index = _as19
	_ok = 1
	if (_ok):
		int _best21 = -1
		int _as21 = index
		index = _as21
		_ok = 1
		if (_ok):
			int _n22 = pg_g_graphql_frag_ESC(input, index)
			if (_n22 < 0):
				_ok = 0
			else:
				index = index + _n22
		if (_ok):
			if ((index - _as21) > _best21):
				_best21 = index - _as21
		index = _as21
		_ok = 1
		if (_ok):
			if ((((((input[index] == '"') | (input[index] == 92)) == 0) & (input[index] != 0))) == 0):
				_ok = 0
			else:
				index = index + 1
		if (_ok):
			if ((index - _as21) > _best21):
				_best21 = index - _as21
		if (_best21 < 0):
			index = _as21
			_ok = 0
		else:
			index = _as21 + _best21
			_ok = 1
	if (_ok):
		if ((index - _as19) > _best19):
			_best19 = index - _as19
	if (_best19 < 0):
		index = _as19
		_ok = 0
	else:
		index = _as19 + _best19
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_STRING(char* input, int index):
	int _start = index
	int _ok = 1
	int _best24 = -1
	int _as24 = index
	index = _as24
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '"')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		while (_ok):
			int _s26 = index
			if (_ok):
				int _n27 = pg_g_graphql_frag_CHARACTER(input, index)
				if (_n27 < 0):
					_ok = 0
				else:
					index = index + _n27
			if (_ok == 0):
				index = _s26
				_ok = 1
				break
			if (index == _s26):
				break
	if (_ok):
		if ((input[index + 0] != '"')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as24) > _best24):
			_best24 = index - _as24
	if (_best24 < 0):
		index = _as24
		_ok = 0
	else:
		index = _as24 + _best24
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_lexer_matcher_g_graphql_ID(char* input, int index):
	int _start = index
	int _ok = 1
	int _best29 = -1
	int _as29 = index
	index = _as29
	_ok = 1
	if (_ok):
		int _n30 = pg_g_graphql_frag_STRING(input, index)
		if (_n30 < 0):
			_ok = 0
		else:
			index = index + _n30
	if (_ok):
		if ((index - _as29) > _best29):
			_best29 = index - _as29
	if (_best29 < 0):
		index = _as29
		_ok = 0
	else:
		index = _as29 + _best29
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_g_graphql_frag_NEGATIVE_SIGN(char* input, int index):
	int _start = index
	int _ok = 1
	int _best31 = -1
	int _as31 = index
	index = _as31
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '-')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as31) > _best31):
			_best31 = index - _as31
	if (_best31 < 0):
		index = _as31
		_ok = 0
	else:
		index = _as31 + _best31
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_NONZERO_DIGIT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best33 = -1
	int _as33 = index
	index = _as33
	_ok = 1
	if (_ok):
		if ((((input[index] >= '1') & (input[index] <= '9'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as33) > _best33):
			_best33 = index - _as33
	if (_best33 < 0):
		index = _as33
		_ok = 0
	else:
		index = _as33 + _best33
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_DIGIT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best35 = -1
	int _as35 = index
	index = _as35
	_ok = 1
	if (_ok):
		if ((((input[index] >= '0') & (input[index] <= '9'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as35) > _best35):
			_best35 = index - _as35
	if (_best35 < 0):
		index = _as35
		_ok = 0
	else:
		index = _as35 + _best35
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_INT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best37 = -1
	int _as37 = index
	index = _as37
	_ok = 1
	if (_ok):
		int _s38 = index
		int _ok_save38 = _ok
		if (_ok):
			int _n39 = pg_g_graphql_frag_NEGATIVE_SIGN(input, index)
			if (_n39 < 0):
				_ok = 0
			else:
				index = index + _n39
		if (_ok == 0):
			index = _s38
			_ok = _ok_save38
	if (_ok):
		if ((input[index + 0] != '0')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as37) > _best37):
			_best37 = index - _as37
	index = _as37
	_ok = 1
	if (_ok):
		int _s41 = index
		int _ok_save41 = _ok
		if (_ok):
			int _n42 = pg_g_graphql_frag_NEGATIVE_SIGN(input, index)
			if (_n42 < 0):
				_ok = 0
			else:
				index = index + _n42
		if (_ok == 0):
			index = _s41
			_ok = _ok_save41
	if (_ok):
		int _n43 = pg_g_graphql_frag_NONZERO_DIGIT(input, index)
		if (_n43 < 0):
			_ok = 0
		else:
			index = index + _n43
	if (_ok):
		while (_ok):
			int _s44 = index
			if (_ok):
				int _n45 = pg_g_graphql_frag_DIGIT(input, index)
				if (_n45 < 0):
					_ok = 0
				else:
					index = index + _n45
			if (_ok == 0):
				index = _s44
				_ok = 1
				break
			if (index == _s44):
				break
	if (_ok):
		if ((index - _as37) > _best37):
			_best37 = index - _as37
	if (_best37 < 0):
		index = _as37
		_ok = 0
	else:
		index = _as37 + _best37
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_FRACTIONAL_PART(char* input, int index):
	int _start = index
	int _ok = 1
	int _best46 = -1
	int _as46 = index
	index = _as46
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '.')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if (_ok):
			int _n49 = pg_g_graphql_frag_DIGIT(input, index)
			if (_n49 < 0):
				_ok = 0
			else:
				index = index + _n49
		while (_ok):
			int _s48 = index
			if (_ok):
				int _n50 = pg_g_graphql_frag_DIGIT(input, index)
				if (_n50 < 0):
					_ok = 0
				else:
					index = index + _n50
			if (_ok == 0):
				index = _s48
				_ok = 1
				break
			if (index == _s48):
				break
	if (_ok):
		if ((index - _as46) > _best46):
			_best46 = index - _as46
	if (_best46 < 0):
		index = _as46
		_ok = 0
	else:
		index = _as46 + _best46
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_EXPONENT_INDICATOR(char* input, int index):
	int _start = index
	int _ok = 1
	int _best51 = -1
	int _as51 = index
	index = _as51
	_ok = 1
	if (_ok):
		if ((((input[index] == 'e') | (input[index] == 'E'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as51) > _best51):
			_best51 = index - _as51
	if (_best51 < 0):
		index = _as51
		_ok = 0
	else:
		index = _as51 + _best51
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_SIGN(char* input, int index):
	int _start = index
	int _ok = 1
	int _best53 = -1
	int _as53 = index
	index = _as53
	_ok = 1
	if (_ok):
		if ((((input[index] == '+') | (input[index] == '-'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as53) > _best53):
			_best53 = index - _as53
	if (_best53 < 0):
		index = _as53
		_ok = 0
	else:
		index = _as53 + _best53
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_EXPONENTIAL_PART(char* input, int index):
	int _start = index
	int _ok = 1
	int _best55 = -1
	int _as55 = index
	index = _as55
	_ok = 1
	if (_ok):
		int _n56 = pg_g_graphql_frag_EXPONENT_INDICATOR(input, index)
		if (_n56 < 0):
			_ok = 0
		else:
			index = index + _n56
	if (_ok):
		int _s57 = index
		int _ok_save57 = _ok
		if (_ok):
			int _n58 = pg_g_graphql_frag_SIGN(input, index)
			if (_n58 < 0):
				_ok = 0
			else:
				index = index + _n58
		if (_ok == 0):
			index = _s57
			_ok = _ok_save57
	if (_ok):
		if (_ok):
			int _n60 = pg_g_graphql_frag_DIGIT(input, index)
			if (_n60 < 0):
				_ok = 0
			else:
				index = index + _n60
		while (_ok):
			int _s59 = index
			if (_ok):
				int _n61 = pg_g_graphql_frag_DIGIT(input, index)
				if (_n61 < 0):
					_ok = 0
				else:
					index = index + _n61
			if (_ok == 0):
				index = _s59
				_ok = 1
				break
			if (index == _s59):
				break
	if (_ok):
		if ((index - _as55) > _best55):
			_best55 = index - _as55
	if (_best55 < 0):
		index = _as55
		_ok = 0
	else:
		index = _as55 + _best55
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_lexer_matcher_g_graphql_FLOAT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best62 = -1
	int _as62 = index
	index = _as62
	_ok = 1
	if (_ok):
		int _n63 = pg_g_graphql_frag_INT(input, index)
		if (_n63 < 0):
			_ok = 0
		else:
			index = index + _n63
	if (_ok):
		int _n64 = pg_g_graphql_frag_FRACTIONAL_PART(input, index)
		if (_n64 < 0):
			_ok = 0
		else:
			index = index + _n64
	if (_ok):
		if ((index - _as62) > _best62):
			_best62 = index - _as62
	index = _as62
	_ok = 1
	if (_ok):
		int _n65 = pg_g_graphql_frag_INT(input, index)
		if (_n65 < 0):
			_ok = 0
		else:
			index = index + _n65
	if (_ok):
		int _n66 = pg_g_graphql_frag_EXPONENTIAL_PART(input, index)
		if (_n66 < 0):
			_ok = 0
		else:
			index = index + _n66
	if (_ok):
		if ((index - _as62) > _best62):
			_best62 = index - _as62
	index = _as62
	_ok = 1
	if (_ok):
		int _n67 = pg_g_graphql_frag_INT(input, index)
		if (_n67 < 0):
			_ok = 0
		else:
			index = index + _n67
	if (_ok):
		int _n68 = pg_g_graphql_frag_FRACTIONAL_PART(input, index)
		if (_n68 < 0):
			_ok = 0
		else:
			index = index + _n68
	if (_ok):
		int _n69 = pg_g_graphql_frag_EXPONENTIAL_PART(input, index)
		if (_n69 < 0):
			_ok = 0
		else:
			index = index + _n69
	if (_ok):
		if ((index - _as62) > _best62):
			_best62 = index - _as62
	if (_best62 < 0):
		index = _as62
		_ok = 0
	else:
		index = _as62 + _best62
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_lexer_matcher_g_graphql_INT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best70 = -1
	int _as70 = index
	index = _as70
	_ok = 1
	if (_ok):
		int _s71 = index
		int _ok_save71 = _ok
		if (_ok):
			int _n72 = pg_g_graphql_frag_NEGATIVE_SIGN(input, index)
			if (_n72 < 0):
				_ok = 0
			else:
				index = index + _n72
		if (_ok == 0):
			index = _s71
			_ok = _ok_save71
	if (_ok):
		if ((input[index + 0] != '0')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as70) > _best70):
			_best70 = index - _as70
	index = _as70
	_ok = 1
	if (_ok):
		int _s74 = index
		int _ok_save74 = _ok
		if (_ok):
			int _n75 = pg_g_graphql_frag_NEGATIVE_SIGN(input, index)
			if (_n75 < 0):
				_ok = 0
			else:
				index = index + _n75
		if (_ok == 0):
			index = _s74
			_ok = _ok_save74
	if (_ok):
		int _n76 = pg_g_graphql_frag_NONZERO_DIGIT(input, index)
		if (_n76 < 0):
			_ok = 0
		else:
			index = index + _n76
	if (_ok):
		while (_ok):
			int _s77 = index
			if (_ok):
				int _n78 = pg_g_graphql_frag_DIGIT(input, index)
				if (_n78 < 0):
					_ok = 0
				else:
					index = index + _n78
			if (_ok == 0):
				index = _s77
				_ok = 1
				break
			if (index == _s77):
				break
	if (_ok):
		if ((index - _as70) > _best70):
			_best70 = index - _as70
	if (_best70 < 0):
		index = _as70
		_ok = 0
	else:
		index = _as70 + _best70
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_lexer_matcher_g_graphql_PUNCTUATOR(char* input, int index):
	int _start = index
	int _ok = 1
	int _best79 = -1
	int _as79 = index
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '!')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '$')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '(')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != ')')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '.') | (input[index + 1] != '.') | (input[index + 2] != '.')):
			_ok = 0
		else:
			index = index + 3
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != ':')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '=')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '@')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '[')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != ']')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '{')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '}')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	index = _as79
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '|')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as79) > _best79):
			_best79 = index - _as79
	if (_best79 < 0):
		index = _as79
		_ok = 0
	else:
		index = _as79 + _best79
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_g_graphql_frag_UTF8_BOM(char* input, int index):
	int _start = index
	int _ok = 1
	int _best93 = -1
	int _as93 = index
	index = _as93
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 'u') | (input[index + 1] != 'E') | (input[index + 2] != 'F') | (input[index + 3] != 'B') | (input[index + 4] != 'B') | (input[index + 5] != 'B') | (input[index + 6] != 'F')):
			_ok = 0
		else:
			index = index + 7
	if (_ok):
		if ((index - _as93) > _best93):
			_best93 = index - _as93
	if (_best93 < 0):
		index = _as93
		_ok = 0
	else:
		index = _as93 + _best93
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_UTF16_BOM(char* input, int index):
	int _start = index
	int _ok = 1
	int _best95 = -1
	int _as95 = index
	index = _as95
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 'u') | (input[index + 1] != 'F') | (input[index + 2] != 'E') | (input[index + 3] != 'F') | (input[index + 4] != 'F')):
			_ok = 0
		else:
			index = index + 5
	if (_ok):
		if ((index - _as95) > _best95):
			_best95 = index - _as95
	if (_best95 < 0):
		index = _as95
		_ok = 0
	else:
		index = _as95 + _best95
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_graphql_frag_UTF32_BOM(char* input, int index):
	int _start = index
	int _ok = 1
	int _best97 = -1
	int _as97 = index
	index = _as97
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 'u') | (input[index + 1] != '0') | (input[index + 2] != '0') | (input[index + 3] != '0') | (input[index + 4] != '0') | (input[index + 5] != 'F') | (input[index + 6] != 'E') | (input[index + 7] != 'F') | (input[index + 8] != 'F')):
			_ok = 0
		else:
			index = index + 9
	if (_ok):
		if ((index - _as97) > _best97):
			_best97 = index - _as97
	if (_best97 < 0):
		index = _as97
		_ok = 0
	else:
		index = _as97 + _best97
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_lexer_matcher_g_graphql_UNICODE_BOM(char* input, int index):
	int _start = index
	int _ok = 1
	int _best99 = -1
	int _as99 = index
	index = _as99
	_ok = 1
	if (_ok):
		int _best101 = -1
		int _as101 = index
		index = _as101
		_ok = 1
		if (_ok):
			int _n102 = pg_g_graphql_frag_UTF8_BOM(input, index)
			if (_n102 < 0):
				_ok = 0
			else:
				index = index + _n102
		if (_ok):
			if ((index - _as101) > _best101):
				_best101 = index - _as101
		index = _as101
		_ok = 1
		if (_ok):
			int _n103 = pg_g_graphql_frag_UTF16_BOM(input, index)
			if (_n103 < 0):
				_ok = 0
			else:
				index = index + _n103
		if (_ok):
			if ((index - _as101) > _best101):
				_best101 = index - _as101
		index = _as101
		_ok = 1
		if (_ok):
			int _n104 = pg_g_graphql_frag_UTF32_BOM(input, index)
			if (_n104 < 0):
				_ok = 0
			else:
				index = index + _n104
		if (_ok):
			if ((index - _as101) > _best101):
				_best101 = index - _as101
		if (_best101 < 0):
			index = _as101
			_ok = 0
		else:
			index = _as101 + _best101
			_ok = 1
	if (_ok):
		if ((index - _as99) > _best99):
			_best99 = index - _as99
	if (_best99 < 0):
		index = _as99
		_ok = 0
	else:
		index = _as99 + _best99
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start
