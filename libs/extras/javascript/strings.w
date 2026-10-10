# Compatibility conversion for char* consumers (module-specifier edits and
# literal property names). New string-value consumers should use text.w.
# This seam rejects embedded NUL and lone surrogates instead of truncating.
import libs.extras.javascript.text


char* js_string_decode(char* raw, pg_diagnostics* diagnostics):
	js_text* value = 0
	if (raw != 0): value = js_text_decode(raw, strlen(raw))
	int length = 0
	char* result = 0
	if (value != 0): result = js_text_to_utf8(value, &length)
	js_text_free(value)
	if (result != 0 && strlen(result) == length): return result
	free(result)
	char* actual = raw
	if (actual == 0): actual = c"null"
	pg_diagnostics_add(diagnostics, c"<JavaScript string>", 1, 1, c"string cannot be represented by this char* AST API", c"non-NUL Unicode scalar values", actual)
	return 0
