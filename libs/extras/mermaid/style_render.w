import libs.extras.mermaid.style
import libs.extras.mermaid.scene

void mm_style_node(mm_document* d, mm_scene* scene, mm_node* node, int start):
	mm_style resolved
	resolved.mask = 0
	resolved.fill = 0
	resolved.stroke = 0
	resolved.text = 0
	resolved.width = 0
	mm_style_class* definition = mm_style_find(d, c"default")
	if (definition != 0): mm_style_merge(&resolved, &definition.style)
	int begin = 0
	int length = strlen(node.style_classes)
	if (length != 0):
		for i in range(length + 1):
			if (i == length || node.style_classes[i] == ','):
				char* name = mm_style_trim(node.style_classes, begin, i)
				definition = mm_style_find(d, name)
				if (definition != 0): mm_style_merge(&resolved, &definition.style)
				free(name)
				begin = i + 1
	mm_style_merge(&resolved, &node.style)
	for i in range(start, scene.items.length):
		mm_primitive* primitive = scene.items[i]
		primitive.node_style = 1
		mm_style_merge(&primitive.style, &resolved)

void mm_style_scene(mm_document* d, mm_scene* scene):
	if (d.theme == 0): return
	scene.has_background = 1
	scene.background = d.background
	for mm_primitive* primitive in scene.items:
		mm_style resolved = d.palette
		if (primitive.node_style == 0):
			resolved.stroke = d.palette_line
			resolved.text = d.palette_label
		mm_style_merge(&resolved, &primitive.style)
		primitive.style = resolved
