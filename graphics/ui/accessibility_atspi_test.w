# The AT-SPI bridge on a private dbus-daemon: a client connection plays
# the registry (answering Embed and numbering the application) and the
# screen reader (walking the tree, reading names, states, text and
# geometry, invoking actions and receiving events), while the bridge is
# pumped the way an application's frame loop pumps it. Skipped when
# dbus-daemon is not installed.
# wbuild: name=graphics_ui_accessibility_atspi_test x64
import lib.testing
import lib.ci_skip
import lib.str
import lib.dbus
import lib.dbus_test_bus
import graphics.ui.accessibility
import graphics.ui.accessibility_atspi


struct atspi_test_app:
	ui_access_tree* tree
	int calls
	int last_id
	int last_action
	char[64] last_value
	int last_length


int atspi_test_action(void* context, int id, int action, char* data, int length):
	atspi_test_app* app = cast(atspi_test_app*, context)
	app.calls = app.calls + 1
	app.last_id = id
	app.last_action = action
	app.last_length = length
	for i in range(length): app.last_value[i] = data[i]
	app.last_value[length] = 0
	return 1


# A dialog-free settings window: heading, a checkbox, a textbox, a
# progress bar and a two-item list.
ui_access_tree* atspi_test_tree(atspi_test_app* app, int checked, char* name):
	ui_access_tree* tree = ui_access_tree_new(32, 512)
	ui_rect r = ui_rect_new(10.0, 20.0, 300.0, 200.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_set_text(tree, 1, UI_ACCESS_NAME, c"Settings", 8)
	ui_access_node* h = ui_access_add(tree, 2, 1, UI_ACCESS_HEADING, ui_rect_new(10.0, 20.0, 300.0, 30.0))
	h.heading_level = 2
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"General", 7)
	ui_access_node* box = ui_access_add(tree, 3, 1, UI_ACCESS_CHECKBOX, ui_rect_new(10.0, 60.0, 100.0, 20.0))
	box.states = UI_ACCESS_FOCUSABLE
	if checked: box.states = box.states | UI_ACCESS_CHECKED
	box.actions = UI_ACCESS_TOGGLE | UI_ACCESS_FOCUS
	ui_access_set_text(tree, 3, UI_ACCESS_NAME, name, strlen(name))
	ui_access_node* entry = ui_access_add(tree, 4, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 90.0, 200.0, 24.0))
	entry.states = UI_ACCESS_FOCUSABLE
	entry.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_FOCUS
	ui_access_set_text(tree, 4, UI_ACCESS_NAME, c"City", 4)
	ui_access_set_text(tree, 4, UI_ACCESS_VALUE, c"Z\xc3\xbcrich", 7)
	ui_access_add(tree, 5, 1, UI_ACCESS_PROGRESS, ui_rect_new(10.0, 120.0, 200.0, 10.0))
	ui_access_set_text(tree, 5, UI_ACCESS_VALUE, c"40%", 3)
	ui_access_add(tree, 6, 1, UI_ACCESS_LIST, ui_rect_new(10.0, 140.0, 200.0, 40.0))
	ui_access_node* a = ui_access_add(tree, 7, 6, UI_ACCESS_LIST_ITEM, ui_rect_new(10.0, 140.0, 200.0, 20.0))
	a.states = UI_ACCESS_SELECTED
	a.actions = UI_ACCESS_ACTIVATE
	ui_access_set_text(tree, 7, UI_ACCESS_NAME, c"North", 5)
	ui_access_add(tree, 8, 6, UI_ACCESS_LIST_ITEM, ui_rect_new(10.0, 160.0, 200.0, 20.0))
	ui_access_set_text(tree, 8, UI_ACCESS_NAME, c"South", 5)
	tree.focused_id = 4
	tree.action = atspi_test_action
	tree.context = app
	return tree


# Everything the client heard besides replies: "Member kind path\n".
struct atspi_test_client:
	dbus_conn* conn
	char[8192] log
	int log_length
	int embeds


void atspi_test_log(atspi_test_client* c, char* s):
	int n = strlen(s)
	if (c.log_length + n + 1 >= 8192): return
	for i in range(n): c.log[c.log_length + i] = s[i]
	c.log_length = c.log_length + n
	c.log[c.log_length] = 0


# Answer the bridge's Embed the way at-spi2-registryd does, then number
# the application through Properties.Set.
void atspi_test_registry(atspi_test_client* c, dbus_message* m):
	if (strcmp(m.member, c"Embed") != 0): return
	c.embeds = c.embeds + 1
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_struct(out)
	dbus_put_string(out, c.conn.unique_name)
	dbus_put_path(out, c"/org/a11y/atspi/accessible/root")
	dbus_reply(c.conn, m, c"(so)")
	out = dbus_body(c.conn)
	dbus_put_string(out, c"org.a11y.atspi.Application")
	dbus_put_string(out, c"Id")
	dbus_put_sig(out, c"i")
	dbus_put_i32(out, 7)
	dbus_call(c.conn, m.sender, c"/org/a11y/atspi/accessible/root", c"org.freedesktop.DBus.Properties", c"Set", c"ssv")


# Pump the bridge and the client until the reply to serial arrives.
# Returns 1 (reply), -1 (error reply, also filled) or 0 (timeout).
int atspi_test_pump(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int serial, dbus_message* reply):
	dbus_message_init(reply)
	for i in range(1000):
		ui_access_atspi_dispatch(b, tree)
		dbus_message m
		if (dbus_wait(c.conn, &m, 10) == 1):
			if (((m.type == DBUS_METHOD_RETURN) || (m.type == DBUS_ERROR)) && (m.reply_serial == serial) && (serial != 0)):
				reply[0] = m
				if (m.type == DBUS_ERROR): return 0 - 1
				return 1
			if (m.type == DBUS_METHOD_CALL): atspi_test_registry(c, &m)
			if ((m.type == DBUS_SIGNAL) && (strcmp(m.interface, c"org.freedesktop.DBus") != 0)):
				dbus_reader r
				dbus_message_reader(&m, &r)
				atspi_test_log(c, m.member)
				atspi_test_log(c, c" ")
				if (strcmp(m.member, c"Announcement") == 0):
					# "Announcement <politeness> <text> <path>"
					dbus_read_string(&r, 0)
					char[2] live
					live[0] = '0' + dbus_read_i32(&r)
					live[1] = 0
					dbus_read_i32(&r)
					atspi_test_log(c, &live[0])
					atspi_test_log(c, c" ")
					dbus_read_sig(&r)
					atspi_test_log(c, dbus_read_string(&r, 0))
				else if (starts_with(m.signature, c"s")): atspi_test_log(c, dbus_read_string(&r, 0))
				if (starts_with(m.signature, c"(")):
					dbus_read_align(&r, 8)
					dbus_read_string(&r, 0)
					atspi_test_log(c, dbus_read_string(&r, 0))
				atspi_test_log(c, c" ")
				atspi_test_log(c, m.path)
				atspi_test_log(c, c"\n")
			dbus_message_free(&m)
	return 0


char* atspi_test_path(int id):
	if (id == 0): return c"/org/a11y/atspi/accessible/root"
	char* out = cast(char*, malloc(64))
	return ui_atspi_node_path(out, id)


# Call iface.member on node id with the body already in c.conn's buffer.
int atspi_test_call(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* iface, char* member, char* sig, dbus_message* reply):
	int serial = dbus_call(c.conn, b.bus.unique_name, atspi_test_path(id), iface, member, sig)
	return atspi_test_pump(c, b, tree, serial, reply)


char* atspi_test_property_string(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* iface, char* prop):
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, iface)
	dbus_put_string(out, prop)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, c"org.freedesktop.DBus.Properties", c"Get", c"ss", &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"s", dbus_read_sig(&r))
	char* s = dbus_strdup(dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	return s


int atspi_test_u32(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* iface, char* member):
	dbus_body(c.conn)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, iface, member, 0, &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	int v = dbus_read_u32(&r)
	dbus_message_free(&reply)
	return v


# The two state words of node id.
void atspi_test_state(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, int* lo, int* hi):
	dbus_body(c.conn)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, c"org.a11y.atspi.Accessible", c"GetState", 0, &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	assert_equal(8, dbus_read_u32(&r))
	lo[0] = dbus_read_u32(&r)
	hi[0] = dbus_read_u32(&r)
	dbus_message_free(&reply)


int atspi_test_has(int word, int bit):
	return (word & (1 << bit)) != 0


int atspi_test_bool(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* iface, char* member, char* sig):
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, iface, member, sig, &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	int v = dbus_read_bool(&r)
	dbus_message_free(&reply)
	return v


void check_bridge(char* address):
	atspi_test_client client
	client.log_length = 0
	client.log[0] = 0
	client.embeds = 0
	client.conn = dbus_open(address)
	asserts(c"client connects", client.conn != 0)
	atspi_test_client* c = &client
	# Own the registry's name before the application starts.
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, c"org.a11y.atspi.Registry")
	dbus_put_u32(out, 4)
	dbus_message reply
	assert_equal(1, dbus_call_sync(c.conn, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"RequestName", c"su"))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_string(out, c"type='signal',interface='org.a11y.atspi.Event.Object'")
	assert_equal(1, dbus_call_sync(c.conn, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"AddMatch", c"s"))
	dbus_message_free(&reply)

	atspi_test_app app
	app.calls = 0
	ui_access_tree* tree = atspi_test_tree(&app, 0, c"Wi-Fi")
	ui_atspi_bridge* b = ui_access_atspi_open_at(address, c"W settings")
	asserts(c"bridge connects", b != 0)
	ui_access_atspi_set_origin(b, 100, 50)
	assert_equal(1, ui_access_atspi_publish(b, tree))

	# Registration: the first Ping's reply follows the bridge's Embed
	# call, which the client answers (with the Id Set) while waiting;
	# the second Ping follows that answer, so both have landed after it.
	for k in range(2):
		dbus_body(c.conn)
		assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
		dbus_message_free(&reply)
	assert_equal(1, c.embeds)
	asserts(c"embedded", ui_access_atspi_embedded(b))
	assert_equal(7, b.app_id)
	asserts(c"window announced", contains(&c.log[0], c"ChildrenChanged add /org/a11y/atspi/accessible/root"))

	# The application root: name, role, the window as its only child.
	char* name = atspi_test_property_string(c, b, tree, 0, c"org.a11y.atspi.Accessible", c"Name")
	assert_strings_equal(c"W settings", name)
	free(name)
	assert_equal(ATSPI_ROLE_APPLICATION, atspi_test_u32(c, b, tree, 0, c"org.a11y.atspi.Accessible", c"GetRole"))
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.a11y.atspi.Accessible", c"GetChildren", 0, &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	dbus_read_u32(&r)
	dbus_read_align(&r, 8)
	assert_strings_equal(b.bus.unique_name, dbus_read_string(&r, 0))
	assert_strings_equal(c"/org/a11y/atspi/accessible/1", dbus_read_string(&r, 0))
	assert_equal(0, r.failed)
	dbus_message_free(&reply)

	# The window and its controls.
	assert_equal(ATSPI_ROLE_FRAME, atspi_test_u32(c, b, tree, 1, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(ATSPI_ROLE_HEADING, atspi_test_u32(c, b, tree, 2, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(ATSPI_ROLE_CHECK_BOX, atspi_test_u32(c, b, tree, 3, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(ATSPI_ROLE_ENTRY, atspi_test_u32(c, b, tree, 4, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(ATSPI_ROLE_PROGRESS_BAR, atspi_test_u32(c, b, tree, 5, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(ATSPI_ROLE_LIST_ITEM, atspi_test_u32(c, b, tree, 7, c"org.a11y.atspi.Accessible", c"GetRole"))
	name = atspi_test_property_string(c, b, tree, 3, c"org.a11y.atspi.Accessible", c"Name")
	assert_strings_equal(c"Wi-Fi", name)
	free(name)
	int lo = 0
	int hi = 0
	atspi_test_state(c, b, tree, 3, &lo, &hi)
	asserts(c"checkbox focusable", atspi_test_has(lo, ATSPI_STATE_FOCUSABLE))
	asserts(c"checkbox unchecked", !atspi_test_has(lo, ATSPI_STATE_CHECKED))
	asserts(c"checkbox checkable", atspi_test_has(hi, ATSPI_STATE_CHECKABLE - 32))
	atspi_test_state(c, b, tree, 4, &lo, &hi)
	asserts(c"entry focused", atspi_test_has(lo, ATSPI_STATE_FOCUSED))
	asserts(c"entry editable", atspi_test_has(lo, ATSPI_STATE_EDITABLE))
	atspi_test_state(c, b, tree, 7, &lo, &hi)
	asserts(c"item selected", atspi_test_has(lo, ATSPI_STATE_SELECTED))

	# libatspi's cache preload gets an empty, well-formed answer.
	dbus_body(c.conn)
	int serial = dbus_call(c.conn, b.bus.unique_name, c"/org/a11y/atspi/cache", c"org.a11y.atspi.Cache", c"GetItems", 0)
	assert_equal(1, atspi_test_pump(c, b, tree, serial, &reply))
	assert_strings_equal(c"a((so)(so)(so)iiassusau)", reply.signature)
	dbus_message_free(&reply)

	# Unknown objects and members are errors, not silence.
	dbus_body(c.conn)
	assert_equal(0 - 1, atspi_test_call(c, b, tree, 99, c"org.a11y.atspi.Accessible", c"GetRole", 0, &reply))
	dbus_message_free(&reply)
	dbus_body(c.conn)
	assert_equal(0 - 1, atspi_test_call(c, b, tree, 3, c"org.a11y.atspi.Accessible", c"Frobnicate", 0, &reply))
	dbus_message_free(&reply)

	# Geometry: window coordinates plus the origin in screen space.
	out = dbus_body(c.conn)
	dbus_put_u32(out, 0)
	assert_equal(1, atspi_test_call(c, b, tree, 3, c"org.a11y.atspi.Component", c"GetExtents", c"u", &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(110, dbus_read_i32(&r))
	assert_equal(110, dbus_read_i32(&r))
	assert_equal(100, dbus_read_i32(&r))
	assert_equal(20, dbus_read_i32(&r))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 115)
	dbus_put_i32(out, 145)
	dbus_put_u32(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 1, c"org.a11y.atspi.Component", c"GetAccessibleAtPoint", c"iiu", &reply))
	dbus_message_reader(&reply, &r)
	dbus_read_string(&r, 0)
	assert_strings_equal(c"/org/a11y/atspi/accessible/7", dbus_read_string(&r, 0))
	dbus_message_free(&reply)

	# Text counts characters, not bytes.
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	dbus_put_i32(out, 0 - 1)
	assert_equal(1, atspi_test_call(c, b, tree, 4, c"org.a11y.atspi.Text", c"GetText", c"ii", &reply))
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"\xc3\xbcrich", dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 4, c"org.a11y.atspi.Text", c"GetCharacterAtOffset", c"i", &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(252, dbus_read_i32(&r))
	dbus_message_free(&reply)

	# Actions are applied through the application's callback.
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	asserts(c"toggle accepted", atspi_test_bool(c, b, tree, 3, c"org.a11y.atspi.Action", c"DoAction", c"i"))
	assert_equal(1, app.calls)
	assert_equal(3, app.last_id)
	assert_equal(UI_ACCESS_TOGGLE, app.last_action)
	dbus_body(c.conn)
	asserts(c"focus accepted", atspi_test_bool(c, b, tree, 3, c"org.a11y.atspi.Component", c"GrabFocus", 0))
	assert_equal(UI_ACCESS_FOCUS, app.last_action)
	assert_equal(3, tree.focused_id)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_string(out, c"Bern ")
	dbus_put_i32(out, 5)
	asserts(c"insert accepted", atspi_test_bool(c, b, tree, 4, c"org.a11y.atspi.EditableText", c"InsertText", c"isi"))
	assert_equal(UI_ACCESS_SET_VALUE, app.last_action)
	assert_strings_equal(c"Bern Z\xc3\xbcrich", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	dbus_put_i32(out, 2)
	asserts(c"delete accepted", atspi_test_bool(c, b, tree, 4, c"org.a11y.atspi.EditableText", c"DeleteText", c"ii"))
	assert_strings_equal(c"Zrich", &app.last_value[0])
	# A heading does not implement Action; a list item without the
	# action refuses it.
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	assert_equal(0 - 1, atspi_test_call(c, b, tree, 2, c"org.a11y.atspi.Action", c"DoAction", c"i", &reply))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	asserts(c"no second action", !atspi_test_bool(c, b, tree, 7, c"org.a11y.atspi.Action", c"DoAction", c"i"))
	assert_equal(4, app.calls)

	# A new snapshot announces what changed.
	ui_access_tree* next = atspi_test_tree(&app, 1, c"Wireless")
	next.focused_id = 3
	ui_access_set_text(next, 4, UI_ACCESS_VALUE, c"Bern", 4)
	ui_access_atspi_publish(b, next)
	ui_access_tree_free(tree)
	tree = next
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	asserts(c"checked event", contains(&c.log[0], c"StateChanged checked /org/a11y/atspi/accessible/3"))
	asserts(c"name event", contains(&c.log[0], c"PropertyChange accessible-name /org/a11y/atspi/accessible/3"))
	asserts(c"focus event", contains(&c.log[0], c"StateChanged focused /org/a11y/atspi/accessible/3"))
	asserts(c"text event", contains(&c.log[0], c"TextChanged insert /org/a11y/atspi/accessible/4"))
	atspi_test_state(c, b, tree, 3, &lo, &hi)
	asserts(c"now checked", atspi_test_has(lo, ATSPI_STATE_CHECKED))

	ui_access_atspi_close(b)
	ui_access_tree_free(tree)
	dbus_close(c.conn)


# A file table (header row, two data rows, the first selected), a tab
# list and a list; with_extra swaps the second data row for a new one
# and clears the first row's selection.
ui_access_tree* tables_tree(atspi_test_app* app, int changed):
	ui_access_tree* tree = ui_access_tree_new(64, 1024)
	ui_rect r = ui_rect_new(0.0, 0.0, 300.0, 300.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_add(tree, 10, 1, UI_ACCESS_TABLE, r)
	ui_access_set_text(tree, 10, UI_ACCESS_NAME, c"Files", 5)
	ui_access_add(tree, 11, 10, UI_ACCESS_ROW, r)
	ui_access_add(tree, 12, 11, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 12, UI_ACCESS_NAME, c"Name", 4)
	ui_access_add(tree, 13, 11, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 13, UI_ACCESS_NAME, c"Size", 4)
	ui_access_node* row = ui_access_add(tree, 20, 10, UI_ACCESS_ROW, r)
	row.actions = UI_ACCESS_ACTIVATE
	if (changed == 0): row.states = UI_ACCESS_SELECTED
	ui_access_add(tree, 21, 20, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 21, UI_ACCESS_NAME, c"a.txt", 5)
	ui_access_add(tree, 22, 20, UI_ACCESS_CELL, r)
	if changed: ui_access_set_text(tree, 22, UI_ACCESS_NAME, c"4 KB", 4)
	else: ui_access_set_text(tree, 22, UI_ACCESS_NAME, c"3 KB", 4)
	int second = 30
	if changed: second = 60
	row = ui_access_add(tree, second, 10, UI_ACCESS_ROW, r)
	row.actions = UI_ACCESS_ACTIVATE
	ui_access_add(tree, second + 1, second, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, second + 1, UI_ACCESS_NAME, c"b.txt", 5)
	ui_access_add(tree, second + 2, second, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, second + 2, UI_ACCESS_NAME, c"9 KB", 4)
	ui_access_add(tree, 40, 1, UI_ACCESS_TAB_LIST, r)
	ui_access_node* tab = ui_access_add(tree, 41, 40, UI_ACCESS_TAB, r)
	tab.states = UI_ACCESS_SELECTED
	tab.actions = UI_ACCESS_ACTIVATE
	ui_access_set_text(tree, 41, UI_ACCESS_NAME, c"One", 3)
	tab = ui_access_add(tree, 42, 40, UI_ACCESS_TAB, r)
	tab.actions = UI_ACCESS_ACTIVATE
	ui_access_set_text(tree, 42, UI_ACCESS_NAME, c"Two", 3)
	tree.action = atspi_test_action
	tree.context = app
	return tree


int atspi_test_int_property(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* iface, char* prop):
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, iface)
	dbus_put_string(out, prop)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, c"org.freedesktop.DBus.Properties", c"Get", c"ss", &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"i", dbus_read_sig(&r))
	int v = dbus_read_i32(&r)
	dbus_message_free(&reply)
	return v


# iface.member(args) on id answering one i32.
int atspi_test_i32_ii(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* iface, char* member, int x, int y, int two):
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_i32(out, x)
	char* sig = c"i"
	if two:
		dbus_put_i32(out, y)
		sig = c"ii"
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, iface, member, sig, &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	int v = dbus_read_i32(&r)
	if (reply.signature[0] == 'b'):
		dbus_reader_init(&r, reply.body, reply.body_length)
		v = dbus_read_bool(&r)
	dbus_message_free(&reply)
	return v


# iface.member(args) on id answering one (so); its object path, copied.
char* atspi_test_ref_ii(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* iface, char* member, int x, int y, int two):
	dbus_buf* out = dbus_body(c.conn)
	char* sig = 0
	if (x >= 0):
		dbus_put_i32(out, x)
		sig = c"i"
	if two:
		dbus_put_i32(out, y)
		sig = c"ii"
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, iface, member, sig, &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	dbus_read_align(&r, 8)
	dbus_read_string(&r, 0)
	char* path = dbus_strdup(dbus_read_string(&r, 0))
	assert_equal(0, r.failed)
	dbus_message_free(&reply)
	return path


void check_tables(char* address):
	atspi_test_client client
	client.log_length = 0
	client.log[0] = 0
	client.embeds = 0
	client.conn = dbus_open(address)
	asserts(c"client connects", client.conn != 0)
	atspi_test_client* c = &client
	dbus_message reply
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, c"type='signal',interface='org.a11y.atspi.Event.Object'")
	assert_equal(1, dbus_call_sync(c.conn, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"AddMatch", c"s"))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_string(out, c"type='signal',interface='org.a11y.atspi.Cache'")
	assert_equal(1, dbus_call_sync(c.conn, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"AddMatch", c"s"))
	dbus_message_free(&reply)

	atspi_test_app app
	app.calls = 0
	ui_access_tree* tree = tables_tree(&app, 0)
	# No registry owns its name on this bus: Embed fails, which the
	# bridge tolerates.
	ui_atspi_bridge* b = ui_access_atspi_open_at(address, c"Files")
	asserts(c"bridge connects", b != 0)
	assert_equal(1, ui_access_atspi_publish(b, tree))
	char* table = c"org.a11y.atspi.Table"

	# Header cells are column headers; data cells are table cells.
	assert_equal(ATSPI_ROLE_TABLE_COLUMN_HEADER, atspi_test_u32(c, b, tree, 12, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(ATSPI_ROLE_TABLE_CELL, atspi_test_u32(c, b, tree, 21, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(2, atspi_test_int_property(c, b, tree, 10, table, c"NRows"))
	assert_equal(2, atspi_test_int_property(c, b, tree, 10, table, c"NColumns"))
	assert_equal(1, atspi_test_int_property(c, b, tree, 10, table, c"NSelectedRows"))
	char* path = atspi_test_ref_ii(c, b, tree, 10, table, c"GetAccessibleAt", 1, 0, 1)
	assert_strings_equal(c"/org/a11y/atspi/accessible/31", path)
	free(path)
	assert_equal(3, atspi_test_i32_ii(c, b, tree, 10, table, c"GetIndexAt", 1, 1, 1))
	assert_equal(1, atspi_test_i32_ii(c, b, tree, 10, table, c"GetRowAtIndex", 3, 0, 0))
	assert_equal(1, atspi_test_i32_ii(c, b, tree, 10, table, c"GetColumnAtIndex", 2, 0, 0) + 1)
	assert_equal(0 - 1, atspi_test_i32_ii(c, b, tree, 10, table, c"GetRowAtIndex", 4, 0, 0))
	path = atspi_test_ref_ii(c, b, tree, 10, table, c"GetColumnHeader", 1, 0, 0)
	assert_strings_equal(c"/org/a11y/atspi/accessible/13", path)
	free(path)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	assert_equal(1, atspi_test_call(c, b, tree, 10, table, c"GetColumnDescription", c"i", &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"Name", dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 10, table, c"GetSelectedRows", 0, &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(4, dbus_read_u32(&r))
	assert_equal(0, dbus_read_i32(&r))
	dbus_message_free(&reply)
	assert_equal(0, atspi_test_i32_ii(c, b, tree, 10, table, c"IsRowSelected", 1, 0, 0))

	# A data cell knows its place and its column header.
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 32, c"org.a11y.atspi.TableCell", c"GetRowColumnSpan", 0, &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(1, dbus_read_i32(&r))
	assert_equal(1, dbus_read_i32(&r))
	assert_equal(1, dbus_read_i32(&r))
	assert_equal(1, dbus_read_i32(&r))
	dbus_message_free(&reply)
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 32, c"org.a11y.atspi.TableCell", c"GetColumnHeaderCells", 0, &reply))
	dbus_message_reader(&reply, &r)
	dbus_read_u32(&r)
	dbus_read_align(&r, 8)
	dbus_read_string(&r, 0)
	assert_strings_equal(c"/org/a11y/atspi/accessible/13", dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	path = atspi_test_property_string(c, b, tree, 21, c"org.a11y.atspi.Accessible", c"Name")
	assert_strings_equal(c"a.txt", path)
	free(path)
	# Unnamed rows are named from their cells.
	path = atspi_test_property_string(c, b, tree, 20, c"org.a11y.atspi.Accessible", c"Name")
	assert_strings_equal(c"a.txt 3 KB", path)
	free(path)
	path = atspi_test_property_string(c, b, tree, 11, c"org.a11y.atspi.Accessible", c"Name")
	assert_strings_equal(c"Name Size", path)
	free(path)
	# Header cells are not TableCells.
	dbus_body(c.conn)
	assert_equal(0 - 1, atspi_test_call(c, b, tree, 12, c"org.a11y.atspi.TableCell", c"GetRowColumnSpan", 0, &reply))
	dbus_message_free(&reply)

	# Selecting a row or a tab activates it, as a click would.
	asserts(c"add row selection", atspi_test_i32_ii(c, b, tree, 10, table, c"AddRowSelection", 1, 0, 0))
	assert_equal(1, app.calls)
	assert_equal(30, app.last_id)
	assert_equal(UI_ACCESS_ACTIVATE, app.last_action)
	char* selection = c"org.a11y.atspi.Selection"
	assert_equal(1, atspi_test_int_property(c, b, tree, 40, selection, c"NSelectedChildren"))
	path = atspi_test_ref_ii(c, b, tree, 40, selection, c"GetSelectedChild", 0, 0, 0)
	assert_strings_equal(c"/org/a11y/atspi/accessible/41", path)
	free(path)
	assert_equal(0, atspi_test_i32_ii(c, b, tree, 40, selection, c"IsChildSelected", 1, 0, 0))
	asserts(c"select tab", atspi_test_i32_ii(c, b, tree, 40, selection, c"SelectChild", 1, 0, 0))
	assert_equal(42, app.last_id)
	# Already selected: nothing to do.
	asserts(c"select selected tab", atspi_test_i32_ii(c, b, tree, 40, selection, c"SelectChild", 0, 0, 0))
	assert_equal(2, app.calls)
	assert_equal(0, atspi_test_i32_ii(c, b, tree, 40, selection, c"DeselectChild", 0, 0, 0))
	# The table selects over rows; its header row (child 0) never is.
	assert_equal(0, atspi_test_i32_ii(c, b, tree, 10, selection, c"IsChildSelected", 0, 0, 0))
	assert_equal(1, atspi_test_i32_ii(c, b, tree, 10, selection, c"IsChildSelected", 1, 0, 0))

	# The cache preload lists the application and every node, parents
	# first.
	dbus_body(c.conn)
	int serial = dbus_call(c.conn, b.bus.unique_name, c"/org/a11y/atspi/cache", c"org.a11y.atspi.Cache", c"GetItems", 0)
	assert_equal(1, atspi_test_pump(c, b, tree, serial, &reply))
	dbus_message_reader(&reply, &r)
	int end = dbus_read_u32(&r)
	dbus_read_align(&r, 8)
	end = end + r.pos
	int items = 0
	while ((r.pos < end) && (r.failed == 0)):
		dbus_read_align(&r, 8)
		dbus_read_string(&r, 0)
		char* self = dbus_read_string(&r, 0)
		dbus_read_align(&r, 8)
		dbus_read_string(&r, 0)
		dbus_read_string(&r, 0)
		dbus_read_align(&r, 8)
		dbus_read_string(&r, 0)
		char* parent = dbus_read_string(&r, 0)
		int index = dbus_read_i32(&r)
		int children = dbus_read_u32(&r)
		dbus_skip(&r, c"as", 0)
		char* name = dbus_read_string(&r, 0)
		int role = dbus_read_u32(&r)
		dbus_read_string(&r, 0)
		dbus_skip(&r, c"au", 0)
		if (items == 0):
			assert_strings_equal(c"/org/a11y/atspi/accessible/root", self)
			assert_strings_equal(c"Files", name)
			assert_equal(ATSPI_ROLE_APPLICATION, role)
			assert_equal(1, children)
		if (strcmp(self, c"/org/a11y/atspi/accessible/13") == 0):
			assert_strings_equal(c"/org/a11y/atspi/accessible/11", parent)
			assert_equal(1, index)
			assert_equal(ATSPI_ROLE_TABLE_COLUMN_HEADER, role)
			assert_strings_equal(c"Size", name)
		if (strcmp(self, c"/org/a11y/atspi/accessible/10") == 0): assert_equal(3, children)
		items = items + 1
	assert_equal(0, r.failed)
	assert_equal(15, items)
	dbus_message_free(&reply)

	# Republishing adds and removes cache entries before the events
	# that mention them.
	ui_access_tree* next = tables_tree(&app, 1)
	ui_access_atspi_publish(b, next)
	ui_access_tree_free(tree)
	tree = next
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	char* log = &c.log[0]
	int added = index_of(log, c"AddAccessible /org/a11y/atspi/accessible/60 ")
	int announced = index_of(log, c"ChildrenChanged add /org/a11y/atspi/accessible/10")
	asserts(c"row cached", added >= 0)
	asserts(c"cell cached", contains(log, c"AddAccessible /org/a11y/atspi/accessible/61 "))
	asserts(c"cached before announced", (announced > added))
	asserts(c"old row uncached", contains(log, c"RemoveAccessible /org/a11y/atspi/accessible/30 "))
	asserts(c"old row defunct", contains(log, c"StateChanged defunct /org/a11y/atspi/accessible/30"))
	asserts(c"selection cleared", contains(log, c"StateChanged selected /org/a11y/atspi/accessible/20"))
	int changed = index_of(log, c"SelectionChanged  /org/a11y/atspi/accessible/10\n")
	asserts(c"table selection changed", changed > index_of(log, c"StateChanged selected /org/a11y/atspi/accessible/20"))
	asserts(c"tab selection unchanged", !contains(log, c"SelectionChanged  /org/a11y/atspi/accessible/40\n"))
	# A cell's new name renames its unnamed row, and the row says so.
	asserts(c"derived row name changed", contains(log, c"PropertyChange accessible-name /org/a11y/atspi/accessible/20\n"))
	asserts(c"other row unchanged", !contains(log, c"PropertyChange accessible-name /org/a11y/atspi/accessible/60\n"))
	path = atspi_test_property_string(c, b, tree, 20, c"org.a11y.atspi.Accessible", c"Name")
	assert_strings_equal(c"a.txt 4 KB", path)
	free(path)
	assert_equal(0, atspi_test_int_property(c, b, tree, 10, table, c"NSelectedRows"))

	ui_access_atspi_close(b)
	ui_access_tree_free(tree)
	dbus_close(c.conn)


# A window with a polite status line (live text), a button and, from
# the second snapshot, an assertive toast.
ui_access_tree* live_tree(atspi_test_app* app, char* status, int toast):
	ui_access_tree* tree = ui_access_tree_new(16, 512)
	ui_rect r = ui_rect_new(0.0, 0.0, 300.0, 200.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_set_text(tree, 1, UI_ACCESS_NAME, c"Editor", 6)
	ui_access_node* line = ui_access_add(tree, 2, 1, UI_ACCESS_TEXT, r)
	line.live = UI_ACCESS_LIVE_POLITE
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, status, strlen(status))
	ui_access_node* button = ui_access_add(tree, 3, 1, UI_ACCESS_BUTTON, r)
	button.actions = UI_ACCESS_ACTIVATE
	ui_access_set_text(tree, 3, UI_ACCESS_NAME, c"Save", 4)
	if toast:
		ui_access_node* note = ui_access_add(tree, 4, 1, UI_ACCESS_TEXT, r)
		note.live = UI_ACCESS_LIVE_ASSERTIVE
		ui_access_set_text(tree, 4, UI_ACCESS_NAME, c"Disk full", 9)
	tree.action = atspi_test_action
	tree.context = app
	return tree


# The node's GetAttributes as "key=value;" pairs.
char* atspi_test_attributes(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id):
	dbus_body(c.conn)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, c"org.a11y.atspi.Accessible", c"GetAttributes", 0, &reply))
	assert_strings_equal(c"a{ss}", reply.signature)
	dbus_reader r
	dbus_message_reader(&reply, &r)
	int bytes = dbus_read_u32(&r)
	dbus_read_align(&r, 8)
	int end = r.pos + bytes
	atspi_test_client pairs
	pairs.log_length = 0
	pairs.log[0] = 0
	while ((r.pos < end) && (r.failed == 0)):
		dbus_read_align(&r, 8)
		atspi_test_log(&pairs, dbus_read_string(&r, 0))
		atspi_test_log(&pairs, c"=")
		atspi_test_log(&pairs, dbus_read_string(&r, 0))
		atspi_test_log(&pairs, c";")
	assert_equal(0, r.failed)
	dbus_message_free(&reply)
	return dbus_strdup(&pairs.log[0])


int atspi_test_count(char* log, char* needle):
	int count = 0
	int at = index_of(log, needle)
	while (at >= 0):
		count = count + 1
		log = &log[at + 1]
		at = index_of(log, needle)
	return count


void check_live(char* address):
	atspi_test_client client
	client.log_length = 0
	client.log[0] = 0
	client.embeds = 0
	client.conn = dbus_open(address)
	atspi_test_client* c = &client
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, c"type='signal',interface='org.a11y.atspi.Event.Object'")
	dbus_message reply
	assert_equal(1, dbus_call_sync(c.conn, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"AddMatch", c"s"))
	dbus_message_free(&reply)
	atspi_test_app app
	app.calls = 0
	ui_access_tree* tree = live_tree(&app, c"Ready.", 0)
	ui_atspi_bridge* b = ui_access_atspi_open_at(address, c"W live")
	asserts(c"bridge connects", b != 0)
	assert_equal(1, ui_access_atspi_publish(b, tree))
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	char* log = &c.log[0]
	# Content present at the first publication is not announced.
	asserts(c"nothing announced yet", !contains(log, c"Announcement"))
	char* attributes = atspi_test_attributes(c, b, tree, 2)
	asserts(c"live attribute", contains(attributes, c"live=polite;"))
	asserts(c"container-live attribute", contains(attributes, c"container-live=polite;"))
	free(attributes)
	attributes = atspi_test_attributes(c, b, tree, 3)
	asserts(c"no live outside a region", !contains(attributes, c"live="))
	free(attributes)

	# A changed status line, a new assertive toast and an explicit
	# announcement, each spoken once.
	ui_access_tree* next = live_tree(&app, c"Saved.", 1)
	assert_equal(1, ui_access_announce(next, c"Exported", 8, UI_ACCESS_LIVE_POLITE))
	assert_equal(0, ui_access_announce(next, c"", 0, UI_ACCESS_LIVE_POLITE))
	assert_equal(0, ui_access_announce(next, c"x", 1, 7))
	assert_equal(0, ui_access_announce(next, c"\xff", 1, UI_ACCESS_LIVE_POLITE))
	asserts(c"pending announcement differs", !ui_access_tree_same(next, tree))
	assert_equal(1, ui_access_atspi_publish(b, next))
	assert_equal(0, next.announcement.length)
	ui_access_tree_free(tree)
	tree = next
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	asserts(c"status announced politely", contains(log, c"Announcement 1 Saved. /org/a11y/atspi/accessible/2\n"))
	asserts(c"toast announced assertively", contains(log, c"Announcement 2 Disk full /org/a11y/atspi/accessible/4\n"))
	asserts(c"explicit announcement from the window", contains(log, c"Announcement 1 Exported /org/a11y/atspi/accessible/1\n"))
	asserts(c"status name changed too", contains(log, c"PropertyChange accessible-name /org/a11y/atspi/accessible/2"))
	assert_equal(3, atspi_test_count(log, c"Announcement"))
	attributes = atspi_test_attributes(c, b, tree, 4)
	asserts(c"toast is assertive", contains(attributes, c"live=assertive;"))
	free(attributes)

	# Republishing the same text announces nothing again.
	next = live_tree(&app, c"Saved.", 1)
	next.focused_id = 0
	assert_equal(1, ui_access_atspi_publish(b, next))
	ui_access_tree_free(tree)
	tree = next
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	assert_equal(3, atspi_test_count(log, c"Announcement"))

	ui_access_atspi_close(b)
	ui_access_tree_free(tree)
	dbus_close(c.conn)


# A two-line editor: "one two\nthr\xc3\xa9e" (13 characters), the
# caret at 7 after selecting "two" forwards from 4.
ui_access_tree* text_tree(atspi_test_app* app, int caret, int anchor):
	ui_access_tree* tree = ui_access_tree_new(8, 256)
	ui_rect r = ui_rect_new(0.0, 0.0, 300.0, 100.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* editor = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, r)
	editor.states = UI_ACCESS_FOCUSABLE
	editor.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SET_SELECTION | UI_ACCESS_FOCUS
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"Notes", 5)
	ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"one two\nthr\xc3\xa9e", 14)
	ui_access_set_selection(tree, 2, anchor, caret)
	tree.focused_id = 2
	tree.action = atspi_test_action
	tree.context = app
	return tree


# Text.member(args) on node 2 answering a bool; the args are already in
# the client's buffer.
int atspi_test_text_bool(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, char* member, char* sig):
	return atspi_test_bool(c, b, tree, 2, c"org.a11y.atspi.Text", member, sig)


void check_text(char* address):
	atspi_test_client client
	client.log_length = 0
	client.log[0] = 0
	client.embeds = 0
	client.conn = dbus_open(address)
	asserts(c"client connects", client.conn != 0)
	atspi_test_client* c = &client
	dbus_message reply
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, c"type='signal',interface='org.a11y.atspi.Event.Object'")
	assert_equal(1, dbus_call_sync(c.conn, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"AddMatch", c"s"))
	dbus_message_free(&reply)

	atspi_test_app app
	app.calls = 0
	ui_access_tree* tree = text_tree(&app, 7, 4)
	ui_atspi_bridge* b = ui_access_atspi_open_at(address, c"Editor")
	asserts(c"bridge connects", b != 0)
	assert_equal(1, ui_access_atspi_publish(b, tree))
	char* text = c"org.a11y.atspi.Text"

	# The caret, the selection and the selectable-text state.
	assert_equal(7, atspi_test_int_property(c, b, tree, 2, text, c"CaretOffset"))
	assert_equal(13, atspi_test_int_property(c, b, tree, 2, text, c"CharacterCount"))
	assert_equal(1, atspi_test_u32(c, b, tree, 2, text, c"GetNSelections"))
	int lo = 0
	int hi = 0
	atspi_test_state(c, b, tree, 2, &lo, &hi)
	asserts(c"selectable text", atspi_test_has(hi, ATSPI_STATE_SELECTABLE_TEXT - 32))
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetSelection", c"i", &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	assert_equal(4, dbus_read_i32(&r))
	assert_equal(7, dbus_read_i32(&r))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetSelection", c"i", &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(0, dbus_read_i32(&r))
	assert_equal(0, dbus_read_i32(&r))
	dbus_message_free(&reply)

	# Attributes: empty sets, one run over the whole text, and an empty
	# string array without stray padding.
	out = dbus_body(c.conn)
	dbus_put_i32(out, 9)
	dbus_put_bool(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetAttributeRun", c"ib", &reply))
	assert_strings_equal(c"a{ss}ii", reply.signature)
	dbus_message_reader(&reply, &r)
	assert_equal(0, dbus_read_u32(&r))
	dbus_read_align(&r, 8)
	assert_equal(0, dbus_read_i32(&r))
	assert_equal(13, dbus_read_i32(&r))
	assert_equal(0, r.failed)
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetAttributes", c"i", &reply))
	assert_strings_equal(c"a{ss}ii", reply.signature)
	dbus_message_free(&reply)
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetDefaultAttributeSet", 0, &reply))
	assert_strings_equal(c"as", reply.signature)
	assert_equal(4, reply.body_length)
	dbus_message_free(&reply)
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetDefaultAttributes", 0, &reply))
	assert_strings_equal(c"a{ss}", reply.signature)
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_string(out, c"weight")
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetAttributeValue", c"is", &reply))
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"", dbus_read_string(&r, 0))
	dbus_message_free(&reply)

	# Caret moves and selections reach the application as
	# SET_SELECTION "anchor active".
	out = dbus_body(c.conn)
	dbus_put_i32(out, 2)
	asserts(c"caret accepted", atspi_test_text_bool(c, b, tree, c"SetCaretOffset", c"i"))
	assert_equal(1, app.calls)
	assert_equal(2, app.last_id)
	assert_equal(UI_ACCESS_SET_SELECTION, app.last_action)
	assert_strings_equal(c"2 2", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 14)
	asserts(c"caret past the end", !atspi_test_text_bool(c, b, tree, c"SetCaretOffset", c"i"))
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_i32(out, 3)
	asserts(c"one selection only", !atspi_test_text_bool(c, b, tree, c"AddSelection", c"ii"))
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_i32(out, 13)
	dbus_put_i32(out, 8)
	asserts(c"set selection", atspi_test_text_bool(c, b, tree, c"SetSelection", c"iii"))
	assert_strings_equal(c"13 8", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	dbus_put_i32(out, 0)
	dbus_put_i32(out, 1)
	asserts(c"no second selection", !atspi_test_text_bool(c, b, tree, c"SetSelection", c"iii"))
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	asserts(c"remove selection", atspi_test_text_bool(c, b, tree, c"RemoveSelection", c"i"))
	assert_strings_equal(c"7 7", &app.last_value[0])
	assert_equal(3, app.calls)

	# Republishing with the selection gone and the caret moved announces
	# both, selection first.
	ui_access_tree* next = text_tree(&app, 9, 9)
	ui_access_atspi_publish(b, next)
	ui_access_tree_free(tree)
	tree = next
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	char* log = &c.log[0]
	int selection = index_of(log, c"TextSelectionChanged  /org/a11y/atspi/accessible/2\n")
	asserts(c"selection event", selection >= 0)
	asserts(c"caret event after it", index_of(log, c"TextCaretMoved  /org/a11y/atspi/accessible/2\n") > selection)
	assert_equal(0, atspi_test_u32(c, b, tree, 2, text, c"GetNSelections"))
	# Without a selection a new one can be added; an empty one cannot.
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_i32(out, 3)
	asserts(c"add selection", atspi_test_text_bool(c, b, tree, c"AddSelection", c"ii"))
	assert_strings_equal(c"0 3", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 2)
	dbus_put_i32(out, 2)
	asserts(c"empty selection", !atspi_test_text_bool(c, b, tree, c"AddSelection", c"ii"))
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	asserts(c"nothing to remove", !atspi_test_text_bool(c, b, tree, c"RemoveSelection", c"i"))
	# A caret move alone announces no selection change.
	c.log_length = 0
	c.log[0] = 0
	next = text_tree(&app, 10, 10)
	ui_access_atspi_publish(b, next)
	ui_access_tree_free(tree)
	tree = next
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	asserts(c"caret moved", contains(log, c"TextCaretMoved  /org/a11y/atspi/accessible/2\n"))
	asserts(c"no selection event", !contains(log, c"TextSelectionChanged"))
	assert_equal(10, atspi_test_int_property(c, b, tree, 2, text, c"CaretOffset"))

	ui_access_atspi_close(b)
	ui_access_tree_free(tree)
	dbus_close(c.conn)


void test_atspi_bridge_on_a_private_bus():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_bridge(bus.address)
	dbus_test_bus_stop(&bus)


void test_atspi_tables_selection_and_cache():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_tables(bus.address)
	dbus_test_bus_stop(&bus)


void test_atspi_live_regions_and_announcements():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_live(bus.address)
	dbus_test_bus_stop(&bus)


void test_atspi_text_caret_selection_and_attributes():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_text(bus.address)
	dbus_test_bus_stop(&bus)


void test_atspi_open_without_a_bus():
	assert_equal(0, cast(int, ui_access_atspi_open_at(c"unix:path=/nonexistent/w-atspi", c"x")))


# Widget snapshots root at ui_access_root_id (2^30); paths up to 2^31 - 1
# must resolve, longer ones must not overflow into another id.
void test_atspi_paths_cover_widget_root_ids():
	char[64] path
	assert_equal(1073741824, ui_atspi_path_id(ui_atspi_node_path(&path[0], 1073741824)))
	assert_equal(2147483647, ui_atspi_path_id(c"/org/a11y/atspi/accessible/2147483647"))
	assert_equal(0 - 1, ui_atspi_path_id(c"/org/a11y/atspi/accessible/21474836470"))
	assert_equal(0, ui_atspi_path_id(c"/org/a11y/atspi/accessible/root"))


# An a{ss} at the reader as "key=value;" pairs.
char* atspi_test_pairs(dbus_reader* r):
	int bytes = dbus_read_u32(r)
	dbus_read_align(r, 8)
	int end = r.pos + bytes
	atspi_test_client pairs
	pairs.log_length = 0
	pairs.log[0] = 0
	while ((r.pos < end) && (r.failed == 0)):
		dbus_read_align(r, 8)
		atspi_test_log(&pairs, dbus_read_string(r, 0))
		atspi_test_log(&pairs, c"=")
		atspi_test_log(&pairs, dbus_read_string(r, 0))
		atspi_test_log(&pairs, c";")
	return dbus_strdup(&pairs.log[0])


# The #863 depth: a two-line editor with glyph boxes, attributes and
# two selections; a multi-selection list; a table with an explicit
# header row, a row header spanning two rows and a cell spanning two
# columns.
ui_access_tree* depth_tree(atspi_test_app* app):
	ui_access_tree* tree = ui_access_tree_new(32, 512)
	ui_rect r = ui_rect_new(0.0, 0.0, 300.0, 300.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_node* editor = ui_access_add(tree, 2, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 10.0, 200.0, 40.0))
	editor.states = UI_ACCESS_FOCUSABLE
	editor.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SET_SELECTION | UI_ACCESS_SET_SELECTIONS
	ui_access_set_text(tree, 2, UI_ACCESS_VALUE, c"ab\ncd", 5)
	ui_rect[5] boxes
	boxes[0] = ui_rect_new(14.0, 12.0, 10.0, 16.0)
	boxes[1] = ui_rect_new(24.0, 12.0, 10.0, 16.0)
	boxes[2] = ui_rect_new(34.0, 12.0, 0.0, 16.0)
	boxes[3] = ui_rect_new(14.0, 30.0, 10.0, 16.0)
	boxes[4] = ui_rect_new(24.0, 30.0, 12.0, 16.0)
	ui_access_set_char_boxes(tree, 2, &boxes[0], 5)
	ui_access_text_attrs* base = ui_access_default_attrs(tree, 2)
	ui_access_attrs_set_family(base, c"Liberation Sans", 15)
	base.size = 12
	base.weight = 400
	base.fg = 0x102030
	base.bg = 0xffffff
	ui_access_text_attrs* bold = ui_access_add_attr_run(tree, 2, 3, 5)
	bold.weight = 700
	ui_access_set_selection(tree, 2, 0, 1)
	ui_access_add_selection(tree, 2, 3, 5)
	ui_access_node* list = ui_access_add(tree, 3, 1, UI_ACCESS_LIST, ui_rect_new(10.0, 60.0, 100.0, 60.0))
	list.states = UI_ACCESS_MULTISELECTABLE
	for k in range(3):
		ui_access_node* item = ui_access_add(tree, 4 + k, 3, UI_ACCESS_LIST_ITEM, ui_rect_new(10.0, 60.0 + cast(float32, k) * 20.0, 100.0, 20.0))
		item.actions = UI_ACCESS_SELECT | UI_ACCESS_ACTIVATE
		if (k == 1): item.states = UI_ACCESS_SELECTED
	ui_access_add(tree, 10, 1, UI_ACCESS_TABLE, ui_rect_new(10.0, 130.0, 200.0, 80.0))
	ui_access_node* head = ui_access_add(tree, 11, 10, UI_ACCESS_ROW, r)
	head.states = UI_ACCESS_HEADER
	ui_access_add(tree, 12, 11, UI_ACCESS_CELL, r)
	ui_access_set_text(tree, 12, UI_ACCESS_NAME, c"Kind", 4)
	ui_access_node* item_head = ui_access_add(tree, 13, 11, UI_ACCESS_CELL, r)
	item_head.col_span = 2
	ui_access_set_text(tree, 13, UI_ACCESS_NAME, c"Item", 4)
	ui_access_add(tree, 20, 10, UI_ACCESS_ROW, r)
	ui_access_node* fruit = ui_access_add(tree, 21, 20, UI_ACCESS_CELL, r)
	fruit.states = UI_ACCESS_HEADER
	fruit.row_span = 2
	ui_access_set_text(tree, 21, UI_ACCESS_NAME, c"Fruit", 5)
	ui_access_add(tree, 22, 20, UI_ACCESS_CELL, r)
	ui_access_add(tree, 23, 20, UI_ACCESS_CELL, r)
	ui_access_add(tree, 30, 10, UI_ACCESS_ROW, r)
	ui_access_node* cherry = ui_access_add(tree, 31, 30, UI_ACCESS_CELL, r)
	cherry.col_span = 2
	ui_access_set_text(tree, 31, UI_ACCESS_NAME, c"Cherry", 6)
	tree.focused_id = 2
	tree.action = atspi_test_action
	tree.context = app
	return tree


# Four ints from an (iiii)-less "iiii" reply.
void atspi_test_iiii(dbus_message* reply, int* v):
	dbus_reader r
	dbus_message_reader(reply, &r)
	for i in range(4): v[i] = dbus_read_i32(&r)


# A direct (no bus, no Hello) connection, authenticated with SASL
# EXTERNAL as libdbus opens a private connection to a peer; the bridge
# is pumped meanwhile, since it answers on this thread.
dbus_conn* atspi_test_p2p_open(char* address, ui_atspi_bridge* b, ui_access_tree* tree):
	int fd = dbus_connect_address(address)
	if (fd < 0): return 0
	dbus_conn* conn = new dbus_conn()
	conn.fd = fd
	conn.serial = 0
	conn.unique_name = 0
	conn.failed = 0
	dbus_buf_init(&conn.in)
	dbus_buf_init(&conn.head)
	dbus_buf_init(&conn.body)
	socket_set_nonblocking(fd)
	char* uid = itoa(getuid())
	dbus_buf line
	dbus_buf_init(&line)
	dbus_put_byte(&line, 0)
	dbus_put_bytes(&line, c"AUTH EXTERNAL ", 14)
	char* hex = c"0123456789abcdef"
	for i in range(strlen(uid)):
		dbus_put_byte(&line, hex[(uid[i] >> 4) & 15])
		dbus_put_byte(&line, hex[uid[i] & 15])
	dbus_put_bytes(&line, c"\r\nNEGOTIATE_UNIX_FD\r\n", 21)
	dbus_write_all(conn, line.data, line.length)
	dbus_buf_free(&line)
	# "OK <guid>" and "ERROR" (no fd passing) come back.
	int lines = 0
	for i in range(400):
		ui_access_atspi_dispatch(b, tree)
		dbus_fill(conn)
		lines = 0
		for k in range(conn.in.length):
			if (conn.in.data[k] == 10): lines = lines + 1
		if (lines >= 2): break
		poll_single(fd, poll_in, 5)
	if ((lines < 2) || (conn.in.data[0] != 'O') || (conn.in.data[1] != 'K')):
		dbus_close(conn)
		return 0
	conn.in.length = 0
	dbus_write_all(conn, c"BEGIN\r\n", 7)
	return conn


void check_depth(char* address):
	atspi_test_client client
	client.log_length = 0
	client.log[0] = 0
	client.embeds = 0
	client.conn = dbus_open(address)
	asserts(c"client connects", client.conn != 0)
	atspi_test_client* c = &client
	dbus_message reply
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, c"type='signal',interface='org.a11y.atspi.Event.Object'")
	assert_equal(1, dbus_call_sync(c.conn, &reply, 2000, c"org.freedesktop.DBus", c"/org/freedesktop/DBus", c"org.freedesktop.DBus", c"AddMatch", c"s"))
	dbus_message_free(&reply)
	atspi_test_app app
	app.calls = 0
	ui_access_tree* tree = depth_tree(&app)
	ui_atspi_bridge* b = ui_access_atspi_open_at(address, c"Depth")
	asserts(c"bridge connects", b != 0)
	ui_access_atspi_set_origin(b, 100, 200)
	assert_equal(1, ui_access_atspi_publish(b, tree))
	char* text = c"org.a11y.atspi.Text"
	dbus_reader r
	int[4] v

	# Glyph geometry: a character in window and screen coordinates, a
	# range over two lines, and the character at a point.
	out = dbus_body(c.conn)
	dbus_put_i32(out, 4)
	dbus_put_u32(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetCharacterExtents", c"iu", &reply))
	atspi_test_iiii(&reply, &v[0])
	dbus_message_free(&reply)
	assert_equal(24, v[0])
	assert_equal(30, v[1])
	assert_equal(12, v[2])
	assert_equal(16, v[3])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_u32(out, 0)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetCharacterExtents", c"iu", &reply))
	atspi_test_iiii(&reply, &v[0])
	dbus_message_free(&reply)
	assert_equal(114, v[0])
	assert_equal(212, v[1])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	dbus_put_i32(out, 5)
	dbus_put_u32(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetRangeExtents", c"iiu", &reply))
	atspi_test_iiii(&reply, &v[0])
	dbus_message_free(&reply)
	assert_equal(14, v[0])
	assert_equal(12, v[1])
	assert_equal(22, v[2])
	assert_equal(34, v[3])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 125)
	dbus_put_i32(out, 235)
	dbus_put_u32(out, 0)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetOffsetAtPoint", c"iiu", &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(4, dbus_read_i32(&r))
	dbus_message_free(&reply)

	# Attributes: the defaults, a run's own attributes alone, and with
	# the defaults included.
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetDefaultAttributes", 0, &reply))
	dbus_message_reader(&reply, &r)
	char* pairs = atspi_test_pairs(&r)
	dbus_message_free(&reply)
	assert_strings_equal(c"family-name=Liberation Sans;size=12;weight=400;style=normal;underline=none;fg-color=4112,8224,12336;bg-color=65535,65535,65535;", pairs)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 4)
	dbus_put_bool(out, 0)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetAttributeRun", c"ib", &reply))
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"weight=700;", atspi_test_pairs(&r))
	assert_equal(3, dbus_read_i32(&r))
	assert_equal(5, dbus_read_i32(&r))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	dbus_put_bool(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetAttributeRun", c"ib", &reply))
	dbus_message_reader(&reply, &r)
	asserts(c"defaults included", contains(atspi_test_pairs(&r), c"family-name=Liberation Sans;"))
	assert_equal(0, dbus_read_i32(&r))
	assert_equal(3, dbus_read_i32(&r))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 4)
	dbus_put_string(out, c"weight")
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetAttributeValue", c"is", &reply))
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"700", dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetDefaultAttributeSet", 0, &reply))
	dbus_message_reader(&reply, &r)
	dbus_read_u32(&r)
	assert_strings_equal(c"family-name:Liberation Sans", dbus_read_string(&r, 0))
	dbus_message_free(&reply)

	# Two selections; adding a third and removing the first go out as
	# one SET_SELECTIONS request each, keeping the primary's caret.
	assert_equal(2, atspi_test_u32(c, b, tree, 2, text, c"GetNSelections"))
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	assert_equal(1, atspi_test_call(c, b, tree, 2, text, c"GetSelection", c"i", &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(3, dbus_read_i32(&r))
	assert_equal(5, dbus_read_i32(&r))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 2)
	dbus_put_i32(out, 3)
	asserts(c"add a selection", atspi_test_bool(c, b, tree, 2, text, c"AddSelection", c"ii"))
	assert_equal(UI_ACCESS_SET_SELECTIONS, app.last_action)
	assert_strings_equal(c"0 1 3 5 2 3", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	asserts(c"remove the first", atspi_test_bool(c, b, tree, 2, text, c"RemoveSelection", c"i"))
	assert_strings_equal(c"1 1 3 5", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 1)
	dbus_put_i32(out, 0)
	dbus_put_i32(out, 2)
	asserts(c"replace the second", atspi_test_bool(c, b, tree, 2, text, c"SetSelection", c"iii"))
	assert_strings_equal(c"0 1 0 2", &app.last_value[0])

	# The multi-selection list: its state, adding, removing, all, none.
	char* sel = c"org.a11y.atspi.Selection"
	int lo = 0
	int hi = 0
	atspi_test_state(c, b, tree, 3, &lo, &hi)
	asserts(c"multiselectable", atspi_test_has(lo, ATSPI_STATE_MULTISELECTABLE))
	app.calls = 0
	assert_equal(1, atspi_test_i32_ii(c, b, tree, 3, sel, c"SelectChild", 0, 0, 0))
	assert_equal(UI_ACCESS_SELECT, app.last_action)
	assert_strings_equal(c"add", &app.last_value[0])
	assert_equal(4, app.last_id)
	assert_equal(1, atspi_test_i32_ii(c, b, tree, 3, sel, c"DeselectSelectedChild", 0, 0, 0))
	assert_strings_equal(c"remove", &app.last_value[0])
	assert_equal(5, app.last_id)
	assert_equal(0, atspi_test_i32_ii(c, b, tree, 3, sel, c"DeselectChild", 0, 0, 0))
	assert_equal(2, app.calls)
	dbus_body(c.conn)
	asserts(c"select all", atspi_test_bool(c, b, tree, 3, sel, c"SelectAll", 0))
	assert_equal(4, app.calls)
	assert_equal(6, app.last_id)
	dbus_body(c.conn)
	asserts(c"clear", atspi_test_bool(c, b, tree, 3, sel, c"ClearSelection", 0))
	assert_equal(5, app.calls)
	assert_strings_equal(c"remove", &app.last_value[0])

	# The table: explicit header row, a row header over two rows and a
	# cell over two columns.
	char* table = c"org.a11y.atspi.Table"
	char* cell = c"org.a11y.atspi.TableCell"
	assert_equal(2, atspi_test_int_property(c, b, tree, 10, table, c"NRows"))
	assert_equal(3, atspi_test_int_property(c, b, tree, 10, table, c"NColumns"))
	assert_strings_equal(c"/org/a11y/atspi/accessible/31", atspi_test_ref_ii(c, b, tree, 10, table, c"GetAccessibleAt", 1, 2, 1))
	assert_strings_equal(c"/org/a11y/atspi/accessible/21", atspi_test_ref_ii(c, b, tree, 10, table, c"GetRowHeader", 1, 0, 0))
	assert_strings_equal(c"/org/a11y/atspi/accessible/13", atspi_test_ref_ii(c, b, tree, 10, table, c"GetColumnHeader", 2, 0, 0))
	assert_equal(2, atspi_test_i32_ii(c, b, tree, 10, table, c"GetColumnExtentAt", 1, 2, 1))
	assert_equal(2, atspi_test_i32_ii(c, b, tree, 10, table, c"GetRowExtentAt", 1, 0, 1))
	assert_equal(ATSPI_ROLE_TABLE_ROW_HEADER, atspi_test_u32(c, b, tree, 21, c"org.a11y.atspi.Accessible", c"GetRole"))
	assert_equal(2, atspi_test_int_property(c, b, tree, 31, cell, c"ColumnSpan"))
	assert_equal(2, atspi_test_int_property(c, b, tree, 21, cell, c"RowSpan"))
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 31, cell, c"GetRowColumnSpan", 0, &reply))
	atspi_test_iiii(&reply, &v[0])
	dbus_message_free(&reply)
	assert_equal(1, v[0])
	assert_equal(1, v[1])
	assert_equal(1, v[2])
	assert_equal(2, v[3])
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 31, cell, c"GetRowHeaderCells", 0, &reply))
	dbus_message_reader(&reply, &r)
	dbus_read_u32(&r)
	dbus_read_align(&r, 8)
	dbus_read_string(&r, 0)
	assert_strings_equal(c"/org/a11y/atspi/accessible/21", dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	out = dbus_body(c.conn)
	dbus_put_i32(out, 4)
	assert_equal(1, atspi_test_call(c, b, tree, 10, table, c"GetRowColumnExtentsAtIndex", c"i", &reply))
	dbus_message_reader(&reply, &r)
	assert_equal(1, dbus_read_bool(&r))
	assert_equal(1, dbus_read_i32(&r))
	assert_equal(1, dbus_read_i32(&r))
	assert_equal(1, dbus_read_i32(&r))
	assert_equal(2, dbus_read_i32(&r))
	dbus_message_free(&reply)

	# Republishing with other selections and attributes announces both.
	c.log_length = 0
	c.log[0] = 0
	ui_access_tree* next = depth_tree(&app)
	ui_access_find(next, 2).selections[0] = 4
	ui_access_find(next, 2).runs[0].attrs.italic = 1
	ui_access_atspi_publish(b, next)
	ui_access_tree_free(tree)
	tree = next
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.freedesktop.DBus.Peer", c"Ping", 0, &reply))
	dbus_message_free(&reply)
	asserts(c"selection event", contains(&c.log[0], c"TextSelectionChanged  /org/a11y/atspi/accessible/2\n"))
	asserts(c"attributes event", contains(&c.log[0], c"TextAttributesChanged  /org/a11y/atspi/accessible/2\n"))

	# The peer-to-peer bus: the address the application hands out takes
	# a direct connection, which answers queries without the bus.
	dbus_body(c.conn)
	assert_equal(1, atspi_test_call(c, b, tree, 0, c"org.a11y.atspi.Application", c"GetApplicationBusAddress", 0, &reply))
	dbus_message_reader(&reply, &r)
	char* p2p = dbus_strdup(dbus_read_string(&r, 0))
	dbus_message_free(&reply)
	asserts(c"p2p address", starts_with(p2p, c"unix:abstract=w-atspi-"))
	dbus_conn* direct = atspi_test_p2p_open(p2p, b, tree)
	asserts(c"p2p connects", direct != 0)
	dbus_body(direct)
	int serial = dbus_call(direct, 0, c"/org/a11y/atspi/accessible/21", c"org.a11y.atspi.Accessible", c"GetRole", 0)
	int got = 0
	for i in range(400):
		ui_access_atspi_dispatch(b, tree)
		dbus_message m
		if ((got == 0) && (dbus_wait(direct, &m, 5) == 1)):
			if ((m.type == DBUS_METHOD_RETURN) && (m.reply_serial == serial)):
				dbus_message_reader(&m, &r)
				got = dbus_read_u32(&r)
			dbus_message_free(&m)
	assert_equal(ATSPI_ROLE_TABLE_ROW_HEADER, got)
	assert_equal(1, ui_access_atspi_p2p_calls(b))
	dbus_close(direct)
	ui_access_atspi_dispatch(b, tree)
	assert_equal(0, b.peer_count)

	ui_access_atspi_close(b)
	ui_access_tree_free(tree)
	dbus_close(c.conn)


void test_atspi_glyphs_attributes_selections_tables_and_p2p():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_depth(bus.address)
	dbus_test_bus_stop(&bus)


# The #911/#912 depth: a slider labelled by a label, a combo box that
# controls its list, and an editor scrolled so that only its middle two
# lines show, which takes SCROLL_TO.
ui_access_tree* relations_tree(atspi_test_app* app):
	ui_access_tree* tree = ui_access_tree_new(32, 512)
	ui_rect r = ui_rect_new(0.0, 0.0, 300.0, 300.0)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, r)
	ui_access_add(tree, 2, 1, UI_ACCESS_TEXT, ui_rect_new(10.0, 10.0, 60.0, 20.0))
	ui_access_set_text(tree, 2, UI_ACCESS_NAME, c"Volume", 6)
	ui_access_node* slider = ui_access_add(tree, 3, 1, UI_ACCESS_SLIDER, ui_rect_new(80.0, 10.0, 100.0, 20.0))
	slider.states = UI_ACCESS_FOCUSABLE
	slider.actions = UI_ACCESS_SET_VALUE
	ui_access_set_text(tree, 3, UI_ACCESS_VALUE, c"4", 1)
	assert_equal(1, ui_access_set_range(tree, 3, 4.0, 0.0, 10.0, 0.5))
	assert_equal(1, ui_access_add_relation(tree, 3, UI_ACCESS_REL_LABELLED_BY, 2))
	ui_access_node* editor = ui_access_add(tree, 4, 1, UI_ACCESS_TEXTBOX, ui_rect_new(10.0, 100.0, 100.0, 40.0))
	editor.actions = UI_ACCESS_SET_VALUE | UI_ACCESS_SCROLL_TO
	ui_access_set_text(tree, 4, UI_ACCESS_VALUE, c"ab\ncd\nef\ngh", 11)
	ui_rect[11] boxes
	for k in range(11):
		float32 line = cast(float32, k / 3)
		float32 column = cast(float32, k % 3)
		float32 w = 10.0
		if (k % 3 == 2): w = 0.0
		boxes[k] = ui_rect_new(10.0 + column * 10.0, 80.0 + line * 20.0, w, 20.0)
	ui_access_set_char_boxes(tree, 4, &boxes[0], 11)
	ui_access_node* combo = ui_access_add(tree, 5, 1, UI_ACCESS_COMBOBOX, ui_rect_new(10.0, 40.0, 100.0, 20.0))
	combo.states = UI_ACCESS_EXPANDED
	ui_access_add(tree, 6, 1, UI_ACCESS_LIST, ui_rect_new(10.0, 60.0, 100.0, 30.0))
	assert_equal(1, ui_access_add_relation(tree, 5, UI_ACCESS_REL_CONTROLLER_FOR, 6))
	tree.focused_id = 3
	tree.action = atspi_test_action
	tree.context = app
	return tree


# A node's relation set as "type:path,path;" entries.
char* atspi_test_relations(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id):
	dbus_body(c.conn)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, c"org.a11y.atspi.Accessible", c"GetRelationSet", 0, &reply))
	assert_strings_equal(c"a(ua(so))", reply.signature)
	dbus_reader r
	dbus_message_reader(&reply, &r)
	atspi_test_client text
	text.log_length = 0
	text.log[0] = 0
	int bytes = dbus_read_u32(&r)
	dbus_read_align(&r, 8)
	int end = r.pos + bytes
	while ((r.pos < end) && (r.failed == 0)):
		dbus_read_align(&r, 8)
		atspi_test_log(&text, itoa(dbus_read_u32(&r)))
		atspi_test_log(&text, c":")
		int inner = dbus_read_u32(&r)
		dbus_read_align(&r, 8)
		int inner_end = r.pos + inner
		while ((r.pos < inner_end) && (r.failed == 0)):
			dbus_read_align(&r, 8)
			dbus_read_string(&r, 0)
			atspi_test_log(&text, dbus_read_string(&r, 0))
			atspi_test_log(&text, c",")
		atspi_test_log(&text, c";")
	asserts(c"relation set parses", r.failed == 0)
	dbus_message_free(&reply)
	return dbus_strdup(&text.log[0])


# A Value property of node id, as a double.
float32 atspi_test_double(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int id, char* prop):
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_string(out, c"org.a11y.atspi.Value")
	dbus_put_string(out, prop)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, id, c"org.freedesktop.DBus.Properties", c"Get", c"ss", &reply))
	dbus_reader r
	dbus_message_reader(&reply, &r)
	assert_strings_equal(c"d", dbus_read_sig(&r))
	float32 v = dbus_read_double_f32(&r)
	dbus_message_free(&reply)
	return v


# GetBoundedRanges over (x, y, w, h) in window coordinates, as
# "start-end:text;" entries.
char* atspi_test_bounded(atspi_test_client* c, ui_atspi_bridge* b, ui_access_tree* tree, int x, int y, int w, int h, int xclip, int yclip):
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_i32(out, x)
	dbus_put_i32(out, y)
	dbus_put_i32(out, w)
	dbus_put_i32(out, h)
	dbus_put_u32(out, 1)
	dbus_put_u32(out, xclip)
	dbus_put_u32(out, yclip)
	dbus_message reply
	assert_equal(1, atspi_test_call(c, b, tree, 4, c"org.a11y.atspi.Text", c"GetBoundedRanges", c"iiiiuuu", &reply))
	assert_strings_equal(c"a(iisv)", reply.signature)
	dbus_reader r
	dbus_message_reader(&reply, &r)
	atspi_test_client text
	text.log_length = 0
	text.log[0] = 0
	int bytes = dbus_read_u32(&r)
	dbus_read_align(&r, 8)
	int end = r.pos + bytes
	while ((r.pos < end) && (r.failed == 0)):
		dbus_read_align(&r, 8)
		atspi_test_log(&text, itoa(dbus_read_i32(&r)))
		atspi_test_log(&text, c"-")
		atspi_test_log(&text, itoa(dbus_read_i32(&r)))
		atspi_test_log(&text, c":")
		atspi_test_log(&text, dbus_read_string(&r, 0))
		assert_strings_equal(c"i", dbus_read_sig(&r))
		dbus_read_i32(&r)
		atspi_test_log(&text, c";")
	asserts(c"ranges parse", r.failed == 0)
	dbus_message_free(&reply)
	return dbus_strdup(&text.log[0])


void check_relations(char* address):
	atspi_test_client client
	client.log_length = 0
	client.log[0] = 0
	client.embeds = 0
	client.conn = dbus_open(address)
	asserts(c"client connects", client.conn != 0)
	atspi_test_client* c = &client
	atspi_test_app app
	app.calls = 0
	ui_access_tree* tree = relations_tree(&app)
	ui_atspi_bridge* b = ui_access_atspi_open_at(address, c"Relations")
	asserts(c"bridge connects", b != 0)
	assert_equal(1, ui_access_atspi_publish(b, tree))
	dbus_message reply

	# Relations both ways: labelled-by and its label-for, controller-for
	# and its controlled-by; a node without any has an empty set.
	assert_strings_equal(c"2:/org/a11y/atspi/accessible/2,;", atspi_test_relations(c, b, tree, 3))
	assert_strings_equal(c"1:/org/a11y/atspi/accessible/3,;", atspi_test_relations(c, b, tree, 2))
	assert_strings_equal(c"3:/org/a11y/atspi/accessible/6,;", atspi_test_relations(c, b, tree, 5))
	assert_strings_equal(c"4:/org/a11y/atspi/accessible/5,;", atspi_test_relations(c, b, tree, 6))
	assert_strings_equal(c"", atspi_test_relations(c, b, tree, 4))

	# The slider: its role, its range and setting it.
	assert_equal(ATSPI_ROLE_SLIDER, atspi_test_u32(c, b, tree, 3, c"org.a11y.atspi.Accessible", c"GetRole"))
	asserts(c"current", atspi_test_double(c, b, tree, 3, c"CurrentValue") == 4.0)
	asserts(c"maximum", atspi_test_double(c, b, tree, 3, c"MaximumValue") == 10.0)
	asserts(c"minimum", atspi_test_double(c, b, tree, 3, c"MinimumValue") == 0.0)
	asserts(c"increment", atspi_test_double(c, b, tree, 3, c"MinimumIncrement") == 0.5)
	dbus_buf* out = dbus_body(c.conn)
	dbus_put_double_f32(out, 7.5)
	asserts(c"set value", atspi_test_bool(c, b, tree, 3, c"org.a11y.atspi.Value", c"SetCurrentValue", c"d"))
	assert_equal(UI_ACCESS_SET_VALUE, app.last_action)
	assert_equal(3, app.last_id)
	assert_strings_equal(c"7.5", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_double_f32(out, 11.0)
	asserts(c"out of range", !atspi_test_bool(c, b, tree, 3, c"org.a11y.atspi.Value", c"SetCurrentValue", c"d"))
	out = dbus_body(c.conn)
	dbus_put_string(out, c"org.a11y.atspi.Value")
	dbus_put_string(out, c"CurrentValue")
	dbus_put_sig(out, c"d")
	dbus_put_double_f32(out, 2.0)
	assert_equal(1, atspi_test_call(c, b, tree, 3, c"org.freedesktop.DBus.Properties", c"Set", c"ssv", &reply))
	dbus_message_free(&reply)
	assert_strings_equal(c"2", &app.last_value[0])

	# Bounded ranges over the scrolled editor: the visible middle lines
	# with no clipping, and only the fully shown line when both edges
	# clip.
	assert_strings_equal(c"3-9:cd\nef\n;", atspi_test_bounded(c, b, tree, 10, 100, 100, 40, 0, 0))
	assert_strings_equal(c"3-11:cd\nef\ngh;", atspi_test_bounded(c, b, tree, 10, 105, 100, 40, 0, 0))
	assert_strings_equal(c"6-9:ef\n;", atspi_test_bounded(c, b, tree, 10, 105, 100, 40, 3, 3))
	assert_strings_equal(c"3-4:c;6-7:e;", atspi_test_bounded(c, b, tree, 10, 100, 10, 40, 3, 0))
	assert_strings_equal(c"", atspi_test_bounded(c, b, tree, 200, 100, 10, 40, 0, 0))

	# Scrolling a substring: the last line to the bottom edge, the
	# first to a point near the top.
	out = dbus_body(c.conn)
	dbus_put_i32(out, 9)
	dbus_put_i32(out, 11)
	dbus_put_u32(out, 3)
	asserts(c"scroll substring", atspi_test_bool(c, b, tree, 4, c"org.a11y.atspi.Text", c"ScrollSubstringTo", c"iiu"))
	assert_equal(UI_ACCESS_SCROLL_TO, app.last_action)
	assert_strings_equal(c"9 11 1", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_i32(out, 2)
	dbus_put_u32(out, 1)
	dbus_put_i32(out, 10)
	dbus_put_i32(out, 101)
	asserts(c"scroll to point", atspi_test_bool(c, b, tree, 4, c"org.a11y.atspi.Text", c"ScrollSubstringToPoint", c"iiuii"))
	assert_strings_equal(c"0 2 0", &app.last_value[0])
	out = dbus_body(c.conn)
	dbus_put_i32(out, 0)
	dbus_put_i32(out, 99)
	dbus_put_u32(out, 6)
	asserts(c"bad range", !atspi_test_bool(c, b, tree, 4, c"org.a11y.atspi.Text", c"ScrollSubstringTo", c"iiu"))

	ui_access_atspi_close(b)
	ui_access_tree_free(tree)
	dbus_close(c.conn)


void test_atspi_relations_slider_bounded_ranges_and_scroll():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_relations(bus.address)
	dbus_test_bus_stop(&bus)
