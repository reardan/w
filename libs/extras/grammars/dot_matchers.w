/* Generated lexer matchers from antlr_to_pg -- do not edit. */

int pg_g_dot_frag_LETTER(char* input, int index):
	int _start = index
	int _ok = 1
	int _best0 = -1
	int _as0 = index
	index = _as0
	_ok = 1
	if (_ok):
		if ((((input[index] >= 'a') & (input[index] <= 'z') | (input[index] == '_'))) == 0):
			_ok = 0
		else:
			index = index + 1
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
		return -1
	return index - _start

int pg_g_dot_frag_DIGIT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best2 = -1
	int _as2 = index
	index = _as2
	_ok = 1
	if (_ok):
		if ((((input[index] >= '0') & (input[index] <= '9'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as2) > _best2):
			_best2 = index - _as2
	if (_best2 < 0):
		index = _as2
		_ok = 0
	else:
		index = _as2 + _best2
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_lexer_matcher_g_dot_ID(char* input, int index):
	int _start = index
	int _ok = 1
	int _best4 = -1
	int _as4 = index
	index = _as4
	_ok = 1
	if (_ok):
		int _n5 = pg_g_dot_frag_LETTER(input, index)
		if (_n5 < 0):
			_ok = 0
		else:
			index = index + _n5
	if (_ok):
		while (_ok):
			int _s6 = index
			if (_ok):
				int _best8 = -1
				int _as8 = index
				index = _as8
				_ok = 1
				if (_ok):
					int _n9 = pg_g_dot_frag_LETTER(input, index)
					if (_n9 < 0):
						_ok = 0
					else:
						index = index + _n9
				if (_ok):
					if ((index - _as8) > _best8):
						_best8 = index - _as8
				index = _as8
				_ok = 1
				if (_ok):
					int _n10 = pg_g_dot_frag_DIGIT(input, index)
					if (_n10 < 0):
						_ok = 0
					else:
						index = index + _n10
				if (_ok):
					if ((index - _as8) > _best8):
						_best8 = index - _as8
				if (_best8 < 0):
					index = _as8
					_ok = 0
				else:
					index = _as8 + _best8
					_ok = 1
			if (_ok == 0):
				index = _s6
				_ok = 1
				break
			if (index == _s6):
				break
	if (_ok):
		if ((index - _as4) > _best4):
			_best4 = index - _as4
	if (_best4 < 0):
		index = _as4
		_ok = 0
	else:
		index = _as4 + _best4
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_g_dot_frag_TAG(char* input, int index):
	int _start = index
	int _ok = 1
	int _best11 = -1
	int _as11 = index
	index = _as11
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '<')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		while (_ok):
			int _s13 = index
			if (_ok):
				if (input[index] == 0):
					_ok = 0
				else:
					index = index + 1
			if (_ok == 0):
				index = _s13
				_ok = 1
				break
			if (index == _s13):
				break
	if (_ok):
		if ((input[index + 0] != '>')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as11) > _best11):
			_best11 = index - _as11
	if (_best11 < 0):
		index = _as11
		_ok = 0
	else:
		index = _as11 + _best11
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_lexer_matcher_g_dot_HTML_STRING(char* input, int index):
	int _start = index
	int _ok = 1
	int _best16 = -1
	int _as16 = index
	index = _as16
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '<')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		while (_ok):
			int _s18 = index
			if (_ok):
				int _best20 = -1
				int _as20 = index
				index = _as20
				_ok = 1
				if (_ok):
					int _n21 = pg_g_dot_frag_TAG(input, index)
					if (_n21 < 0):
						_ok = 0
					else:
						index = index + _n21
				if (_ok):
					if ((index - _as20) > _best20):
						_best20 = index - _as20
				index = _as20
				_ok = 1
				if (_ok):
					if ((((((input[index] == '<') | (input[index] == '>')) == 0) & (input[index] != 0))) == 0):
						_ok = 0
					else:
						index = index + 1
				if (_ok):
					if ((index - _as20) > _best20):
						_best20 = index - _as20
				if (_best20 < 0):
					index = _as20
					_ok = 0
				else:
					index = _as20 + _best20
					_ok = 1
			if (_ok == 0):
				index = _s18
				_ok = 1
				break
			if (index == _s18):
				break
	if (_ok):
		if ((input[index + 0] != '>')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as16) > _best16):
			_best16 = index - _as16
	if (_best16 < 0):
		index = _as16
		_ok = 0
	else:
		index = _as16 + _best16
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start
