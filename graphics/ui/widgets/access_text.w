/*
graphics.ui.widgets.access_text: what the text widgets publish about
their text to the accessibility snapshot beyond its value and caret
(#863): one box per character from the layout they drew (glyph
geometry for magnifiers, braille panning and caret tracking) and the
text attributes (font family, size, weight, slant, colours) the field
draws in. ui_textbox_access_layout and ui_textarea_access_layout call
these after they set the node's value.
*/
import lib.lib
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.text
import graphics.ui.accessibility
import graphics.ui.accessibility_text
import graphics.ui.widgets.state


# Past this many characters a field publishes no glyph boxes (the
# bridges fall back to its bounds): a box per character costs a prefix
# width per character every frame.
const int ui_access_text_max_boxes = 8192


# The boxes of the characters (code points) of text[0..length), drawn
# in strike scale from (x, y) on a line h tall, into out[0..]: each
# spans its advance; one past clip_right is a zero-width box at
# clip_right (not drawn). Returns the count written.
int ui_access_line_boxes(char* text, int length, int scale, float32 x, float32 y, float32 h, float32 clip_right, ui_rect* out):
	int count = 0
	int i = 0
	int cp = 0
	int from = 0
	while (i < length):
		int next = ui_utf8_next(text, i, &cp)
		if (next > length): next = length
		int to = ui_text_prefix_width(text, next, scale)
		float32 x0 = x + cast(float32, from)
		float32 x1 = x + cast(float32, to)
		if (x0 > clip_right): x0 = clip_right
		if (x1 > clip_right): x1 = clip_right
		out[count] = ui_rect_new(x0, y, x1 - x0, h)
		count = count + 1
		from = to
		i = next
	return count


# The field's default text attributes: the strike's face (the embedded
# Liberation Sans faces name their family, weight and slant), its size
# in points (pixels * 3 / 4 at 96 dpi) and the colours.
void ui_access_field_attrs(ui_context* ctx, ui_access_node* node, int scale, ui_color fg, ui_color bg):
	ui_access_text_attrs* a = ui_access_default_attrs(ctx.access, node.id)
	if (a == 0): return
	int strike = ui_font_strike_from_scale(scale)
	int face = ui_font_strike_face(strike)
	if ((face >= 0) && (face <= 3)): ui_access_attrs_set_family(a, c"Liberation Sans", 15)
	a.size = (ui_font_strike_ppem(strike) * 3 + 2) / 4
	a.weight = 400
	if ((face == 1) || (face == 3)): a.weight = 700
	a.italic = (face == 2) || (face == 3)
	a.fg = ui_access_rgb(fg.r, fg.g, fg.b)
	a.bg = ui_access_rgb(bg.r, bg.g, bg.b)


# Publish boxes (count of them) for node, freeing them; skipped when
# they do not match the value it set.
void ui_access_publish_boxes(ui_context* ctx, ui_access_node* node, ui_rect* boxes, int count):
	ui_access_set_char_boxes(ctx.access, node.id, boxes, count)
	free(cast(char*, boxes))


# Publish the IME composition field node shows (#912) into its value,
# as the screen shows it: call it once ui_text_preedit_showing, after
# the field's value, caret and layout. The preview goes in at caret_byte
# with boxes drawn from (x, y) on a line h tall, the caret and the
# conversion target from the preedit state (the clause at
# preedit_selection, preedit_target_length long; with none the caret
# sits at preedit_selection).
void ui_access_publish_preedit(ui_context* ctx, ui_access_node* node, int caret_byte, float32 x, float32 y, float32 h):
	if ((node == 0) || (ctx.access == 0) || (ctx.preedit_length <= 0)): return
	int at = ui_access_byte_char(node.value.data, node.value.length, caret_byte)
	int chars = ui_access_char_count(&ctx.preedit[0], ctx.preedit_length)
	ui_rect* boxes = cast(ui_rect*, malloc((ctx.preedit_length + 1) * sizeof(ui_rect)))
	int count = ui_access_line_boxes(&ctx.preedit[0], ctx.preedit_length, ctx.theme.text_scale, x, y, h, 1000000.0, boxes)
	int target = ctx.preedit_selection
	if ((target < 0) || (target > chars)): target = chars
	int target_length = ctx.preedit_target_length
	if ((target_length < 0) || (target + target_length > chars)): target_length = 0
	int caret = target + target_length
	ui_rect* given = boxes
	if (count != chars): given = 0
	ui_access_insert_composition(ctx.access, node.id, at, &ctx.preedit[0], ctx.preedit_length, given, caret, target, target_length)
	free(cast(char*, boxes))
