# Shared multi-line label layout for the graph families.
#
# A label is either plain text or a Mermaid markdown string: the quoted
# text's first and last characters are backticks ("`...`"). Both accept
# explicit `<br>`, `<br/>` and `<br />` breaks (any letter case). Markdown
# strings additionally break at real newlines and style `**bold**`,
# `*italic*` and `_italic_` runs; in plain labels those markers are literal
# text, as upstream. Whitespace runs collapse to one space, as HTML labels
# do. Lines then wrap greedily at spaces so no line is wider than the
# requested maximum; a single word wider than the maximum stays whole on its
# own line. The source text is never modified: the block only owns copies.
import libs.extras.mermaid.scene

const int MM_TEXT_WRAP = 200

struct mm_text_run:
	char* text
	int style
	int line
	int x
	int width

struct mm_text_block:
	list[mm_text_run*] runs
	list[int] line_widths
	int width
	int height

# Tokens are unbroken text pieces (kind 0), spaces (1) and line breaks (2).
struct mm_text_token:
	int kind
	int start
	int end
	int style

int mm_text_is_markdown(char* label):
	int n = strlen(label)
	return n >= 2 && label[0] == '`' && label[n - 1] == '`'

# Length of a `<br>`, `<br/>` or `<br />` tag at text[i], else 0.
int mm_text_break_tag(char* text, int i, int end):
	if (i + 3 >= end || text[i] != '<'): return 0
	if (text[i + 1] != 'b' && text[i + 1] != 'B'): return 0
	if (text[i + 2] != 'r' && text[i + 2] != 'R'): return 0
	int j = i + 3
	while (j < end && text[j] == ' '): j = j + 1
	if (j < end && text[j] == '/'): j = j + 1
	if (j < end && text[j] == '>'): return j + 1 - i
	return 0

int mm_text_word_char(int c):
	return isalnum(c) || c >= 128

# A closing marker for an emphasis opened at i exists later on this line.
int mm_text_closes(char* text, int i, int end, char* marker):
	int n = strlen(marker)
	int j = i + n
	if (j >= end || text[j] == ' ' || text[j] == 10): return 0
	j = j + 1
	while (j + n <= end && text[j] != 10):
		int match = 1
		for k in range(n):
			if (text[j + k] != marker[k]): match = 0
		if (match && text[j - 1] != ' '):
			if (marker[0] != '_' || j + 1 >= end || mm_text_word_char(text[j + 1] & 255) == 0): return 1
		j = j + 1
	return 0

void mm_text_token_push(list[mm_text_token*] tokens, int kind, int start, int end, int style):
	if (kind == 0 && start >= end): return
	if (kind == 1 && tokens.length > 0 && tokens[tokens.length - 1].kind == 1): return
	mm_text_token* t = new mm_text_token()
	t.kind = kind
	t.start = start
	t.end = end
	t.style = style
	tokens.push(t)

list[mm_text_token*] mm_text_tokens(char* text, int start, int end, int markdown):
	list[mm_text_token*] tokens = new list[mm_text_token*]
	int style = 0
	int italic_marker = 0
	int piece = start
	int i = start
	while (i < end):
		int c = text[i] & 255
		int skip = 0
		int kind = -1
		int toggle = 0
		int tag = mm_text_break_tag(text, i, end)
		if (tag):
			skip = tag
			kind = 2
		else if (c == 10 && markdown):
			skip = 1
			kind = 2
		else if (c == ' ' || c == 9 || c == 10 || c == 13):
			skip = 1
			kind = 1
		else if (markdown && c == '*' && i + 1 < end && text[i + 1] == '*'):
			if ((style & MM_TEXT_BOLD) || mm_text_closes(text, i, end, c"**")):
				skip = 2
				toggle = MM_TEXT_BOLD
		else if (markdown && (c == '*' || c == '_')):
			if (style & MM_TEXT_ITALIC):
				if (italic_marker == c && (c == '*' || i + 1 >= end || mm_text_word_char(text[i + 1] & 255) == 0)):
					skip = 1
					toggle = MM_TEXT_ITALIC
			else:
				int opens = 0
				if (c == '*'): opens = mm_text_closes(text, i, end, c"*")
				else if (i == start || mm_text_word_char(text[i - 1] & 255) == 0): opens = mm_text_closes(text, i, end, c"_")
				if (opens):
					skip = 1
					toggle = MM_TEXT_ITALIC
					italic_marker = c
		if (skip == 0):
			i = i + 1
			continue
		mm_text_token_push(tokens, 0, piece, i, style)
		if (kind == 1 || kind == 2): mm_text_token_push(tokens, kind, i, i, style)
		style = style ^ toggle
		# A line break ends any emphasis that never closed on its line.
		if (kind == 2): style = 0
		i = i + skip
		piece = i
	mm_text_token_push(tokens, 0, piece, end, style)
	return tokens

void mm_text_run_add(mm_text_block* b, string_builder* text, int style, int line, int x):
	if (text.length == 0):
		string_free(text)
		return
	mm_text_run* r = new mm_text_run()
	r.text = strclone(text.data)
	r.style = style
	r.line = line
	r.x = x
	r.width = mm_text_width(r.text, style)
	b.runs.push(r)
	string_free(text)

# Lay out label; max_width <= 0 disables automatic wrapping.
mm_text_block* mm_text_layout(char* label, int max_width):
	mm_text_block* b = new mm_text_block()
	b.runs = new list[mm_text_run*]
	b.line_widths = new list[int]
	if (label == 0): label = c""
	int start = 0
	int end = strlen(label)
	int markdown = mm_text_is_markdown(label)
	if (markdown):
		start = 1
		end = end - 1
	list[mm_text_token*] tokens = mm_text_tokens(label, start, end, markdown)
	int line = 0
	int line_width = 0
	int pending_space = 0
	string_builder* run = string_new()
	int run_style = 0
	int run_x = 0
	int i = 0
	while (i <= tokens.length):
		if (i == tokens.length || tokens[i].kind == 2):
			mm_text_run_add(b, run, run_style, line, run_x)
			run = string_new()
			b.line_widths.push(line_width)
			if (i == tokens.length): break
			line = line + 1
			line_width = 0
			pending_space = 0
			i = i + 1
			continue
		mm_text_token* t = tokens[i]
		if (t.kind == 1):
			if (line_width > 0): pending_space = 1
			i = i + 1
			continue
		# Measure the whole word: consecutive pieces with no space between.
		int j = i
		int word = 0
		while (j < tokens.length && tokens[j].kind == 0):
			word = word + mm_text_width_range(label, tokens[j].start, tokens[j].end, tokens[j].style)
			j = j + 1
		int space = 0
		if (pending_space): space = mm_text_codepoint_width(' ', t.style)
		if (max_width > 0 && line_width > 0 && line_width + space + word > max_width):
			mm_text_run_add(b, run, run_style, line, run_x)
			run = string_new()
			b.line_widths.push(line_width)
			line = line + 1
			line_width = 0
			space = 0
		pending_space = 0
		for k in range(i, j):
			mm_text_token* piece = tokens[k]
			if (run.length > 0 && piece.style != run_style):
				mm_text_run_add(b, run, run_style, line, run_x)
				run = string_new()
			if (run.length == 0):
				run_style = piece.style
				run_x = line_width
			if (space):
				if (run.length > 0): string_append_char(run, ' ')
				else: run_x = run_x + space
				line_width = line_width + space
				space = 0
			for c in range(piece.start, piece.end): string_append_char(run, label[c])
			line_width = line_width + mm_text_width_range(label, piece.start, piece.end, piece.style)
		i = j
	string_free(run)
	for mm_text_token* t in tokens: free(t)
	__w_list_free(cast(__w_list*, tokens))
	for int w in b.line_widths:
		if (w > b.width): b.width = w
	b.height = b.line_widths.length * MM_TEXT_PITCH - (MM_TEXT_PITCH - MM_TEXT_LINE)
	return b

int mm_text_lines(mm_text_block* b):
	return b.line_widths.length

void mm_text_block_free(mm_text_block* b):
	if (b == 0): return
	for mm_text_run* r in b.runs:
		free(r.text)
		free(r)
	__w_list_free(cast(__w_list*, b.runs))
	__w_list_free(cast(__w_list*, b.line_widths))
	free(b)

# Emit one MM_TEXT primitive per styled run. x is the block's left edge, or
# its horizontal center when centered is set (each line centers on its own).
void mm_text_draw(mm_scene* s, mm_text_block* b, int x, int y, int centered):
	for mm_text_run* r in b.runs:
		int left = x
		if (centered): left = x - b.line_widths[r.line] / 2
		mm_text_styled(s, left + r.x, y + r.line * MM_TEXT_PITCH, r.text, r.style)

# Lay out, draw and free in one step; returns the block height drawn.
int mm_label(mm_scene* s, int x, int y, char* label, int max_width, int centered):
	mm_text_block* b = mm_text_layout(label, max_width)
	mm_text_draw(s, b, x, y, centered)
	int height = b.height
	mm_text_block_free(b)
	return height
