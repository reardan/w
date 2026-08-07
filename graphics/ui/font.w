/*
graphics.ui.font: builds the runtime glyph atlas from the baked
font_data tables and measures text (docs/projects/ui_framework.md §6,
stage-1 bitmap placeholder — issue #379 tracks real typography).

The atlas is a single-channel 128x48 buffer: 16x6 cells of 8x8. Cells
0..94 hold ASCII 32..126 expanded from 1bpp to 0/255 coverage bytes;
cell 95 is solid white, so untextured fills draw through the same
shader by sampling its center. Pure CPU code — the GL upload lives in
graphics.ui.render.
*/
import lib.lib
import graphics.ui.font_data


int ui_font_atlas_w():
	return 128


int ui_font_atlas_h():
	return 48


int ui_font_atlas_cols():
	return 16


# Cell index of the solid-white cell (untextured fills sample here).
int ui_font_white_cell():
	return 95


# Build the atlas pixel buffer (ui_font_atlas_w x ui_font_atlas_h
# bytes, one coverage byte per pixel). Caller frees.
char* ui_font_build_atlas():
	int width = ui_font_atlas_w()
	int total = width * ui_font_atlas_h()
	char* pixels = malloc(total)
	int i = 0
	while (i < total):
		pixels[i] = 0
		i = i + 1

	int cell = 0
	while (cell < ui_font_char_count()):
		char* rows = ui_font_glyph_bits(ui_font_first_char() + cell)
		int cell_x = (cell % ui_font_atlas_cols()) * 8
		int cell_y = (cell / ui_font_atlas_cols()) * 8
		int row = 0
		while (row < 8):
			# bit 0 is the leftmost column (tools/ui/font8x8.txt).
			int bits = rows[row] & 255
			int col = 0
			while (col < 8):
				if ((bits >> col) & 1):
					pixels[(cell_y + row) * width + cell_x + col] = 255
				col = col + 1
			row = row + 1
		cell = cell + 1

	int white_x = (ui_font_white_cell() % ui_font_atlas_cols()) * 8
	int white_y = (ui_font_white_cell() / ui_font_atlas_cols()) * 8
	int row2 = 0
	while (row2 < 8):
		int col2 = 0
		while (col2 < 8):
			pixels[(white_y + row2) * width + white_x + col2] = 255
			col2 = col2 + 1
		row2 = row2 + 1
	return pixels


# Pixel width of a string drawn at the given integer scale (monospace:
# every glyph advances 8 * scale).
int ui_text_width(char* s, int scale):
	return strlen(s) * 8 * scale


int ui_text_height(int scale):
	return 8 * scale
