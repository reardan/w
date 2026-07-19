import lib.utf8
import lib.grapheme_data


int grapheme_should_break(int previous, int current, int ri_count, int previous_extended_pictographic_zwj):
	if ((previous == grapheme_prop_cr()) & (current == grapheme_prop_lf())):
		return 0
	if ((previous == grapheme_prop_cr()) | (previous == grapheme_prop_lf()) | (previous == grapheme_prop_control())):
		return 1
	if ((current == grapheme_prop_cr()) | (current == grapheme_prop_lf()) | (current == grapheme_prop_control())):
		return 1
	if (previous == grapheme_prop_l()):
		if ((current == grapheme_prop_l()) | (current == grapheme_prop_v()) |
				(current == grapheme_prop_lv()) | (current == grapheme_prop_lvt())):
			return 0
	if ((previous == grapheme_prop_lv()) | (previous == grapheme_prop_v())):
		if ((current == grapheme_prop_v()) | (current == grapheme_prop_t())):
			return 0
	if ((previous == grapheme_prop_lvt()) | (previous == grapheme_prop_t())):
		if (current == grapheme_prop_t()):
			return 0
	if ((current == grapheme_prop_extend()) | (current == grapheme_prop_zwj())):
		return 0
	if (current == grapheme_prop_spacing_mark()):
		return 0
	if (previous == grapheme_prop_prepend()):
		return 0
	if (previous_extended_pictographic_zwj & (current == grapheme_prop_extended_pictographic())):
		return 0
	if ((previous == grapheme_prop_regional_indicator()) & (current == grapheme_prop_regional_indicator())):
		return (ri_count % 2) == 0
	return 1


int grapheme_next(string s, int byte_index):
	if (byte_index >= s.length):
		return s.length
	assert1(byte_index >= 0)
	int first = utf8_decode(s, byte_index)
	int previous = grapheme_property(first)
	int previous_non_extend = previous
	int ri_count = 0
	int extended_pictographic_before_zwj = previous == grapheme_prop_extended_pictographic()
	int previous_extended_pictographic_zwj = 0
	if (previous == grapheme_prop_regional_indicator()):
		ri_count = 1
	int i = utf8_next(s, byte_index)
	while (i < s.length):
		int cp = utf8_decode(s, i)
		int current = grapheme_property(cp)
		if (grapheme_should_break(previous, current, ri_count, previous_extended_pictographic_zwj)):
			return i
		if (current == grapheme_prop_regional_indicator()):
			ri_count = ri_count + 1
		else if (current != grapheme_prop_extend()):
			ri_count = 0
		previous_extended_pictographic_zwj = extended_pictographic_before_zwj & (current == grapheme_prop_zwj())
		if ((current != grapheme_prop_extend()) & (current != grapheme_prop_zwj())):
			extended_pictographic_before_zwj = current == grapheme_prop_extended_pictographic()
			previous_non_extend = current
		previous = current
		i = utf8_next(s, i)
	return s.length


int grapheme_is_boundary(string s, int byte_index):
	if ((byte_index < 0) || (byte_index > s.length)):
		return 0
	if ((byte_index == 0) || (byte_index == s.length)):
		return 1
	int i = 0
	while (i < s.length):
		i = grapheme_next(s, i)
		if (i == byte_index):
			return 1
		if (i > byte_index):
			return 0
	return 0


int grapheme_count(string s):
	int count = 0
	int i = 0
	while (i < s.length):
		i = grapheme_next(s, i)
		count = count + 1
	return count
