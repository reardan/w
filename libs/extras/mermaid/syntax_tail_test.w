# wbuild: x64
# Sequence half-arrows and ZenUML participant icons, stereotypes, widths and colours.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render
import libs.extras.mermaid.serialize
import libs.extras.mermaid.serialize_equal

mm_document* tail_parse(char* source):
	mm_document* d = mm_parse(source, strlen(source))
	if (d.error != 0): println2(d.error)
	asserts(c"tail source parses", d.error == 0)
	return d

# Source write is lossless and the canonical form reparses to the same model.
void tail_round_trip(mm_document* d):
	char* written = mm_write(d)
	assert_strings_equal(d.source, written)
	free(written)
	char* canonical = mm_serialize(d)
	asserts(c"tail canonical form exists", canonical != 0)
	mm_document* again = mm_parse(canonical, strlen(canonical))
	if (again.error != 0): println2(canonical)
	asserts(c"canonical form reparses", again.error == 0)
	char* diff = mm_document_diff(d, again)
	if (diff != 0): println2(diff)
	asserts(c"canonical form keeps the model", diff == 0)
	mm_document_free(again)
	free(canonical)

void tail_expect_error(char* source, char* message):
	mm_document* d = mm_parse(source, strlen(source))
	asserts(c"tail diagnostic reported", d.error != 0)
	if (d.error != 0): assert_strings_equal(message, d.error)
	mm_document_free(d)

int tail_lines(mm_scene* scene, int x, int y, int x2, int y2):
	int count = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_LINE && item.x == x && item.y == y && item.x2 == x2 && item.y2 == y2): count = count + 1
	return count

void test_sequence_half_arrows_parse():
	mm_document* d = tail_parse(c"sequenceDiagram\nA-|\\B: top\nA--|\\B: top dotted\nA-|/B: bottom\nA--|/B: bottom dotted\nA-\\\\B: stick top\nA--\\\\B: stick top dotted\nA-//B: stick bottom\nA--//B: stick bottom dotted\nA/|-B: reverse top\nA/|--B: reverse top dotted\nA\\|-B: reverse bottom\nA\\|--B: reverse bottom dotted\nA//-B: reverse stick top\nA//--B: reverse stick top dotted\nA\\\\-B: reverse stick bottom\nA\\\\--B: reverse stick bottom dotted\nA->>B: plain\n")
	assert_equal(17, d.narrative.length)
	assert_equal(2, d.nodes.length)
	for i in range(16):
		mm_narrative_event* e = d.narrative[i]
		assert_equal(5 + i / 2, e.arrow)
		assert_equal(i % 2, e.dashed)
		assert_equal(0, e.from_node)
		assert_equal(1, e.to_node)
	assert_equal(1, d.narrative[16].arrow)
	tail_round_trip(d)
	mm_document_free(d)

void test_sequence_half_arrow_geometry():
	mm_document* d = tail_parse(c"sequenceDiagram\nA-|\\B: top\nA-|/B: bottom\nA-\\\\B: stick\nA/|-B: back\nB//-A: back stick\n")
	mm_scene* scene = mm_render(d)
	asserts(c"half-arrow scene", scene != 0)
	mm_bounds* a = scene.nodes[0]
	mm_bounds* b = scene.nodes[1]
	int ax = a.x + a.w / 2
	int bx = b.x + b.w / 2
	asserts(c"A left of B", ax < bx)
	# -|\ : the top half wing at the receiver.
	assert_equal(1, tail_lines(scene, bx, 170, bx - 10, 162))
	# -|/ : the bottom half wing.
	assert_equal(1, tail_lines(scene, bx, 240, bx - 10, 248))
	# -\\ : a single stick above the line.
	assert_equal(1, tail_lines(scene, bx, 310, bx - 7, 303))
	# /|- : reversed at the sender, wing on top.
	assert_equal(1, tail_lines(scene, ax, 380, ax + 10, 372))
	# B//-A runs right to left; its reversed stick sits at B pointing back to it.
	assert_equal(1, tail_lines(scene, bx, 450, bx - 7, 457))
	char* svg = mm_svg(scene)
	asserts(c"half-arrow svg", index_of(svg, c"<svg") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(d)

void test_zenuml_cloud_annotators():
	mm_document* d = tail_parse(c"zenuml\n@Lambda Fn as Handler\n@S3 Bucket\n@AzureFunction Az\n@pubsub Topic\n@CloudWatch Logs\n@Database Db\n@Widget W\nFn->Bucket: put\n")
	assert_equal(8, d.nodes[0].shape)
	assert_strings_equal(c"Lambda", d.nodes[0].annotation)
	assert_strings_equal(c"Handler", d.nodes[0].label)
	assert_equal(8, d.nodes[1].shape)
	assert_equal(8, d.nodes[2].shape)
	assert_equal(8, d.nodes[3].shape)
	assert_equal(8, d.nodes[4].shape)
	assert_equal(5, d.nodes[5].shape)
	# Unknown annotators keep the stereotype line.
	assert_equal(0, d.nodes[6].shape)
	int color = 0
	char* caption = mm_n_zen_icon(c"lambda", &color)
	assert_strings_equal(c"Fn", caption)
	assert_equal(0xed7100, color)
	free(caption)
	asserts(c"unknown annotator has no icon", mm_n_zen_icon(c"widget", &color) == 0)
	mm_scene* scene = mm_render(d)
	int tiles = 0
	int captions = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_BOX && item.x2 - item.x == 24 && item.y2 - item.y == 24 && item.style.fill == 0xed7100): tiles = tiles + 1
		if (item.kind == MM_TEXT && strcmp(item.text, c"Fn") == 0 && item.font_size == 10): captions = captions + 1
	# One Lambda tile on its participant box (no mirrored actors).
	assert_equal(1, tiles)
	assert_equal(1, captions)
	char* svg = mm_svg(scene)
	asserts(c"tile colour in svg", index_of(svg, c"#ed7100") >= 0)
	asserts(c"tile caption in svg", index_of(svg, c">GCS<") < 0 && index_of(svg, c">PS<") >= 0)
	asserts(c"unknown annotator stereotype", index_of(svg, c"&lt;&lt;Widget&gt;&gt;") >= 0)
	free(svg)
	mm_scene_free(scene)
	tail_round_trip(d)
	mm_document_free(d)

void test_zenuml_every_documented_annotator_has_a_symbol():
	list[char*] kinds = list[char*]{c"CloudWatch", c"CloudFront", c"Cognito", c"DynamoDB", c"EBS", c"EC2", c"ECS", c"EFS", c"ElastiCache", c"ElasticBeantalk", c"ElasticFileSystem", c"Glacier", c"IAM", c"Kinesis", c"Lambda", c"LightSail", c"RDS", c"Redshift", c"S3", c"SNS", c"SQS", c"Sagemaker", c"VPC", c"AzureActiveDirectory", c"AzureBackup", c"AzureCDN", c"AzureDataFactory", c"AzureDevOps", c"AzureFunction", c"AzureSQL", c"CosmosDB", c"LogicApps", c"VirtualMachine", c"BigTable", c"BigQuery", c"CloudCDN", c"CloudDNS", c"CloudInterconnect", c"CloudLoadBalancing", c"CloudSQL", c"CloudStorage", c"DataLab", c"DataProc", c"GoogleIAM", c"GoogleSecurity", c"GoogleVPC", c"PubSub", c"SecurityScanner", c"StackDriver", c"VisionAPI"}
	assert_equal(50, kinds.length)
	for char* kind in kinds:
		string_builder* source = string_from(c"zenuml\n@")
		string_append(source, kind)
		string_append(source, c" P\n")
		mm_document* d = tail_parse(source.data)
		assert_equal(8, d.nodes[0].shape)
		mm_document_free(d)
		string_free(source)
	__w_list_free(cast(__w_list*, kinds))

void test_zenuml_participant_stereotype_width_and_colour():
	mm_document* d = tail_parse(c"zenuml\n@Actor <<Person>> Alice\n<<Repository>> Repo 220 as Order store #FFEBE6\nB #0747a6\n@EC2 Box #333\nAlice->Repo: hi\n")
	assert_equal(1, d.nodes[0].shape)
	assert_strings_equal(c"Person", d.nodes[0].role)
	mm_node* repo = d.nodes[1]
	assert_strings_equal(c"Repository", repo.role)
	assert_equal(220, repo.value_x)
	assert_strings_equal(c"Order store", repo.label)
	assert_equal(MM_STYLE_FILL, repo.style.mask)
	assert_equal(0xffebe6, repo.style.fill)
	assert_equal(0x0747a6, d.nodes[2].style.fill)
	assert_equal(0x333333, d.nodes[3].style.fill)
	assert_equal(8, d.nodes[3].shape)
	mm_scene* scene = mm_render(d)
	int filled = 0
	int white = 0
	for mm_primitive* item in scene.items:
		if (item.kind == MM_BOX && (item.style.mask & MM_STYLE_FILL) && item.style.fill == 0x0747a6): filled = filled + 1
		if (item.kind == MM_TEXT && strcmp(item.text, c"B") == 0 && (item.style.mask & MM_STYLE_TEXT) && item.style.text == 0xffffff): white = white + 1
	assert_equal(1, filled)
	assert_equal(1, white)
	mm_bounds* box = scene.nodes[1]
	asserts(c"declared width honoured", box.w >= 220)
	char* svg = mm_svg(scene)
	asserts(c"stereotype line", index_of(svg, c"«Repository»") >= 0)
	asserts(c"participant colour", index_of(svg, c"#ffebe6") >= 0)
	free(svg)
	mm_scene_free(scene)
	tail_round_trip(d)
	mm_document_free(d)
	# Colours and stereotypes also survive a dark theme.
	mm_document* themed = tail_parse(c"---\nconfig:\n  theme: dark\n---\nzenuml\nB #0747a6\nB->B: x\n")
	mm_scene* dark = mm_render(themed)
	int kept = 0
	for mm_primitive* item in dark.items:
		if (item.kind == MM_BOX && item.style.fill == 0x0747a6): kept = kept + 1
	assert_equal(1, kept)
	mm_scene_free(dark)
	mm_document_free(themed)

void test_zenuml_participant_diagnostics():
	tail_expect_error(c"zenuml\n<<Repo Repo\n", c"ZenUML stereotype requires <<Name>>")
	tail_expect_error(c"zenuml\nRepo #12\n", c"ZenUML participant colour must be #rgb or #rrggbb")
	tail_expect_error(c"zenuml\nRepo 0\n", c"ZenUML participant width must be 1 to 2000")
	tail_expect_error(c"zenuml\nRepo 99999\n", c"ZenUML participant width must be 1 to 2000")
	# ZenUML async messages still take only `->`.
	tail_expect_error(c"zenuml\nA->>B: open\n", c"unsupported sequence message arrow")
	# Every prefix parses or diagnoses without crashing.
	char* source = c"zenuml\n@Lambda <<Svc>> Fn 200 as Handler #ed7100\nsequenceDiagram\n"
	for length in range(strlen(source) + 1):
		mm_document* d = mm_parse(source, length)
		mm_scene* scene = mm_render(d)
		if (scene != 0): mm_scene_free(scene)
		mm_document_free(d)
