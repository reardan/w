# expect_fail
# expect_stderr: to_json/from_json do not support recursive struct types: 'node'
import structures.json


struct node:
	int x
	list[node] kids


int main():
	node n
	json_value* j = to_json(n)
	return 0
# wbuild: fixture_group=diagnostic_sites_test
