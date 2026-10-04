import structures.json
import lib.utf8

struct ast_json_point:
	int x
	int y

struct ast_json_collection:
	list[ast_json_point] points
	map[char*, int] labels
	string title

type ast_json_alias = ast_json_point
int ast_json_calls
ast_json_point ast_json_make(int x):
	ast_json_calls = ast_json_calls + 1
	return ast_json_point(x, x + 1)

int main():
	ast_json_point point = ast_json_point(3, 4)
	json_value* encoded = to_json(point)
	ast_json_alias* decoded = from_json(ast_json_alias, encoded)
	if (decoded.x != 3 || decoded.y != 4): return 1
	ast_json_point* pointer = &point
	if (from_json(ast_json_point, to_json(pointer)).y != 4): return 2
	if (from_json(ast_json_point, to_json(ast_json_make(7))).x != 7): return 3
	if (ast_json_calls != 1): return 4
	ast_json_collection collection
	collection.points = list[ast_json_point]{ast_json_point(1, 2), point}
	collection.labels = map[char*, int]{c"a": 9}
	collection.title = s"collection"
	ast_json_collection* result = from_json(ast_json_collection, to_json(collection))
	if (result.points.length != 2 || result.points[1].x != 3): return 5
	if (result.labels[c"a"] != 9 || result.title != s"collection"): return 6
	if (from_json(ast_json_point, 0) != 0): return 7
	json_free(encoded)
	free(decoded)
	return 0
