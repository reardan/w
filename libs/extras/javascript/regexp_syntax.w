# ECMAScript 2020 RegExp Pattern parser and early errors (sec-patterns,
# including Annex B.1.4 for patterns without the u flag).
# https://tc39.es/ecma262/2020/#sec-patterns
#
# js_regexp_parse builds a small pattern tree that the embedded interpreter
# compiles into its backtracking matcher (regexp_runtime.w); validation uses
# the same parser, so literal early errors and runtime syntax agree. Checks
# cover structure, escape values, class ranges, named groups/backreferences and
# Unicode property names/values. Property names and values are pinned to
# Unicode 12.1, matching the identifier tables in unicode.w.
import lib.utf8
import structures.string
import libs.extras.javascript.lexical


const int JS_RX_SEQ = 1
const int JS_RX_ALT = 2
const int JS_RX_CHAR = 3
const int JS_RX_DOT = 4
const int JS_RX_CLASS = 5
const int JS_RX_BOL = 6
const int JS_RX_EOL = 7
const int JS_RX_WORD = 8
const int JS_RX_GROUP = 9
const int JS_RX_LOOK = 10
const int JS_RX_BACKREF = 11
const int JS_RX_QUANT = 12

# Flag bits, shared with the lexer's flag scan.
const int JS_RX_GLOBAL = 1
const int JS_RX_IGNORE_CASE = 2
const int JS_RX_MULTILINE = 4
const int JS_RX_DOT_ALL = 8
const int JS_RX_UNICODE = 16
const int JS_RX_STICKY = 32

# Class set items below 128 are the escape letters dswDSW. Property escapes
# are JS_RX_PROPERTY + kind * 4096 + value index, plus JS_RX_NEGATED for \P.
const int JS_RX_PROPERTY = 1048576
const int JS_RX_NEGATED = 524288
const int JS_RX_PROPERTY_BINARY = 1
const int JS_RX_PROPERTY_GC = 2
const int JS_RX_PROPERTY_SCRIPT = 3
const int JS_RX_PROPERTY_SCX = 4


# kind-specific fields: CHAR value; WORD negate; GROUP value=capture index
# (0 for non-capturing); LOOK value=1 for lookbehind and negate; BACKREF
# value=capture index; QUANT min/max (-1 unbounded)/greedy; CLASS
# ranges (lo, hi pairs), sets and negate. Nodes are owned by their js_regexp.
struct js_regexp_node:
	int kind
	int value
	int min
	int max
	int greedy
	int negate
	char* name
	list[int] ranges
	list[int] sets
	list[js_regexp_node*] children


struct js_regexp:
	int flags
	int captures
	# names[i] is the UTF-8 name of capture i + 1, or 0.
	list[char*] names
	js_regexp_node* root
	list[js_regexp_node*] nodes
	char* error


struct js_regexp_parser:
	list[int] src
	int pos
	int unicode
	int named
	int total
	int captures
	js_regexp* rx


js_regexp_node* js_regexp_node_new(js_regexp_parser* p, int kind):
	js_regexp_node* node = new js_regexp_node()
	node.kind = kind
	node.value = 0
	node.min = 0
	node.max = 0
	node.greedy = 1
	node.negate = 0
	node.name = 0
	node.ranges = new list[int]
	node.sets = new list[int]
	node.children = new list[js_regexp_node*]
	p.rx.nodes.push(node)
	return node


void js_regexp_free(js_regexp* rx):
	if (rx == 0): return
	for js_regexp_node* node in rx.nodes:
		if (node.name != 0): free(node.name)
		__w_list_free(cast(__w_list*, node.ranges))
		__w_list_free(cast(__w_list*, node.sets))
		__w_list_free(cast(__w_list*, node.children))
		free(node)
	for char* name in rx.names:
		if (name != 0): free(name)
	__w_list_free(cast(__w_list*, rx.nodes))
	__w_list_free(cast(__w_list*, rx.names))
	free(rx)


# The first error wins; messages are static.
int js_regexp_fail(js_regexp_parser* p, char* message):
	if (p.rx.error == 0): p.rx.error = message
	return 0


int js_regexp_peek(js_regexp_parser* p, int offset):
	int at = p.pos + offset
	if (at < 0 || at >= p.src.length): return -1
	return p.src[at]


int js_regexp_eat(js_regexp_parser* p, int ch):
	if (js_regexp_peek(p, 0) != ch): return 0
	p.pos = p.pos + 1
	return 1


int js_regexp_syntax_char(int ch):
	return ch == '^' || ch == '$' || ch == 92 || ch == '.' || ch == '*' || ch == '+' || ch == '?' || ch == '(' || ch == ')' || ch == '[' || ch == ']' || ch == '{' || ch == '}' || ch == '|'


int js_regexp_letter(int ch):
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')


int js_regexp_lead(int ch):
	return ch >= 55296 && ch <= 56319


int js_regexp_trail(int ch):
	return ch >= 56320 && ch <= 57343


# Space-delimited name tables. Unicode 12.1 PropertyValueAliases (scripts
# added in Unicode 13-15 are excluded) and the ES2020 binary property table.
char* js_regexp_gc_names():
	return c" C Other Cc Control cntrl Cf Format Cn Unassigned Co Private_Use Cs Surrogate L Letter LC Cased_Letter Ll Lowercase_Letter Lm Modifier_Letter Lo Other_Letter Lt Titlecase_Letter Lu Uppercase_Letter M Mark Combining_Mark Mc Spacing_Mark Me Enclosing_Mark Mn Nonspacing_Mark N Number Nd Decimal_Number digit Nl Letter_Number No Other_Number P Punctuation punct Pc Connector_Punctuation Pd Dash_Punctuation Pe Close_Punctuation Pf Final_Punctuation Pi Initial_Punctuation Po Other_Punctuation Ps Open_Punctuation S Symbol Sc Currency_Symbol Sk Modifier_Symbol Sm Math_Symbol So Other_Symbol Z Separator Zl Line_Separator Zp Paragraph_Separator Zs Space_Separator "


char* js_regexp_binary_names():
	return c" ASCII ASCII_Hex_Digit AHex Alphabetic Alpha Any Assigned Bidi_Control Bidi_C Bidi_Mirrored Bidi_M Case_Ignorable CI Cased Changes_When_Casefolded CWCF Changes_When_Casemapped CWCM Changes_When_Lowercased CWL Changes_When_NFKC_Casefolded CWKCF Changes_When_Titlecased CWT Changes_When_Uppercased CWU Dash Default_Ignorable_Code_Point DI Deprecated Dep Diacritic Dia Emoji Emoji_Component Emoji_Modifier Emoji_Modifier_Base Emoji_Presentation Extended_Pictographic Extender Ext Grapheme_Base Gr_Base Grapheme_Extend Gr_Ext Hex_Digit Hex IDS_Binary_Operator IDSB IDS_Trinary_Operator IDST ID_Continue IDC ID_Start IDS Ideographic Ideo Join_Control Join_C Logical_Order_Exception LOE Lowercase Lower Math Noncharacter_Code_Point NChar Pattern_Syntax Pat_Syn Pattern_White_Space Pat_WS Quotation_Mark QMark Radical Regional_Indicator RI Sentence_Terminal STerm Soft_Dotted SD Terminal_Punctuation Term Unified_Ideograph UIdeo Uppercase Upper Variation_Selector VS White_Space space XID_Continue XIDC XID_Start XIDS "


char* js_regexp_script_names():
	return c" Adlm Adlam Aghb Caucasian_Albanian Ahom Arab Arabic Armi Imperial_Aramaic Armn Armenian Avst Avestan Bali Balinese Bamu Bamum Bass Bassa_Vah Batk Batak Beng Bengali Bhks Bhaiksuki Bopo Bopomofo Brah Brahmi Brai Braille Bugi Buginese Buhd Buhid Cakm Chakma Cans Canadian_Aboriginal Cari Carian Cham Cher Cherokee Copt Coptic Qaac Cprt Cypriot Cyrl Cyrillic Deva Devanagari Dogr Dogra Dsrt Deseret Dupl Duployan Egyp Egyptian_Hieroglyphs Elba Elbasan Elym Elymaic Ethi Ethiopic Geor Georgian Glag Glagolitic Gong Gunjala_Gondi Gonm Masaram_Gondi Goth Gothic Gran Grantha Grek Greek Gujr Gujarati Guru Gurmukhi Hang Hangul Hani Han Hano Hanunoo Hatr Hatran Hebr Hebrew Hira Hiragana Hluw Anatolian_Hieroglyphs Hmng Pahawh_Hmong Hmnp Nyiakeng_Puachue_Hmong Hrkt Katakana_Or_Hiragana Hung Old_Hungarian Ital Old_Italic Java Javanese Kali Kayah_Li Kana Katakana Khar Kharoshthi Khmr Khmer Khoj Khojki Knda Kannada Kthi Kaithi Lana Tai_Tham Laoo Lao Latn Latin Lepc Lepcha Limb Limbu Lina Linear_A Linb Linear_B Lisu Lyci Lycian Lydi Lydian Mahj Mahajani Maka Makasar Mand Mandaic Mani Manichaean Marc Marchen Medf Medefaidrin Mend Mende_Kikakui Merc Meroitic_Cursive Mero Meroitic_Hieroglyphs Mlym Malayalam Modi Mong Mongolian Mroo Mro Mtei Meetei_Mayek Mult Multani Mymr Myanmar Nand Nandinagari Narb Old_North_Arabian Nbat Nabataean Newa Nkoo Nko Nshu Nushu Ogam Ogham Olck Ol_Chiki Orkh Old_Turkic Orya Oriya Osge Osage Osma Osmanya Palm Palmyrene Pauc Pau_Cin_Hau Perm Old_Permic Phag Phags_Pa Phli Inscriptional_Pahlavi Phlp Psalter_Pahlavi Phnx Phoenician Plrd Miao Prti Inscriptional_Parthian Rjng Rejang Rohg Hanifi_Rohingya Runr Runic Samr Samaritan Sarb Old_South_Arabian Saur Saurashtra Sgnw SignWriting Shaw Shavian Shrd Sharada Sidd Siddham Sind Khudawadi Sinh Sinhala Sogd Sogdian Sogo Old_Sogdian Sora Sora_Sompeng Soyo Soyombo Sund Sundanese Sylo Syloti_Nagri Syrc Syriac Tagb Tagbanwa Takr Takri Tale Tai_Le Talu New_Tai_Lue Taml Tamil Tang Tangut Tavt Tai_Viet Telu Telugu Tfng Tifinagh Tglg Tagalog Thaa Thaana Thai Tibt Tibetan Tirh Tirhuta Ugar Ugaritic Vaii Vai Wara Warang_Citi Wcho Wancho Xpeo Old_Persian Xsux Cuneiform Yiii Yi Zanb Zanabazar_Square Zinh Inherited Qaai Zyyy Common Zzzz Unknown "


# Returns the 1-based word index of name in table, or 0. Names are ASCII
# [A-Za-z0-9_] already, so a space-delimited exact search is unambiguous.
int js_regexp_table_index(char* table, char* name):
	int n = strlen(name)
	int index = 0
	int i = 0
	while (table[i] != 0):
		if (table[i] == ' ' && table[i + 1] != 0):
			index = index + 1
			int j = 0
			while (j < n && table[i + 1 + j] == name[j]): j = j + 1
			if (j == n && table[i + 1 + n] == ' '): return index
		i = i + 1
	return 0


# \p{...} after the opening brace. Returns the set item, or 0 on error.
int js_regexp_property(js_regexp_parser* p, int negated):
	string_builder* name = string_new()
	string_builder* value = string_new()
	int equals = 0
	int ok = 1
	while (1):
		int ch = js_regexp_peek(p, 0)
		if (ch < 0):
			ok = js_regexp_fail(p, c"invalid regular expression: unterminated property escape")
			break
		p.pos = p.pos + 1
		if (ch == '}'): break
		if (ch == '=' && equals == 0):
			equals = 1
			continue
		if (js_regexp_letter(ch) == 0 && ch != '_' && (equals == 0 || js_digit(ch) == 0)):
			ok = js_regexp_fail(p, c"invalid regular expression: invalid property name")
			break
		if (equals): string_append_char(value, ch)
		else: string_append_char(name, ch)
	int result = 0
	if (ok):
		char* left = name.data
		char* right = value.data
		if (name.length == 0 || (equals && value.length == 0)): js_regexp_fail(p, c"invalid regular expression: invalid property name")
		else if (equals):
			int kind = 0
			if (strcmp(left, c"General_Category") == 0 || strcmp(left, c"gc") == 0): kind = JS_RX_PROPERTY_GC
			if (strcmp(left, c"Script") == 0 || strcmp(left, c"sc") == 0): kind = JS_RX_PROPERTY_SCRIPT
			if (strcmp(left, c"Script_Extensions") == 0 || strcmp(left, c"scx") == 0): kind = JS_RX_PROPERTY_SCX
			int index = 0
			if (kind == JS_RX_PROPERTY_GC): index = js_regexp_table_index(js_regexp_gc_names(), right)
			if (kind == JS_RX_PROPERTY_SCRIPT || kind == JS_RX_PROPERTY_SCX): index = js_regexp_table_index(js_regexp_script_names(), right)
			if (kind == 0): js_regexp_fail(p, c"invalid regular expression: unknown property name")
			else if (index == 0): js_regexp_fail(p, c"invalid regular expression: unknown property value")
			else: result = JS_RX_PROPERTY + kind * 4096 + index
		else:
			int index = js_regexp_table_index(js_regexp_gc_names(), left)
			if (index != 0): result = JS_RX_PROPERTY + JS_RX_PROPERTY_GC * 4096 + index
			else:
				index = js_regexp_table_index(js_regexp_binary_names(), left)
				if (index == 0): js_regexp_fail(p, c"invalid regular expression: unknown property name or value")
				else: result = JS_RX_PROPERTY + JS_RX_PROPERTY_BINARY * 4096 + index
	string_free(name)
	string_free(value)
	if (result != 0 && negated): result = result + JS_RX_NEGATED
	return result


# Hex4Digits or {CodePoint} after "\u". Returns -1 when malformed.
int js_regexp_hex4(js_regexp_parser* p, int offset):
	int value = 0
	for i in range(4):
		int digit = js_hex(js_regexp_peek(p, offset + i))
		if (digit < 0): return -1
		value = value * 16 + digit
	return value


# RegExpUnicodeEscapeSequence with p.pos at the "u". unicode selects the
# [+U] form (braces and surrogate-pair joining). Returns -1 when malformed,
# leaving p.pos unchanged.
int js_regexp_unicode_escape(js_regexp_parser* p, int unicode):
	if (unicode && js_regexp_peek(p, 1) == '{'):
		int i = 2
		int value = 0
		while (js_hex(js_regexp_peek(p, i)) >= 0):
			value = value * 16 + js_hex(js_regexp_peek(p, i))
			if (value > 1114111): return -1
			i = i + 1
		if (i == 2 || js_regexp_peek(p, i) != '}'): return -1
		p.pos = p.pos + i + 1
		return value
	int value = js_regexp_hex4(p, 1)
	if (value < 0): return -1
	p.pos = p.pos + 5
	if (unicode && js_regexp_lead(value) && js_regexp_peek(p, 0) == 92 && js_regexp_peek(p, 1) == 'u'):
		int low = js_regexp_hex4(p, 2)
		if (low >= 0 && js_regexp_trail(low)):
			p.pos = p.pos + 6
			value = 65536 + ((value - 55296) << 10) + (low - 56320)
	return value


# RegExpIdentifierName after "<"; consumes ">". Returns owned UTF-8 or 0.
char* js_regexp_group_name(js_regexp_parser* p):
	string_builder* out = string_new()
	int count = 0
	while (1):
		int ch = js_regexp_peek(p, 0)
		if (ch < 0):
			js_regexp_fail(p, c"invalid regular expression: unterminated group name")
			break
		if (ch == '>'):
			p.pos = p.pos + 1
			break
		if (ch == 92):
			p.pos = p.pos + 1
			if (js_regexp_peek(p, 0) != 'u'): ch = -1
			else: ch = js_regexp_unicode_escape(p, 1)
		else:
			p.pos = p.pos + 1
			# Without u the pattern is code units; Node joins literal pairs.
			if (js_regexp_lead(ch) && js_regexp_trail(js_regexp_peek(p, 0))):
				ch = 65536 + ((ch - 55296) << 10) + (js_regexp_peek(p, 0) - 56320)
				p.pos = p.pos + 1
		int valid = ch >= 0 && js_identifier_part(ch)
		if (count == 0): valid = ch >= 0 && js_identifier_start(ch)
		if (valid == 0):
			js_regexp_fail(p, c"invalid regular expression: invalid group name")
			break
		char[4] encoded
		int width = utf8_encode(encoded, ch)
		string_append_bytes(out, encoded, width)
		count = count + 1
	if (p.rx.error == 0 && count == 0): js_regexp_fail(p, c"invalid regular expression: empty group name")
	char* name = 0
	if (p.rx.error == 0): name = strclone(out.data)
	string_free(out)
	return name


# Legacy octal escape (Annex B) with p.pos at the first octal digit.
int js_regexp_legacy_octal(js_regexp_parser* p):
	int first = js_regexp_peek(p, 0) - '0'
	p.pos = p.pos + 1
	int value = first
	int next = js_regexp_peek(p, 0)
	if (next >= '0' && next <= '7'):
		value = value * 8 + next - '0'
		p.pos = p.pos + 1
		next = js_regexp_peek(p, 0)
		if (first <= 3 && next >= '0' && next <= '7'):
			value = value * 8 + next - '0'
			p.pos = p.pos + 1
	return value


# CharacterEscape / ClassEscape after the backslash (p.pos at the escape
# character). Returns the character value or -1 after reporting an error.
# Decimal escapes and class escapes are handled by the callers.
int js_regexp_character_escape(js_regexp_parser* p, int in_class):
	int ch = js_regexp_peek(p, 0)
	if (ch < 0): return js_regexp_fail(p, c"invalid regular expression: \\ at end of pattern") - 1
	if (ch == 'f' || ch == 'n' || ch == 'r' || ch == 't' || ch == 'v'):
		p.pos = p.pos + 1
		if (ch == 'f'): return 12
		if (ch == 'n'): return 10
		if (ch == 'r'): return 13
		if (ch == 't'): return 9
		return 11
	if (ch == 'c'):
		int letter = js_regexp_peek(p, 1)
		if (js_regexp_letter(letter) || (in_class && p.unicode == 0 && (js_digit(letter) || letter == '_'))):
			p.pos = p.pos + 2
			return letter % 32
		if (p.unicode): return js_regexp_fail(p, c"invalid regular expression: invalid control escape") - 1
		# Annex B: "\c" without a control letter is a literal backslash.
		return 92
	if (ch == 'x'):
		int high = js_hex(js_regexp_peek(p, 1))
		int low = js_hex(js_regexp_peek(p, 2))
		if (high >= 0 && low >= 0):
			p.pos = p.pos + 3
			return high * 16 + low
		if (p.unicode): return js_regexp_fail(p, c"invalid regular expression: invalid hexadecimal escape") - 1
		p.pos = p.pos + 1
		return 'x'
	if (ch == 'u'):
		int value = js_regexp_unicode_escape(p, p.unicode)
		if (value >= 0): return value
		if (p.unicode): return js_regexp_fail(p, c"invalid regular expression: invalid Unicode escape") - 1
		p.pos = p.pos + 1
		return 'u'
	if (ch == '0' && js_digit(js_regexp_peek(p, 1)) == 0):
		p.pos = p.pos + 1
		return 0
	if (p.unicode):
		if (js_regexp_syntax_char(ch) || ch == '/' || (in_class && ch == '-')):
			p.pos = p.pos + 1
			return ch
		return js_regexp_fail(p, c"invalid regular expression: invalid identity escape") - 1
	if (ch >= '0' && ch <= '7'): return js_regexp_legacy_octal(p)
	if (ch == 'k' && p.named): return js_regexp_fail(p, c"invalid regular expression: invalid named reference") - 1
	p.pos = p.pos + 1
	# A source surrogate pair is two pattern units without u; keep them so.
	return ch


int js_regexp_class_set_letter(int ch):
	return ch == 'd' || ch == 'D' || ch == 's' || ch == 'S' || ch == 'w' || ch == 'W'


# One ClassAtom. Returns its character, or -2 when it is a class escape
# (pushed to sets), or -1 after an error.
int js_regexp_class_atom(js_regexp_parser* p, list[int] sets):
	int ch = js_regexp_peek(p, 0)
	if (ch != 92):
		p.pos = p.pos + 1
		return ch
	p.pos = p.pos + 1
	int next = js_regexp_peek(p, 0)
	if (js_regexp_class_set_letter(next)):
		p.pos = p.pos + 1
		sets.push(next)
		return -2
	if (p.unicode && (next == 'p' || next == 'P')):
		if (js_regexp_peek(p, 1) != '{'): return js_regexp_fail(p, c"invalid regular expression: invalid property escape") - 1
		p.pos = p.pos + 2
		int item = js_regexp_property(p, next == 'P')
		if (item == 0): return -1
		sets.push(item)
		return -2
	if (next == 'b'):
		p.pos = p.pos + 1
		return 8
	if (p.unicode == 0 && next == '-'):
		p.pos = p.pos + 1
		return '-'
	if (js_digit(next) && (next != '0' || js_digit(js_regexp_peek(p, 1)))):
		if (p.unicode): return js_regexp_fail(p, c"invalid regular expression: invalid class escape") - 1
		if (next >= '8'):
			p.pos = p.pos + 1
			return next
		return js_regexp_legacy_octal(p)
	if (p.unicode == 0 && next == 'k' && p.named == 0):
		p.pos = p.pos + 1
		return 'k'
	return js_regexp_character_escape(p, 1)


js_regexp_node* js_regexp_class(js_regexp_parser* p):
	js_regexp_node* node = js_regexp_node_new(p, JS_RX_CLASS)
	if (js_regexp_eat(p, '^')): node.negate = 1
	while (p.rx.error == 0):
		int ch = js_regexp_peek(p, 0)
		if (ch < 0):
			js_regexp_fail(p, c"invalid regular expression: unterminated character class")
			break
		if (ch == ']'):
			p.pos = p.pos + 1
			break
		int low = js_regexp_class_atom(p, node.sets)
		if (low == -1): break
		if (js_regexp_peek(p, 0) == '-' && js_regexp_peek(p, 1) != ']' && js_regexp_peek(p, 1) >= 0):
			p.pos = p.pos + 1
			int high = js_regexp_class_atom(p, node.sets)
			if (high == -1): break
			if (low == -2 || high == -2):
				if (p.unicode):
					js_regexp_fail(p, c"invalid regular expression: class escape in class range")
					break
				# Annex B: a class escape at either end makes "-" literal.
				node.ranges.push('-')
				node.ranges.push('-')
				if (low >= 0):
					node.ranges.push(low)
					node.ranges.push(low)
				if (high >= 0):
					node.ranges.push(high)
					node.ranges.push(high)
				continue
			if (low > high):
				js_regexp_fail(p, c"invalid regular expression: range out of order in character class")
				break
			node.ranges.push(low)
			node.ranges.push(high)
			continue
		if (low >= 0):
			node.ranges.push(low)
			node.ranges.push(low)
	return node


# Decimal digits at p.pos + offset, saturated at 2^31-1 without overflowing
# a 32-bit word. Stores the digit span end in *end.
int js_regexp_decimal(js_regexp_parser* p, int offset, int* end):
	int value = 0
	while (js_digit(js_regexp_peek(p, offset))):
		int digit = js_regexp_peek(p, offset) - '0'
		if (value > 214748363): value = 2147483647
		else: value = value * 10 + digit
		offset = offset + 1
	*end = offset
	return value


# Compare unbounded decimal digit spans without overflowing a W word.
int js_regexp_digits_greater(js_regexp_parser* p, int left, int left_end, int right, int right_end):
	while (left < left_end && js_regexp_peek(p, left) == '0'): left = left + 1
	while (right < right_end && js_regexp_peek(p, right) == '0'): right = right + 1
	if (left_end - left != right_end - right): return left_end - left > right_end - right
	while (left < left_end):
		if (js_regexp_peek(p, left) != js_regexp_peek(p, right)): return js_regexp_peek(p, left) > js_regexp_peek(p, right)
		left = left + 1
		right = right + 1
	return 0


# Returns the length of a complete braced quantifier at pos ({n}, {n,},
# {n,m}) or 0. Bounds saturate at 2^31-1; *reversed reports {n,m} with n > m
# using exact digit comparison.
int js_regexp_braced(js_regexp_parser* p, int* low, int* high, int* reversed):
	if (js_digit(js_regexp_peek(p, 1)) == 0): return 0
	int low_end = 0
	int lo = js_regexp_decimal(p, 1, &low_end)
	int i = low_end
	int hi = lo
	*reversed = 0
	if (js_regexp_peek(p, i) == ','):
		i = i + 1
		hi = -1
		if (js_digit(js_regexp_peek(p, i))):
			int high_end = 0
			hi = js_regexp_decimal(p, i, &high_end)
			*reversed = js_regexp_digits_greater(p, 1, low_end, i, high_end)
			i = high_end
	if (js_regexp_peek(p, i) != '}'): return 0
	*low = lo
	*high = hi
	return i + 1


js_regexp_node* js_regexp_disjunction(js_regexp_parser* p);


js_regexp_node* js_regexp_set_node(js_regexp_parser* p, int item):
	js_regexp_node* node = js_regexp_node_new(p, JS_RX_CLASS)
	node.sets.push(item)
	return node


js_regexp_node* js_regexp_char_node(js_regexp_parser* p, int ch):
	js_regexp_node* node = js_regexp_node_new(p, JS_RX_CHAR)
	node.value = ch
	return node


# AtomEscape after the backslash. Returns 0 after an error.
js_regexp_node* js_regexp_atom_escape(js_regexp_parser* p):
	int ch = js_regexp_peek(p, 0)
	if (ch >= '1' && ch <= '9'):
		int start = p.pos
		int value = 0
		while (js_digit(js_regexp_peek(p, 0))):
			if (value < 100000): value = value * 10 + js_regexp_peek(p, 0) - '0'
			p.pos = p.pos + 1
		if (value <= p.total):
			js_regexp_node* node = js_regexp_node_new(p, JS_RX_BACKREF)
			node.value = value
			return node
		if (p.unicode):
			js_regexp_fail(p, c"invalid regular expression: invalid backreference")
			return 0
		# Annex B: reparse as a legacy octal or identity escape.
		p.pos = start
		if (ch >= '8'):
			p.pos = p.pos + 1
			return js_regexp_char_node(p, ch)
		return js_regexp_char_node(p, js_regexp_legacy_octal(p))
	if (js_regexp_class_set_letter(ch)):
		p.pos = p.pos + 1
		return js_regexp_set_node(p, ch)
	if (p.unicode && (ch == 'p' || ch == 'P')):
		if (js_regexp_peek(p, 1) != '{'):
			js_regexp_fail(p, c"invalid regular expression: invalid property escape")
			return 0
		p.pos = p.pos + 2
		int item = js_regexp_property(p, ch == 'P')
		if (item == 0): return 0
		return js_regexp_set_node(p, item)
	if (ch == 'k' && p.named):
		if (js_regexp_peek(p, 1) != '<'):
			js_regexp_fail(p, c"invalid regular expression: invalid named reference")
			return 0
		p.pos = p.pos + 2
		char* name = js_regexp_group_name(p)
		if (name == 0): return 0
		js_regexp_node* node = js_regexp_node_new(p, JS_RX_BACKREF)
		node.name = name
		return node
	int value = js_regexp_character_escape(p, 0)
	if (value < 0): return 0
	return js_regexp_char_node(p, value)


js_regexp_node* js_regexp_group(js_regexp_parser* p):
	js_regexp_node* node = js_regexp_node_new(p, JS_RX_GROUP)
	if (js_regexp_eat(p, '?')):
		if (js_regexp_eat(p, ':') == 0):
			if (js_regexp_eat(p, '<') == 0):
				js_regexp_fail(p, c"invalid regular expression: invalid group")
				return 0
			char* name = js_regexp_group_name(p)
			if (name == 0): return 0
			for char* other in p.rx.names:
				if (other != 0 && strcmp(other, name) == 0):
					free(name)
					js_regexp_fail(p, c"invalid regular expression: duplicate capture group name")
					return 0
			p.captures = p.captures + 1
			node.value = p.captures
			p.rx.names.push(name)
	else:
		p.captures = p.captures + 1
		node.value = p.captures
		p.rx.names.push(0)
	node.children.push(js_regexp_disjunction(p))
	if (p.rx.error == 0 && js_regexp_eat(p, ')') == 0): js_regexp_fail(p, c"invalid regular expression: unterminated group")
	return node


# Atom / Annex B ExtendedAtom. Returns 0 after an error.
js_regexp_node* js_regexp_atom(js_regexp_parser* p):
	int ch = js_regexp_peek(p, 0)
	if (ch == '.'):
		p.pos = p.pos + 1
		return js_regexp_node_new(p, JS_RX_DOT)
	if (ch == '('):
		p.pos = p.pos + 1
		return js_regexp_group(p)
	if (ch == '['):
		p.pos = p.pos + 1
		return js_regexp_class(p)
	if (ch == 92):
		p.pos = p.pos + 1
		return js_regexp_atom_escape(p)
	if (ch == '*' || ch == '+' || ch == '?'):
		js_regexp_fail(p, c"invalid regular expression: nothing to repeat")
		return 0
	if (ch == '{' || ch == '}' || ch == ']'):
		int low = 0
		int high = 0
		int reversed = 0
		if (p.unicode || (ch == '{' && js_regexp_braced(p, &low, &high, &reversed))):
			js_regexp_fail(p, c"invalid regular expression: lone quantifier bracket")
			return 0
	p.pos = p.pos + 1
	return js_regexp_char_node(p, ch)


# Term. Appends to seq; returns 0 after an error.
int js_regexp_term(js_regexp_parser* p, js_regexp_node* seq):
	int ch = js_regexp_peek(p, 0)
	js_regexp_node* atom = 0
	int quantifiable = 1
	if (ch == '^' || ch == '$'):
		p.pos = p.pos + 1
		atom = js_regexp_node_new(p, JS_RX_BOL)
		if (ch == '$'): atom.kind = JS_RX_EOL
		quantifiable = 0
	else if (ch == 92 && (js_regexp_peek(p, 1) == 'b' || js_regexp_peek(p, 1) == 'B')):
		atom = js_regexp_node_new(p, JS_RX_WORD)
		atom.negate = js_regexp_peek(p, 1) == 'B'
		p.pos = p.pos + 2
		quantifiable = 0
	else if (ch == '(' && js_regexp_peek(p, 1) == '?' && (js_regexp_peek(p, 2) == '=' || js_regexp_peek(p, 2) == '!' || (js_regexp_peek(p, 2) == '<' && (js_regexp_peek(p, 3) == '=' || js_regexp_peek(p, 3) == '!')))):
		atom = js_regexp_node_new(p, JS_RX_LOOK)
		if (js_regexp_peek(p, 2) == '<'):
			atom.value = 1
			p.pos = p.pos + 1
		atom.negate = js_regexp_peek(p, 2) == '!'
		p.pos = p.pos + 3
		atom.children.push(js_regexp_disjunction(p))
		if (p.rx.error == 0 && js_regexp_eat(p, ')') == 0): return js_regexp_fail(p, c"invalid regular expression: unterminated group")
		# Annex B allows quantified lookahead only without u.
		quantifiable = p.unicode == 0 && atom.value == 0
	else: atom = js_regexp_atom(p)
	if (atom == 0 || p.rx.error != 0): return 0
	int low = 0
	int high = 0
	int reversed = 0
	int next = js_regexp_peek(p, 0)
	int end = 0
	if (next == '*'):
		high = -1
		end = p.pos + 1
	else if (next == '+'):
		low = 1
		high = -1
		end = p.pos + 1
	else if (next == '?'):
		high = 1
		end = p.pos + 1
	else if (next == '{'):
		end = js_regexp_braced(p, &low, &high, &reversed)
		if (end != 0): end = p.pos + end
		else if (p.unicode): return js_regexp_fail(p, c"invalid regular expression: incomplete quantifier")
	if (end == 0):
		seq.children.push(atom)
		return 1
	if (quantifiable == 0): return js_regexp_fail(p, c"invalid regular expression: nothing to repeat")
	if (reversed): return js_regexp_fail(p, c"invalid regular expression: numbers out of order in quantifier")
	p.pos = end
	js_regexp_node* quant = js_regexp_node_new(p, JS_RX_QUANT)
	quant.min = low
	quant.max = high
	if (js_regexp_eat(p, '?')): quant.greedy = 0
	quant.children.push(atom)
	seq.children.push(quant)
	return 1


js_regexp_node* js_regexp_disjunction(js_regexp_parser* p):
	js_regexp_node* alt = js_regexp_node_new(p, JS_RX_ALT)
	while (1):
		js_regexp_node* seq = js_regexp_node_new(p, JS_RX_SEQ)
		alt.children.push(seq)
		while (p.rx.error == 0):
			int ch = js_regexp_peek(p, 0)
			if (ch < 0 || ch == '|' || ch == ')'): break
			if (js_regexp_term(p, seq) == 0): break
		if (p.rx.error != 0 || js_regexp_eat(p, '|') == 0): break
	return alt


# Capture count and whether any GroupName exists, which selects the [N]
# grammar parameter (sec-parsepattern / Annex B.1.4).
void js_regexp_prescan(js_regexp_parser* p):
	int i = 0
	int in_class = 0
	int n = p.src.length
	while (i < n):
		int ch = p.src[i]
		if (ch == 92): i = i + 1
		else if (in_class):
			if (ch == ']'): in_class = 0
		else if (ch == '['): in_class = 1
		else if (ch == '(' && (i + 1 >= n || p.src[i + 1] != '?')): p.total = p.total + 1
		else if (ch == '(' && i + 2 < n && p.src[i + 2] == '<' && (i + 3 >= n || (p.src[i + 3] != '=' && p.src[i + 3] != '!'))):
			p.total = p.total + 1
			p.named = 1
		i = i + 1


void js_regexp_resolve(js_regexp* rx):
	for js_regexp_node* node in rx.nodes:
		if (node.kind != JS_RX_BACKREF || node.name == 0): continue
		for i in range(rx.names.length):
			if (rx.names[i] != 0 && strcmp(rx.names[i], node.name) == 0): node.value = i + 1
		if (node.value == 0 && rx.error == 0): rx.error = c"invalid regular expression: invalid named capture referenced"


# pattern holds code points with u and UTF-16 code units without u.
js_regexp* js_regexp_parse(list[int] pattern, int flags):
	js_regexp* rx = new js_regexp()
	rx.flags = flags
	rx.captures = 0
	rx.names = new list[char*]
	rx.nodes = new list[js_regexp_node*]
	rx.error = 0
	rx.root = 0
	js_regexp_parser parser
	js_regexp_parser* p = &parser
	p.src = pattern
	p.pos = 0
	p.unicode = (flags & JS_RX_UNICODE) != 0
	p.named = p.unicode
	p.total = 0
	p.captures = 0
	p.rx = rx
	js_regexp_prescan(p)
	rx.root = js_regexp_disjunction(p)
	if (rx.error == 0 && p.pos < pattern.length): js_regexp_fail(p, c"invalid regular expression: unmatched )")
	rx.captures = p.captures
	if (rx.error == 0): js_regexp_resolve(rx)
	return rx


# Decode UTF-8 pattern bytes; without u, astral scalars become two units.
list[int] js_regexp_units(char* text, int start, int end, int unicode):
	list[int] units = new list[int]
	int i = start
	while (i < end):
		int cp = 0
		int width = utf8_scan(text + i, end - i, &cp)
		if (width == 0):
			cp = text[i] & 255
			width = 1
		if (unicode == 0 && cp > 65535):
			units.push(55296 + ((cp - 65536) >> 10))
			units.push(56320 + ((cp - 65536) & 1023))
		else: units.push(cp)
		i = i + width
	return units


int js_regexp_flag_bits(char* text, int start):
	int flags = 0
	int i = start
	while (text[i] != 0):
		int ch = text[i]
		if (ch == 'g'): flags = flags | JS_RX_GLOBAL
		if (ch == 'i'): flags = flags | JS_RX_IGNORE_CASE
		if (ch == 'm'): flags = flags | JS_RX_MULTILINE
		if (ch == 's'): flags = flags | JS_RX_DOT_ALL
		if (ch == 'u'): flags = flags | JS_RX_UNICODE
		if (ch == 'y'): flags = flags | JS_RX_STICKY
		i = i + 1
	return flags


# Parse a lexed /pattern/flags literal. The lexer already identified the
# closing slash and validated flags, so a backwards scan is unambiguous.
js_regexp* js_regexp_parse_literal(char* text):
	int end = strlen(text) - 1
	while (end > 0 && text[end] != '/'): end = end - 1
	int flags = js_regexp_flag_bits(text, end + 1)
	list[int] units = js_regexp_units(text, 1, end, (flags & JS_RX_UNICODE) != 0)
	js_regexp* rx = js_regexp_parse(units, flags)
	__w_list_free(cast(__w_list*, units))
	return rx


# Static early-error message for a regular expression literal, or 0.
char* js_regexp_literal_error(char* text):
	if (strlen(text) < 2): return c"invalid regular expression literal"
	js_regexp* rx = js_regexp_parse_literal(text)
	char* error = rx.error
	js_regexp_free(rx)
	return error


int js_regexp_syntax(char* text):
	return js_regexp_literal_error(text) == 0
