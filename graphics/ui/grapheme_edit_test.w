# wbuild: name=graphics_ui_grapheme_edit_test arch_only=x64
import lib.testing
import graphics.ui.widgets


void test_textbox_insert_absorbs_following_mark():
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"\xcc\x81")
	st.caret = 0
	ui_textbox_insert(&st, 'a')
	assert_equal(3, st.caret)
	assert_equal(3, st.length)
	ui_textbox_backspace(&st)
	assert_equal(0, st.length)
	assert_equal(0, st.caret)


void test_textbox_delete_joins_regional_indicators():
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"\xf0\x9f\x87\xbaa\xf0\x9f\x87\xb8")
	st.caret = 5
	ui_textbox_backspace(&st)
	assert_equal(8, st.length)
	assert_equal(0, st.caret)
	assert_equal(8, ui_grapheme_next(&st.text[0], st.caret))


void test_textarea_insert_absorbs_following_mark():
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"\xcc\x81")
	ui_textarea_type(&st, 'a')
	assert_equal(3, ui_textarea_caret_offset(&st))
	assert_equal(3, st.caret_goal_col)
	ui_textarea_backspace(&st)
	assert_equal(0, st.buf.length)
	ui_textarea_free(&st)


void test_textarea_delete_and_selection_join_clusters():
	ui_textarea_state st
	ui_textarea_init(&st)
	char* text = c"\xf0\x9f\x87\xbaa\xf0\x9f\x87\xb8"
	ui_textarea_set(&st, text)
	ui_textarea_set_caret(&st, 4)
	ui_textarea_nav(&st, GFX_NAV_DELETE, 0, 1)
	assert_equal(8, st.buf.length)
	assert_equal(0, ui_textarea_caret_offset(&st))
	ui_textarea_set(&st, text)
	ui_textarea_set_caret(&st, 5)
	ui_textarea_backspace(&st)
	assert_equal(0, ui_textarea_caret_offset(&st))
	ui_textarea_set(&st, text)
	st.sel_anchor = 4
	ui_textarea_set_caret(&st, 5)
	assert_equal(1, ui_textarea_delete_selection(&st))
	assert_equal(0, ui_textarea_caret_offset(&st))
	assert_equal(0 - 1, st.sel_anchor)
	ui_textarea_free(&st)


void test_selection_replacement_preserves_insertion_location():
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"\xf0\x9f\x87\xbaa\xf0\x9f\x87\xb8")
	st.sel_anchor = 4
	ui_textarea_set_caret(&st, 5)
	ui_textarea_type(&st, 'x')
	assert_equal(9, st.buf.length)
	assert_equal('x', st.buf.data[4])
	assert_equal(5, ui_textarea_caret_offset(&st))
	assert_equal(0 - 1, st.sel_anchor)
	ui_textarea_free(&st)
