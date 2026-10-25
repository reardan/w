# Shared differential input for the production x64 backend and wllvm: the
# to_json/from_json and to_proto/from_proto/proto_descriptor builtins,
# whose static descriptors wllvm rebuilds from the type table. Covers
# nested structs, lists, maps, float64, a shared descriptor, and protobuf
# nested, repeated and self-referencing messages. Output and exit status
# must match exactly.
import lib.lib
import structures.json
import libs.extras.protobuf.message


struct codec_point:
	int x
	int y


struct codec_shape:
	char* name
	bool closed
	float64 scale
	codec_point origin
	list[codec_point] corners
	list[int] tags
	map[char*, int] weights


message codec_leaf:
	int32 value = 1
	string label = 2


message codec_tree:
	string name = 3
	codec_leaf leaf = 1
	repeated int32 counts = 2
	repeated codec_leaf leaves = 4
	codec_tree child = 5
	bool flag = 6


int main():
	int score = 0
	codec_shape s
	s.name = c"square"
	s.closed = true
	s.scale = 2.5
	s.origin.x = 3
	s.origin.y = 4
	s.corners = new list[codec_point]
	codec_point corner
	corner.x = 1
	corner.y = 2
	s.corners.push(corner)
	corner.x = 5
	s.corners.push(corner)
	s.tags = list[int]{7, 8, 9}
	s.weights = new map[char*, int]
	s.weights[c"a"] = 10
	json_value* v = to_json(s)
	char* text = json_stringify(v)
	println(text)
	codec_shape* back = from_json(codec_shape, json_parse(text))
	if (back != 0):
		if (strcmp(back.name, c"square") == 0 && back.closed && back.scale == 2.5): score += 1
		if (back.origin.y == 4 && back.corners.length == 2 && back.corners[1].x == 5): score += 1
		if (back.tags.length == 3 && back.tags[2] == 9 && back.weights[c"a"] == 10): score += 1
	codec_point p
	p.x = 11
	p.y = 12
	codec_point* pp = &p
	println(json_stringify(to_json(pp)))
	codec_point* q = from_json(codec_point, json_parse(c"{\"x\": 8, \"y\": 9}"))
	if (q != 0 && q.x + q.y == 17): score += 1
	if (from_json(codec_point, json_parse(c"[1]")) == 0): score += 1

	codec_tree t
	t.name.data = c"root"
	t.name.length = 4
	codec_leaf* leaf = new codec_leaf
	leaf.value = 150
	t.leaf = leaf
	t.counts = list[int32]{1, 2, 300}
	t.leaves = new list[codec_leaf]
	codec_leaf element
	element.value = 7
	element.label.data = c"seven"
	element.label.length = 5
	t.leaves.push(element)
	codec_tree* child = new codec_tree
	child.flag = true
	t.child = child
	pb_bytes* wire = to_proto(t)
	for i in range(wire.length):
		print(wire.data[i] & 255)
		print(c" ")
	println(c"")
	codec_tree* u = from_proto(codec_tree, wire)
	if (u != 0):
		if (u.leaf != 0 && u.leaf.value == 150 && u.counts.length == 3 && u.counts[2] == 300): score += 1
		if (u.leaves.length == 1 && u.leaves[0].value == 7 && u.leaves[0].label.length == 5): score += 1
		if (u.child != 0 && u.child.flag && u.name.length == 4): score += 1
	codec_tree* w = from_proto(codec_tree, wire.data, wire.length)
	if (w != 0 && w.leaf.value == 150): score += 1
	pb_message_desc* d = proto_descriptor(codec_tree)
	if (d == proto_descriptor(codec_tree) && d.field_count == 6): score += 1
	println(score)
	return score
