/* Generated lexer matchers from antlr_to_pg -- do not edit. */

int pg_g_abnf_frag_BIT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best0 = -1
	int _as0 = index
	index = _as0
	_ok = 1
	if (_ok):
		if ((((input[index] >= '0') & (input[index] <= '1'))) == 0):
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

int pg_g_abnf_frag_BinaryValue(char* input, int index):
	int _start = index
	int _ok = 1
	int _best2 = -1
	int _as2 = index
	index = _as2
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 'b')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if (_ok):
			int _n5 = pg_g_abnf_frag_BIT(input, index)
			if (_n5 < 0):
				_ok = 0
			else:
				index = index + _n5
		while (_ok):
			int _s4 = index
			if (_ok):
				int _n6 = pg_g_abnf_frag_BIT(input, index)
				if (_n6 < 0):
					_ok = 0
				else:
					index = index + _n6
			if (_ok == 0):
				index = _s4
				_ok = 1
				break
			if (index == _s4):
				break
	if (_ok):
		int _s7 = index
		int _ok_save7 = _ok
		if (_ok):
			int _best9 = -1
			int _as9 = index
			index = _as9
			_ok = 1
			if (_ok):
				if (_ok):
					int _best12 = -1
					int _as12 = index
					index = _as12
					_ok = 1
					if (_ok):
						if ((input[index + 0] != '.')):
							_ok = 0
						else:
							index = index + 1
					if (_ok):
						if (_ok):
							int _n15 = pg_g_abnf_frag_BIT(input, index)
							if (_n15 < 0):
								_ok = 0
							else:
								index = index + _n15
						while (_ok):
							int _s14 = index
							if (_ok):
								int _n16 = pg_g_abnf_frag_BIT(input, index)
								if (_n16 < 0):
									_ok = 0
								else:
									index = index + _n16
							if (_ok == 0):
								index = _s14
								_ok = 1
								break
							if (index == _s14):
								break
					if (_ok):
						if ((index - _as12) > _best12):
							_best12 = index - _as12
					if (_best12 < 0):
						index = _as12
						_ok = 0
					else:
						index = _as12 + _best12
						_ok = 1
				while (_ok):
					int _s10 = index
					if (_ok):
						int _best18 = -1
						int _as18 = index
						index = _as18
						_ok = 1
						if (_ok):
							if ((input[index + 0] != '.')):
								_ok = 0
							else:
								index = index + 1
						if (_ok):
							if (_ok):
								int _n21 = pg_g_abnf_frag_BIT(input, index)
								if (_n21 < 0):
									_ok = 0
								else:
									index = index + _n21
							while (_ok):
								int _s20 = index
								if (_ok):
									int _n22 = pg_g_abnf_frag_BIT(input, index)
									if (_n22 < 0):
										_ok = 0
									else:
										index = index + _n22
								if (_ok == 0):
									index = _s20
									_ok = 1
									break
								if (index == _s20):
									break
						if (_ok):
							if ((index - _as18) > _best18):
								_best18 = index - _as18
						if (_best18 < 0):
							index = _as18
							_ok = 0
						else:
							index = _as18 + _best18
							_ok = 1
					if (_ok == 0):
						index = _s10
						_ok = 1
						break
					if (index == _s10):
						break
			if (_ok):
				if ((index - _as9) > _best9):
					_best9 = index - _as9
			index = _as9
			_ok = 1
			if (_ok):
				if ((input[index + 0] != '-')):
					_ok = 0
				else:
					index = index + 1
			if (_ok):
				if (_ok):
					int _n25 = pg_g_abnf_frag_BIT(input, index)
					if (_n25 < 0):
						_ok = 0
					else:
						index = index + _n25
				while (_ok):
					int _s24 = index
					if (_ok):
						int _n26 = pg_g_abnf_frag_BIT(input, index)
						if (_n26 < 0):
							_ok = 0
						else:
							index = index + _n26
					if (_ok == 0):
						index = _s24
						_ok = 1
						break
					if (index == _s24):
						break
			if (_ok):
				if ((index - _as9) > _best9):
					_best9 = index - _as9
			if (_best9 < 0):
				index = _as9
				_ok = 0
			else:
				index = _as9 + _best9
				_ok = 1
		if (_ok == 0):
			index = _s7
			_ok = _ok_save7
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

int pg_g_abnf_frag_DIGIT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best27 = -1
	int _as27 = index
	index = _as27
	_ok = 1
	if (_ok):
		if ((((input[index] >= '0') & (input[index] <= '9'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as27) > _best27):
			_best27 = index - _as27
	if (_best27 < 0):
		index = _as27
		_ok = 0
	else:
		index = _as27 + _best27
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_abnf_frag_DecimalValue(char* input, int index):
	int _start = index
	int _ok = 1
	int _best29 = -1
	int _as29 = index
	index = _as29
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 'd')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if (_ok):
			int _n32 = pg_g_abnf_frag_DIGIT(input, index)
			if (_n32 < 0):
				_ok = 0
			else:
				index = index + _n32
		while (_ok):
			int _s31 = index
			if (_ok):
				int _n33 = pg_g_abnf_frag_DIGIT(input, index)
				if (_n33 < 0):
					_ok = 0
				else:
					index = index + _n33
			if (_ok == 0):
				index = _s31
				_ok = 1
				break
			if (index == _s31):
				break
	if (_ok):
		int _s34 = index
		int _ok_save34 = _ok
		if (_ok):
			int _best36 = -1
			int _as36 = index
			index = _as36
			_ok = 1
			if (_ok):
				if (_ok):
					int _best39 = -1
					int _as39 = index
					index = _as39
					_ok = 1
					if (_ok):
						if ((input[index + 0] != '.')):
							_ok = 0
						else:
							index = index + 1
					if (_ok):
						if (_ok):
							int _n42 = pg_g_abnf_frag_DIGIT(input, index)
							if (_n42 < 0):
								_ok = 0
							else:
								index = index + _n42
						while (_ok):
							int _s41 = index
							if (_ok):
								int _n43 = pg_g_abnf_frag_DIGIT(input, index)
								if (_n43 < 0):
									_ok = 0
								else:
									index = index + _n43
							if (_ok == 0):
								index = _s41
								_ok = 1
								break
							if (index == _s41):
								break
					if (_ok):
						if ((index - _as39) > _best39):
							_best39 = index - _as39
					if (_best39 < 0):
						index = _as39
						_ok = 0
					else:
						index = _as39 + _best39
						_ok = 1
				while (_ok):
					int _s37 = index
					if (_ok):
						int _best45 = -1
						int _as45 = index
						index = _as45
						_ok = 1
						if (_ok):
							if ((input[index + 0] != '.')):
								_ok = 0
							else:
								index = index + 1
						if (_ok):
							if (_ok):
								int _n48 = pg_g_abnf_frag_DIGIT(input, index)
								if (_n48 < 0):
									_ok = 0
								else:
									index = index + _n48
							while (_ok):
								int _s47 = index
								if (_ok):
									int _n49 = pg_g_abnf_frag_DIGIT(input, index)
									if (_n49 < 0):
										_ok = 0
									else:
										index = index + _n49
								if (_ok == 0):
									index = _s47
									_ok = 1
									break
								if (index == _s47):
									break
						if (_ok):
							if ((index - _as45) > _best45):
								_best45 = index - _as45
						if (_best45 < 0):
							index = _as45
							_ok = 0
						else:
							index = _as45 + _best45
							_ok = 1
					if (_ok == 0):
						index = _s37
						_ok = 1
						break
					if (index == _s37):
						break
			if (_ok):
				if ((index - _as36) > _best36):
					_best36 = index - _as36
			index = _as36
			_ok = 1
			if (_ok):
				if ((input[index + 0] != '-')):
					_ok = 0
				else:
					index = index + 1
			if (_ok):
				if (_ok):
					int _n52 = pg_g_abnf_frag_DIGIT(input, index)
					if (_n52 < 0):
						_ok = 0
					else:
						index = index + _n52
				while (_ok):
					int _s51 = index
					if (_ok):
						int _n53 = pg_g_abnf_frag_DIGIT(input, index)
						if (_n53 < 0):
							_ok = 0
						else:
							index = index + _n53
					if (_ok == 0):
						index = _s51
						_ok = 1
						break
					if (index == _s51):
						break
			if (_ok):
				if ((index - _as36) > _best36):
					_best36 = index - _as36
			if (_best36 < 0):
				index = _as36
				_ok = 0
			else:
				index = _as36 + _best36
				_ok = 1
		if (_ok == 0):
			index = _s34
			_ok = _ok_save34
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
		return -1
	return index - _start

int pg_g_abnf_frag_HEX_DIGIT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best54 = -1
	int _as54 = index
	index = _as54
	_ok = 1
	if (_ok):
		if ((((input[index] >= '0') & (input[index] <= '9'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as54) > _best54):
			_best54 = index - _as54
	index = _as54
	_ok = 1
	if (_ok):
		if ((((input[index] >= 'a') & (input[index] <= 'f'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as54) > _best54):
			_best54 = index - _as54
	index = _as54
	_ok = 1
	if (_ok):
		if ((((input[index] >= 'A') & (input[index] <= 'F'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as54) > _best54):
			_best54 = index - _as54
	if (_best54 < 0):
		index = _as54
		_ok = 0
	else:
		index = _as54 + _best54
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_g_abnf_frag_HexValue(char* input, int index):
	int _start = index
	int _ok = 1
	int _best58 = -1
	int _as58 = index
	index = _as58
	_ok = 1
	if (_ok):
		if ((input[index + 0] != 'x')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if (_ok):
			int _n61 = pg_g_abnf_frag_HEX_DIGIT(input, index)
			if (_n61 < 0):
				_ok = 0
			else:
				index = index + _n61
		while (_ok):
			int _s60 = index
			if (_ok):
				int _n62 = pg_g_abnf_frag_HEX_DIGIT(input, index)
				if (_n62 < 0):
					_ok = 0
				else:
					index = index + _n62
			if (_ok == 0):
				index = _s60
				_ok = 1
				break
			if (index == _s60):
				break
	if (_ok):
		int _s63 = index
		int _ok_save63 = _ok
		if (_ok):
			int _best65 = -1
			int _as65 = index
			index = _as65
			_ok = 1
			if (_ok):
				if (_ok):
					int _best68 = -1
					int _as68 = index
					index = _as68
					_ok = 1
					if (_ok):
						if ((input[index + 0] != '.')):
							_ok = 0
						else:
							index = index + 1
					if (_ok):
						if (_ok):
							int _n71 = pg_g_abnf_frag_HEX_DIGIT(input, index)
							if (_n71 < 0):
								_ok = 0
							else:
								index = index + _n71
						while (_ok):
							int _s70 = index
							if (_ok):
								int _n72 = pg_g_abnf_frag_HEX_DIGIT(input, index)
								if (_n72 < 0):
									_ok = 0
								else:
									index = index + _n72
							if (_ok == 0):
								index = _s70
								_ok = 1
								break
							if (index == _s70):
								break
					if (_ok):
						if ((index - _as68) > _best68):
							_best68 = index - _as68
					if (_best68 < 0):
						index = _as68
						_ok = 0
					else:
						index = _as68 + _best68
						_ok = 1
				while (_ok):
					int _s66 = index
					if (_ok):
						int _best74 = -1
						int _as74 = index
						index = _as74
						_ok = 1
						if (_ok):
							if ((input[index + 0] != '.')):
								_ok = 0
							else:
								index = index + 1
						if (_ok):
							if (_ok):
								int _n77 = pg_g_abnf_frag_HEX_DIGIT(input, index)
								if (_n77 < 0):
									_ok = 0
								else:
									index = index + _n77
							while (_ok):
								int _s76 = index
								if (_ok):
									int _n78 = pg_g_abnf_frag_HEX_DIGIT(input, index)
									if (_n78 < 0):
										_ok = 0
									else:
										index = index + _n78
								if (_ok == 0):
									index = _s76
									_ok = 1
									break
								if (index == _s76):
									break
						if (_ok):
							if ((index - _as74) > _best74):
								_best74 = index - _as74
						if (_best74 < 0):
							index = _as74
							_ok = 0
						else:
							index = _as74 + _best74
							_ok = 1
					if (_ok == 0):
						index = _s66
						_ok = 1
						break
					if (index == _s66):
						break
			if (_ok):
				if ((index - _as65) > _best65):
					_best65 = index - _as65
			index = _as65
			_ok = 1
			if (_ok):
				if ((input[index + 0] != '-')):
					_ok = 0
				else:
					index = index + 1
			if (_ok):
				if (_ok):
					int _n81 = pg_g_abnf_frag_HEX_DIGIT(input, index)
					if (_n81 < 0):
						_ok = 0
					else:
						index = index + _n81
				while (_ok):
					int _s80 = index
					if (_ok):
						int _n82 = pg_g_abnf_frag_HEX_DIGIT(input, index)
						if (_n82 < 0):
							_ok = 0
						else:
							index = index + _n82
					if (_ok == 0):
						index = _s80
						_ok = 1
						break
					if (index == _s80):
						break
			if (_ok):
				if ((index - _as65) > _best65):
					_best65 = index - _as65
			if (_best65 < 0):
				index = _as65
				_ok = 0
			else:
				index = _as65 + _best65
				_ok = 1
		if (_ok == 0):
			index = _s63
			_ok = _ok_save63
	if (_ok):
		if ((index - _as58) > _best58):
			_best58 = index - _as58
	if (_best58 < 0):
		index = _as58
		_ok = 0
	else:
		index = _as58 + _best58
		_ok = 1
	if (_ok == 0):
		return -1
	return index - _start

int pg_lexer_matcher_g_abnf_NumberValue(char* input, int index):
	int _start = index
	int _ok = 1
	int _best83 = -1
	int _as83 = index
	index = _as83
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '%')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		int _best86 = -1
		int _as86 = index
		index = _as86
		_ok = 1
		if (_ok):
			int _n87 = pg_g_abnf_frag_BinaryValue(input, index)
			if (_n87 < 0):
				_ok = 0
			else:
				index = index + _n87
		if (_ok):
			if ((index - _as86) > _best86):
				_best86 = index - _as86
		index = _as86
		_ok = 1
		if (_ok):
			int _n88 = pg_g_abnf_frag_DecimalValue(input, index)
			if (_n88 < 0):
				_ok = 0
			else:
				index = index + _n88
		if (_ok):
			if ((index - _as86) > _best86):
				_best86 = index - _as86
		index = _as86
		_ok = 1
		if (_ok):
			int _n89 = pg_g_abnf_frag_HexValue(input, index)
			if (_n89 < 0):
				_ok = 0
			else:
				index = index + _n89
		if (_ok):
			if ((index - _as86) > _best86):
				_best86 = index - _as86
		if (_best86 < 0):
			index = _as86
			_ok = 0
		else:
			index = _as86 + _best86
			_ok = 1
	if (_ok):
		if ((index - _as83) > _best83):
			_best83 = index - _as83
	if (_best83 < 0):
		index = _as83
		_ok = 0
	else:
		index = _as83 + _best83
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_lexer_matcher_g_abnf_ProseValue(char* input, int index):
	int _start = index
	int _ok = 1
	int _best90 = -1
	int _as90 = index
	index = _as90
	_ok = 1
	if (_ok):
		if ((input[index + 0] != '<')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		while (_ok):
			int _s92 = index
			if (_ok):
				if ((((((input[index] == '>')) == 0) & (input[index] != 0))) == 0):
					_ok = 0
				else:
					index = index + 1
			if (_ok == 0):
				index = _s92
				_ok = 1
				break
			if (index == _s92):
				break
	if (_ok):
		if ((input[index + 0] != '>')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as90) > _best90):
			_best90 = index - _as90
	if (_best90 < 0):
		index = _as90
		_ok = 0
	else:
		index = _as90 + _best90
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_g_abnf_frag_LETTER(char* input, int index):
	int _start = index
	int _ok = 1
	int _best95 = -1
	int _as95 = index
	index = _as95
	_ok = 1
	if (_ok):
		if ((((input[index] >= 'a') & (input[index] <= 'z'))) == 0):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as95) > _best95):
			_best95 = index - _as95
	index = _as95
	_ok = 1
	if (_ok):
		if ((((input[index] >= 'A') & (input[index] <= 'Z'))) == 0):
			_ok = 0
		else:
			index = index + 1
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

int pg_lexer_matcher_g_abnf_ID(char* input, int index):
	int _start = index
	int _ok = 1
	int _best98 = -1
	int _as98 = index
	index = _as98
	_ok = 1
	if (_ok):
		int _n99 = pg_g_abnf_frag_LETTER(input, index)
		if (_n99 < 0):
			_ok = 0
		else:
			index = index + _n99
	if (_ok):
		while (_ok):
			int _s100 = index
			if (_ok):
				int _best102 = -1
				int _as102 = index
				index = _as102
				_ok = 1
				if (_ok):
					int _n103 = pg_g_abnf_frag_LETTER(input, index)
					if (_n103 < 0):
						_ok = 0
					else:
						index = index + _n103
				if (_ok):
					if ((index - _as102) > _best102):
						_best102 = index - _as102
				index = _as102
				_ok = 1
				if (_ok):
					int _n104 = pg_g_abnf_frag_DIGIT(input, index)
					if (_n104 < 0):
						_ok = 0
					else:
						index = index + _n104
				if (_ok):
					if ((index - _as102) > _best102):
						_best102 = index - _as102
				index = _as102
				_ok = 1
				if (_ok):
					if ((input[index + 0] != '-')):
						_ok = 0
					else:
						index = index + 1
				if (_ok):
					if ((index - _as102) > _best102):
						_best102 = index - _as102
				if (_best102 < 0):
					index = _as102
					_ok = 0
				else:
					index = _as102 + _best102
					_ok = 1
			if (_ok == 0):
				index = _s100
				_ok = 1
				break
			if (index == _s100):
				break
	if (_ok):
		if ((index - _as98) > _best98):
			_best98 = index - _as98
	if (_best98 < 0):
		index = _as98
		_ok = 0
	else:
		index = _as98 + _best98
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_lexer_matcher_g_abnf_COMMENT(char* input, int index):
	int _start = index
	int _ok = 1
	int _best106 = -1
	int _as106 = index
	index = _as106
	_ok = 1
	if (_ok):
		if ((input[index + 0] != ';')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		while (_ok):
			int _s108 = index
			if (_ok):
				if ((((((input[index] == 10) | (input[index] == 13)) == 0) & (input[index] != 0))) == 0):
					_ok = 0
				else:
					index = index + 1
			if (_ok == 0):
				index = _s108
				_ok = 1
				break
			if (index == _s108):
				break
	if (_ok):
		int _s110 = index
		int _ok_save110 = _ok
		if (_ok):
			if ((input[index + 0] != 13)):
				_ok = 0
			else:
				index = index + 1
		if (_ok == 0):
			index = _s110
			_ok = _ok_save110
	if (_ok):
		if ((input[index + 0] != 10)):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as106) > _best106):
			_best106 = index - _as106
	if (_best106 < 0):
		index = _as106
		_ok = 0
	else:
		index = _as106 + _best106
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_lexer_matcher_g_abnf_WS(char* input, int index):
	int _start = index
	int _ok = 1
	int _best113 = -1
	int _as113 = index
	index = _as113
	_ok = 1
	if (_ok):
		int _best115 = -1
		int _as115 = index
		index = _as115
		_ok = 1
		if (_ok):
			if ((input[index + 0] != ' ')):
				_ok = 0
			else:
				index = index + 1
		if (_ok):
			if ((index - _as115) > _best115):
				_best115 = index - _as115
		index = _as115
		_ok = 1
		if (_ok):
			if ((input[index + 0] != 9)):
				_ok = 0
			else:
				index = index + 1
		if (_ok):
			if ((index - _as115) > _best115):
				_best115 = index - _as115
		index = _as115
		_ok = 1
		if (_ok):
			if ((input[index + 0] != 13)):
				_ok = 0
			else:
				index = index + 1
		if (_ok):
			if ((index - _as115) > _best115):
				_best115 = index - _as115
		index = _as115
		_ok = 1
		if (_ok):
			if ((input[index + 0] != 10)):
				_ok = 0
			else:
				index = index + 1
		if (_ok):
			if ((index - _as115) > _best115):
				_best115 = index - _as115
		if (_best115 < 0):
			index = _as115
			_ok = 0
		else:
			index = _as115 + _best115
			_ok = 1
	if (_ok):
		if ((index - _as113) > _best113):
			_best113 = index - _as113
	if (_best113 < 0):
		index = _as113
		_ok = 0
	else:
		index = _as113 + _best113
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start

int pg_lexer_matcher_g_abnf_STRING(char* input, int index):
	int _start = index
	int _ok = 1
	int _best120 = -1
	int _as120 = index
	index = _as120
	_ok = 1
	if (_ok):
		int _s121 = index
		int _ok_save121 = _ok
		if (_ok):
			int _best123 = -1
			int _as123 = index
			index = _as123
			_ok = 1
			if (_ok):
				if ((input[index + 0] != '%') | (input[index + 1] != 's')):
					_ok = 0
				else:
					index = index + 2
			if (_ok):
				if ((index - _as123) > _best123):
					_best123 = index - _as123
			index = _as123
			_ok = 1
			if (_ok):
				if ((input[index + 0] != '%') | (input[index + 1] != 'i')):
					_ok = 0
				else:
					index = index + 2
			if (_ok):
				if ((index - _as123) > _best123):
					_best123 = index - _as123
			if (_best123 < 0):
				index = _as123
				_ok = 0
			else:
				index = _as123 + _best123
				_ok = 1
		if (_ok == 0):
			index = _s121
			_ok = _ok_save121
	if (_ok):
		if ((input[index + 0] != '"')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		while (_ok):
			int _s127 = index
			if (_ok):
				if ((((((input[index] == '"')) == 0) & (input[index] != 0))) == 0):
					_ok = 0
				else:
					index = index + 1
			if (_ok == 0):
				index = _s127
				_ok = 1
				break
			if (index == _s127):
				break
	if (_ok):
		if ((input[index + 0] != '"')):
			_ok = 0
		else:
			index = index + 1
	if (_ok):
		if ((index - _as120) > _best120):
			_best120 = index - _as120
	if (_best120 < 0):
		index = _as120
		_ok = 0
	else:
		index = _as120 + _best120
		_ok = 1
	if (_ok == 0):
		return 0
	return index - _start
