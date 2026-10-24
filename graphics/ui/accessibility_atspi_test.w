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
	for i in range(200):
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
				if (starts_with(m.signature, c"s")): atspi_test_log(c, dbus_read_string(&r, 0))
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

	# Registration: a Peer.Ping round trip lets Embed and Set land.
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


void test_atspi_bridge_on_a_private_bus():
	dbus_test_bus bus
	if (!dbus_test_bus_start(&bus)):
		test_skip(c"SKIP: dbus-daemon not available")
		return
	check_bridge(bus.address)
	dbus_test_bus_stop(&bus)


void test_atspi_open_without_a_bus():
	assert_equal(0, cast(int, ui_access_atspi_open_at(c"unix:path=/nonexistent/w-atspi", c"x")))
