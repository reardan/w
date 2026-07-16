# wbuild: x64
/*
libs/extras/vcs/delta.w: binary deltas as an alternative CAS object
encoding (issue #252 wave 3).

Covers, in two layers:

  - The pure algorithm (delta_diff/delta_apply_ops/delta_encode_ops/
    delta_decode_ops/delta_apply), with no CAS store involved: round-
    trips on identical, disjoint, partial-overlap, empty-base,
    empty-target, and target-smaller-than-base inputs; the opcode wire
    format round-trips through encode/decode unchanged; malformed
    opcode streams and out-of-bounds copies fail cleanly.
  - The CAS integration (cas_put_delta/cas_get_resolved): a delta-
    encoded object is transparently reconstructed, resolves through
    plain (non-delta) objects unchanged, produces the exact same id a
    full cas_put of the same content would (storage never changes
    identity), respects the DELTA_MAX_CHAIN_DEPTH() bound by falling
    back to a full snapshot rather than ever chaining deeper, and a
    hand-fabricated corrupted/cyclic chain (built directly with
    cas_put_raw, no filesystem byte-patching needed) reports a clean
    DELTA_ERR_MALFORMED/propagated error instead of crashing or
    hanging.

The store root is pid-scoped under bin/ so the 32- and 64-bit twins can
run in parallel; the final test removes everything it created and
asserts the store directories rmdir cleanly (cas_cas_test's convention).
*/
import lib.testing
import libs.extras.vcs.cas
import libs.extras.vcs.delta


/* --- shared fixtures -------------------------------------------------- */


char* vcdt_repeat(int ch, int n):
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = ch
		i = i + 1
	out[n] = 0
	return out


int vcdt_count_kind(delta_ops* ops, int kind):
	int n = 0
	for delta_op* op in ops.items:
		if (op.kind == kind):
			n = n + 1
	return n


int vcdt_ops_equal(delta_ops* a, delta_ops* b):
	if (a.items.length != b.items.length):
		return 0
	int i = 0
	while (i < a.items.length):
		delta_op* x = a.items[i]
		delta_op* y = b.items[i]
		if (x.kind != y.kind):
			return 0
		if (x.length != y.length):
			return 0
		if (x.kind == DELTA_OP_COPY()):
			if (x.offset != y.offset):
				return 0
		else:
			int j = 0
			while (j < x.length):
				if (x.literal[j] != y.literal[j]):
					return 0
				j = j + 1
		i = i + 1
	return 1


void vcdt_assert_bytes_equal(char* want, int want_len, char* got, int got_len):
	assert_equal(want_len, got_len)
	int i = 0
	while (i < want_len):
		assert_equal(want[i] & 255, got[i] & 255)
		i = i + 1


/* --- pure algorithm: round-trips -------------------------------------- */


void test_delta_diff_apply_identical():
	char* block_a = vcdt_repeat('A', 80)
	char* block_b = vcdt_repeat('B', 80)
	char* block_c = vcdt_repeat('C', 80)
	string_builder* sb = string_new()
	string_append(sb, block_a)
	string_append(sb, block_b)
	string_append(sb, block_c)
	char* base = sb.data
	int base_len = sb.length
	free(sb)
	char* target = path_clone_range(base, base_len)
	int target_len = base_len

	delta_ops* ops = delta_diff(base, base_len, target, target_len)
	assert1(vcdt_count_kind(ops, DELTA_OP_COPY()) >= 1)

	string_builder* encoded = delta_encode_ops(ops)
	assert1(encoded.length < target_len)
	string_free(encoded)

	wresult[delta_apply_result*]* applied = delta_apply_ops(base, base_len, ops)
	assert1(result_is_ok[delta_apply_result*](applied))
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	vcdt_assert_bytes_equal(target, target_len, r.data, r.length)
	delta_apply_result_free(r)

	delta_ops_free(ops)
	free(block_a)
	free(block_b)
	free(block_c)
	free(base)
	free(target)


void test_delta_diff_apply_disjoint():
	char* block_a = vcdt_repeat('A', 80)
	char* block_b = vcdt_repeat('B', 80)
	char* block_c = vcdt_repeat('C', 80)
	char* block_d = vcdt_repeat('D', 80)
	string_builder* sb1 = string_new()
	string_append(sb1, block_a)
	string_append(sb1, block_b)
	char* base = sb1.data
	int base_len = sb1.length
	free(sb1)
	string_builder* sb2 = string_new()
	string_append(sb2, block_c)
	string_append(sb2, block_d)
	char* target = sb2.data
	int target_len = sb2.length
	free(sb2)

	delta_ops* ops = delta_diff(base, base_len, target, target_len)
	assert_equal(0, vcdt_count_kind(ops, DELTA_OP_COPY()))
	assert1(vcdt_count_kind(ops, DELTA_OP_INSERT()) >= 1)

	wresult[delta_apply_result*]* applied = delta_apply_ops(base, base_len, ops)
	assert1(result_is_ok[delta_apply_result*](applied))
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	vcdt_assert_bytes_equal(target, target_len, r.data, r.length)
	delta_apply_result_free(r)

	delta_ops_free(ops)
	free(block_a)
	free(block_b)
	free(block_c)
	free(block_d)
	free(base)
	free(target)


void test_delta_diff_apply_partial_overlap():
	# block_a and block_b are both exactly one DELTA_BLOCK_SIZE() so
	# block_b starts at a block-aligned offset in base (see the header
	# comment: only full block-aligned windows are indexed, so a match
	# requires an exact block-sized common run landing on that grid).
	# block_c and the target's prefix/suffix are deliberately a
	# different size -- they are never meant to match anything.
	char* block_a = vcdt_repeat('A', DELTA_BLOCK_SIZE())
	char* block_b = vcdt_repeat('B', DELTA_BLOCK_SIZE())
	char* block_c = vcdt_repeat('C', 80)
	char* block_x = vcdt_repeat('X', 50)
	char* block_y = vcdt_repeat('Y', 50)
	string_builder* sb1 = string_new()
	string_append(sb1, block_a)
	string_append(sb1, block_b)
	string_append(sb1, block_c)
	char* base = sb1.data
	int base_len = sb1.length
	free(sb1)
	string_builder* sb2 = string_new()
	string_append(sb2, block_x)
	string_append(sb2, block_b)
	string_append(sb2, block_y)
	char* target = sb2.data
	int target_len = sb2.length
	free(sb2)

	delta_ops* ops = delta_diff(base, base_len, target, target_len)
	assert1(vcdt_count_kind(ops, DELTA_OP_COPY()) >= 1)
	assert1(vcdt_count_kind(ops, DELTA_OP_INSERT()) >= 1)

	wresult[delta_apply_result*]* applied = delta_apply_ops(base, base_len, ops)
	assert1(result_is_ok[delta_apply_result*](applied))
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	vcdt_assert_bytes_equal(target, target_len, r.data, r.length)
	delta_apply_result_free(r)

	delta_ops_free(ops)
	free(block_a)
	free(block_b)
	free(block_c)
	free(block_x)
	free(block_y)
	free(base)
	free(target)


void test_delta_diff_apply_empty_base():
	char* block_a = vcdt_repeat('A', 80)
	char* block_b = vcdt_repeat('B', 80)
	string_builder* sb = string_new()
	string_append(sb, block_a)
	string_append(sb, block_b)
	char* target = sb.data
	int target_len = sb.length
	free(sb)

	delta_ops* ops = delta_diff(0, 0, target, target_len)
	assert_equal(0, vcdt_count_kind(ops, DELTA_OP_COPY()))

	wresult[delta_apply_result*]* applied = delta_apply_ops(0, 0, ops)
	assert1(result_is_ok[delta_apply_result*](applied))
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	vcdt_assert_bytes_equal(target, target_len, r.data, r.length)
	delta_apply_result_free(r)

	delta_ops_free(ops)
	free(block_a)
	free(block_b)
	free(target)


void test_delta_diff_apply_empty_target():
	char* base = vcdt_repeat('A', 80)

	delta_ops* ops = delta_diff(base, 80, 0, 0)
	assert_equal(0, ops.items.length)

	wresult[delta_apply_result*]* applied = delta_apply_ops(base, 80, ops)
	assert1(result_is_ok[delta_apply_result*](applied))
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	assert_equal(0, r.length)
	delta_apply_result_free(r)

	delta_ops_free(ops)
	free(base)


void test_delta_diff_apply_target_smaller_than_base():
	# Each segment is exactly one DELTA_BLOCK_SIZE() so block_b lands on
	# a block-aligned offset in base (see the header comment: only
	# full block-aligned windows are indexed).
	int block = DELTA_BLOCK_SIZE()
	char* block_a = vcdt_repeat('A', block)
	char* block_b = vcdt_repeat('B', block)
	char* block_c = vcdt_repeat('C', block)
	char* block_d = vcdt_repeat('D', block)
	string_builder* sb = string_new()
	string_append(sb, block_a)
	string_append(sb, block_b)
	string_append(sb, block_c)
	string_append(sb, block_d)
	char* base = sb.data
	int base_len = sb.length
	free(sb)
	char* target = path_clone_range(block_b, block)
	int target_len = block

	delta_ops* ops = delta_diff(base, base_len, target, target_len)
	assert1(vcdt_count_kind(ops, DELTA_OP_COPY()) >= 1)
	assert1(target_len < base_len)

	wresult[delta_apply_result*]* applied = delta_apply_ops(base, base_len, ops)
	assert1(result_is_ok[delta_apply_result*](applied))
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	vcdt_assert_bytes_equal(target, target_len, r.data, r.length)
	delta_apply_result_free(r)

	delta_ops_free(ops)
	free(block_a)
	free(block_b)
	free(block_c)
	free(block_d)
	free(base)
	free(target)


/* --- pure algorithm: wire format + corruption --------------------------- */


void test_delta_encode_decode_ops_roundtrip():
	# block_b is block-aligned in base (see the header comment) so the
	# diff actually contains a COPY op, exercising both opcode kinds'
	# wire encoding.
	char* block_a = vcdt_repeat('A', DELTA_BLOCK_SIZE())
	char* block_b = vcdt_repeat('B', DELTA_BLOCK_SIZE())
	char* block_x = vcdt_repeat('X', 50)
	string_builder* sb1 = string_new()
	string_append(sb1, block_a)
	string_append(sb1, block_b)
	char* base = sb1.data
	int base_len = sb1.length
	free(sb1)
	string_builder* sb2 = string_new()
	string_append(sb2, block_x)
	string_append(sb2, block_b)
	char* target = sb2.data
	int target_len = sb2.length
	free(sb2)

	delta_ops* ops = delta_diff(base, base_len, target, target_len)
	assert1(vcdt_count_kind(ops, DELTA_OP_COPY()) >= 1)
	assert1(vcdt_count_kind(ops, DELTA_OP_INSERT()) >= 1)
	string_builder* encoded = delta_encode_ops(ops)

	wresult[delta_ops*]* decoded_r = delta_decode_ops(encoded.data, encoded.length)
	assert1(result_is_ok[delta_ops*](decoded_r))
	delta_ops* decoded = result_value[delta_ops*](decoded_r)
	result_free[delta_ops*](decoded_r)
	assert1(vcdt_ops_equal(ops, decoded) != 0)

	# the convenience entry point: decode + apply in one call, from the
	# encoded bytes alone (the shape a stored delta payload's body has).
	wresult[delta_apply_result*]* applied = delta_apply(base, base_len, encoded.data, encoded.length)
	assert1(result_is_ok[delta_apply_result*](applied))
	delta_apply_result* r = result_value[delta_apply_result*](applied)
	result_free[delta_apply_result*](applied)
	vcdt_assert_bytes_equal(target, target_len, r.data, r.length)
	delta_apply_result_free(r)

	delta_ops_free(decoded)
	delta_ops_free(ops)
	string_free(encoded)
	free(block_a)
	free(block_b)
	free(block_x)
	free(base)
	free(target)


void test_delta_corrupted_ops_clean_errors():
	# Unknown opcode tag byte.
	char* garbage = c"Z123\n"
	wresult[delta_ops*]* g = delta_decode_ops(garbage, strlen(garbage))
	assert1(result_is_error[delta_ops*](g))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[delta_ops*](g))
	result_free[delta_ops*](g)

	# An INSERT claiming more literal bytes than remain in the buffer.
	char* truncated = c"I50\nshort"
	wresult[delta_ops*]* t = delta_decode_ops(truncated, strlen(truncated))
	assert1(result_is_error[delta_ops*](t))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[delta_ops*](t))
	result_free[delta_ops*](t)

	# A non-numeric length field.
	char* bad_num = c"Ixx\n"
	wresult[delta_ops*]* n = delta_decode_ops(bad_num, strlen(bad_num))
	assert1(result_is_error[delta_ops*](n))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[delta_ops*](n))
	result_free[delta_ops*](n)

	# A structurally well-formed COPY op whose range falls outside a
	# small base: delta_apply_ops must reject it, not read out of bounds.
	char* base = vcdt_repeat('A', 10)
	delta_ops* bad_ops = new delta_ops
	bad_ops.items = new list[delta_op*]
	delta_ops_push_copy(bad_ops, 0, 999)
	wresult[delta_apply_result*]* applied = delta_apply_ops(base, 10, bad_ops)
	assert1(result_is_error[delta_apply_result*](applied))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[delta_apply_result*](applied))
	result_free[delta_apply_result*](applied)
	delta_ops_free(bad_ops)
	free(base)


/* --- CAS integration ---------------------------------------------------- */


char* vcdt_root_cache
char* vcdt_root():
	if (vcdt_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/vcs_delta_test_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		vcdt_root_cache = p.data
		free(p)
	return vcdt_root_cache


wcas* vcdt_open():
	wresult[wcas*]* r = cas_open(vcdt_root())
	assert1(result_is_ok[wcas*](r))
	wcas* s = result_value[wcas*](r)
	result_free[wcas*](r)
	return s


list[char*] vcdt_ids
void vcdt_track(char* id):
	if (vcdt_ids == 0):
		vcdt_ids = new list[char*]
	vcdt_ids.push(strclone(id))


# A syntactically valid but never-stored 64-hex id, for corruption
# fixtures that need a base id (or self id) with no real object behind
# it, built from a single repeated character.
char* vcdt_fake_id(int ch):
	char* id = malloc(65)
	int i = 0
	while (i < 64):
		id[i] = ch
		i = i + 1
	id[64] = 0
	return id


void test_delta_cas_put_get_resolved_basic():
	wcas* s = vcdt_open()
	char* base_content = vcdt_repeat('A', 200)
	wresult[char*]* bp = cas_put(s, c"blob", base_content, 200)
	assert1(result_is_ok[char*](bp))
	char* base_id = result_value[char*](bp)
	result_free[char*](bp)
	vcdt_track(base_id)

	string_builder* sb = string_new()
	string_append(sb, base_content)
	string_append(sb, c"-appended-tail")
	char* target = sb.data
	int target_len = sb.length
	free(sb)

	wresult[char*]* dp = cas_put_delta(s, base_id, c"blob", target, target_len)
	assert1(result_is_ok[char*](dp))
	char* delta_id = result_value[char*](dp)
	result_free[char*](dp)
	vcdt_track(delta_id)

	# it actually took the delta path: base is well over one block and
	# the chain is only one hop deep.
	wresult[wcas_object*]* raw = cas_get(s, delta_id)
	assert1(result_is_ok[wcas_object*](raw))
	wcas_object* raw_obj = result_value[wcas_object*](raw)
	result_free[wcas_object*](raw)
	assert_strings_equal(c"delta", raw_obj.object_type)
	cas_object_free(raw_obj)

	wresult[wcas_object*]* resolved = cas_get_resolved(s, delta_id)
	assert1(result_is_ok[wcas_object*](resolved))
	wcas_object* robj = result_value[wcas_object*](resolved)
	result_free[wcas_object*](resolved)
	assert_strings_equal(c"blob", robj.object_type)
	vcdt_assert_bytes_equal(target, target_len, robj.data, robj.length)
	cas_object_free(robj)

	# cas_get_resolved on a PLAIN object is a pure pass-through.
	wresult[wcas_object*]* plain = cas_get_resolved(s, base_id)
	assert1(result_is_ok[wcas_object*](plain))
	wcas_object* pobj = result_value[wcas_object*](plain)
	result_free[wcas_object*](plain)
	assert_strings_equal(c"blob", pobj.object_type)
	vcdt_assert_bytes_equal(base_content, 200, pobj.data, pobj.length)
	cas_object_free(pobj)

	free(base_content)
	free(target)
	cas_close(s)


# The identity invariant: an object's id never depends on whether it
# ends up stored full or delta-encoded.
void test_delta_storage_vs_id_invariance():
	wcas* s = vcdt_open()
	char* base_content = vcdt_repeat('Q', 150)
	wresult[char*]* bp = cas_put(s, c"blob", base_content, 150)
	assert1(result_is_ok[char*](bp))
	char* base_id = result_value[char*](bp)
	result_free[char*](bp)
	vcdt_track(base_id)

	string_builder* sb = string_new()
	string_append(sb, base_content)
	string_append(sb, c"-v2-suffix")
	char* v2 = sb.data
	int v2_len = sb.length
	free(sb)

	# The id a full cas_put would compute, WITHOUT touching the store.
	char* expected_id = cas_id_hex(c"blob", v2, v2_len)

	wresult[char*]* dp = cas_put_delta(s, base_id, c"blob", v2, v2_len)
	assert1(result_is_ok[char*](dp))
	char* delta_id = result_value[char*](dp)
	result_free[char*](dp)
	vcdt_track(delta_id)
	assert_strings_equal(expected_id, delta_id)

	wresult[wcas_object*]* raw = cas_get(s, delta_id)
	assert1(result_is_ok[wcas_object*](raw))
	wcas_object* raw_obj = result_value[wcas_object*](raw)
	result_free[wcas_object*](raw)
	assert_strings_equal(c"delta", raw_obj.object_type)
	cas_object_free(raw_obj)

	wresult[wcas_object*]* resolved = cas_get_resolved(s, delta_id)
	assert1(result_is_ok[wcas_object*](resolved))
	wcas_object* robj = result_value[wcas_object*](resolved)
	result_free[wcas_object*](resolved)
	assert_strings_equal(c"blob", robj.object_type)
	vcdt_assert_bytes_equal(v2, v2_len, robj.data, robj.length)
	cas_object_free(robj)

	# Re-storing the same logical content FULL under the same store
	# takes cas_put's dedup path (the id already exists) and must not
	# disturb the delta encoding already on disk.
	wresult[char*]* redundant = cas_put(s, c"blob", v2, v2_len)
	assert1(result_is_ok[char*](redundant))
	char* redundant_id = result_value[char*](redundant)
	result_free[char*](redundant)
	assert_strings_equal(expected_id, redundant_id)
	free(redundant_id)

	wresult[wcas_object*]* still_raw = cas_get(s, delta_id)
	assert1(result_is_ok[wcas_object*](still_raw))
	wcas_object* still_obj = result_value[wcas_object*](still_raw)
	result_free[wcas_object*](still_raw)
	assert_strings_equal(c"delta", still_obj.object_type)
	cas_object_free(still_obj)

	free(expected_id)
	free(base_content)
	free(v2)
	cas_close(s)


# DELTA_MAX_CHAIN_DEPTH() is enforced at write time: a chain of
# successive single-hop deltas must reset to a full snapshot exactly
# when the bound would otherwise be exceeded, and every step -- delta or
# reset -- must still resolve back to its exact content.
void test_delta_chain_depth_bound():
	wcas* s = vcdt_open()
	char* v0 = vcdt_repeat('S', 200)
	wresult[char*]* p0 = cas_put(s, c"blob", v0, 200)
	assert1(result_is_ok[char*](p0))
	char* prev_id = result_value[char*](p0)
	result_free[char*](p0)
	vcdt_track(prev_id)
	char* prev_data = v0
	int prev_len = 200

	int reset_seen = 0
	int step = 1
	while (step <= 20):
		string_builder* sb = string_new()
		string_append_bytes(sb, prev_data, prev_len)
		string_append(sb, c"-x")
		char* next_data = sb.data
		int next_len = sb.length
		free(sb)

		wresult[char*]* put = cas_put_delta(s, prev_id, c"blob", next_data, next_len)
		assert1(result_is_ok[char*](put))
		char* next_id = result_value[char*](put)
		result_free[char*](put)
		vcdt_track(next_id)

		wresult[wcas_object*]* raw = cas_get(s, next_id)
		assert1(result_is_ok[wcas_object*](raw))
		wcas_object* raw_obj = result_value[wcas_object*](raw)
		result_free[wcas_object*](raw)
		int is_delta = strcmp(raw_obj.object_type, c"delta") == 0
		if (step == 17):
			assert_equal(0, is_delta)
			assert_strings_equal(c"blob", raw_obj.object_type)
			reset_seen = 1
		else:
			assert_equal(1, is_delta)
		cas_object_free(raw_obj)

		wresult[wcas_object*]* resolved = cas_get_resolved(s, next_id)
		assert1(result_is_ok[wcas_object*](resolved))
		wcas_object* robj = result_value[wcas_object*](resolved)
		result_free[wcas_object*](resolved)
		vcdt_assert_bytes_equal(next_data, next_len, robj.data, robj.length)
		cas_object_free(robj)

		free(prev_id)
		free(prev_data)
		prev_id = next_id
		prev_data = next_data
		prev_len = next_len
		step = step + 1

	assert_equal(1, reset_seen)
	free(prev_id)
	free(prev_data)
	cas_close(s)


void test_delta_reserved_type_and_invalid_args():
	wcas* s = vcdt_open()
	char* base_content = vcdt_repeat('A', 200)
	wresult[char*]* bp = cas_put(s, c"blob", base_content, 200)
	assert1(result_is_ok[char*](bp))
	char* base_id = result_value[char*](bp)
	result_free[char*](bp)
	vcdt_track(base_id)

	# "delta" is reserved: cas_put_delta refuses to encode an object
	# whose own logical type is "delta".
	wresult[char*]* reserved = cas_put_delta(s, base_id, c"delta", c"x", 1)
	assert1(result_is_error[char*](reserved))
	assert_equal(-22, result_code[char*](reserved))
	result_free[char*](reserved)

	# Malformed base id / type tag / negative length.
	wresult[char*]* bad_base = cas_put_delta(s, c"not-an-id", c"blob", c"x", 1)
	assert1(result_is_error[char*](bad_base))
	assert_equal(-22, result_code[char*](bad_base))
	result_free[char*](bad_base)

	wresult[char*]* bad_tag = cas_put_delta(s, base_id, c"has space", c"x", 1)
	assert1(result_is_error[char*](bad_tag))
	assert_equal(-22, result_code[char*](bad_tag))
	result_free[char*](bad_tag)

	wresult[char*]* bad_len = cas_put_delta(s, base_id, c"blob", c"x", -1)
	assert1(result_is_error[char*](bad_len))
	assert_equal(-22, result_code[char*](bad_len))
	result_free[char*](bad_len)

	# A base id that is well-formed but never stored: propagates
	# cas_get's ENOENT.
	char* absent = vcdt_fake_id('7')
	wresult[char*]* missing_base = cas_put_delta(s, absent, c"blob", c"x", 1)
	assert1(result_is_error[char*](missing_base))
	assert_equal(-2, result_code[char*](missing_base))
	result_free[char*](missing_base)
	free(absent)

	free(base_content)
	cas_close(s)


# Hand-fabricated malformed/cyclic "delta"-typed objects (built directly
# with cas_put_raw -- no on-disk byte-patching needed), each of which
# must fail cleanly through cas_get_resolved rather than crash or hang.
void test_delta_corrupted_chain_clean_errors():
	wcas* s = vcdt_open()

	# A real, valid small base to reference from the well-formed-header
	# fixtures below.
	char* base_content = vcdt_repeat('A', 10)
	wresult[char*]* bp = cas_put(s, c"blob", base_content, 10)
	assert1(result_is_ok[char*](bp))
	char* base_id = result_value[char*](bp)
	result_free[char*](bp)
	vcdt_track(base_id)

	# (a) Not a chain header at all.
	char* id_a = vcdt_fake_id('a')
	wresult[char*]* put_a = cas_put_raw(s, id_a, DELTA_OBJECT_TYPE(), c"not a chain header", 19)
	assert1(result_is_ok[char*](put_a))
	free(result_value[char*](put_a))
	result_free[char*](put_a)
	vcdt_track(id_a)
	wresult[wcas_object*]* got_a = cas_get_resolved(s, id_a)
	assert1(result_is_error[wcas_object*](got_a))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[wcas_object*](got_a))
	result_free[wcas_object*](got_a)
	free(id_a)

	# (b) Well-formed header, but the base id was never stored.
	char* id_b = vcdt_fake_id('b')
	char* missing_base = vcdt_fake_id('c')
	string_builder* sb_b = string_new()
	string_append(sb_b, c"base ")
	string_append(sb_b, missing_base)
	string_append(sb_b, c"\ntype blob\ndepth 1\nlength 0\n\n")
	wresult[char*]* put_b = cas_put_raw(s, id_b, DELTA_OBJECT_TYPE(), sb_b.data, sb_b.length)
	assert1(result_is_ok[char*](put_b))
	free(result_value[char*](put_b))
	result_free[char*](put_b)
	vcdt_track(id_b)
	string_free(sb_b)
	wresult[wcas_object*]* got_b = cas_get_resolved(s, id_b)
	assert1(result_is_error[wcas_object*](got_b))
	assert_equal(-2, result_code[wcas_object*](got_b))
	result_free[wcas_object*](got_b)
	free(id_b)
	free(missing_base)

	# (c) Valid, existing base, but a COPY opcode reaching outside it.
	char* id_c = vcdt_fake_id('d')
	string_builder* sb_c = string_new()
	string_append(sb_c, c"base ")
	string_append(sb_c, base_id)
	string_append(sb_c, c"\ntype blob\ndepth 1\nlength 5\n\n")
	string_append(sb_c, c"C0 999\n")
	wresult[char*]* put_c = cas_put_raw(s, id_c, DELTA_OBJECT_TYPE(), sb_c.data, sb_c.length)
	assert1(result_is_ok[char*](put_c))
	free(result_value[char*](put_c))
	result_free[char*](put_c)
	vcdt_track(id_c)
	string_free(sb_c)
	wresult[wcas_object*]* got_c = cas_get_resolved(s, id_c)
	assert1(result_is_error[wcas_object*](got_c))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[wcas_object*](got_c))
	result_free[wcas_object*](got_c)
	free(id_c)

	# (d) A declared length that does not match the reconstructed size.
	char* id_d = vcdt_fake_id('e')
	string_builder* sb_d = string_new()
	string_append(sb_d, c"base ")
	string_append(sb_d, base_id)
	string_append(sb_d, c"\ntype blob\ndepth 1\nlength 999\n\n")
	string_append(sb_d, c"C0 5\n")
	wresult[char*]* put_d = cas_put_raw(s, id_d, DELTA_OBJECT_TYPE(), sb_d.data, sb_d.length)
	assert1(result_is_ok[char*](put_d))
	free(result_value[char*](put_d))
	result_free[char*](put_d)
	vcdt_track(id_d)
	string_free(sb_d)
	wresult[wcas_object*]* got_d = cas_get_resolved(s, id_d)
	assert1(result_is_error[wcas_object*](got_d))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[wcas_object*](got_d))
	result_free[wcas_object*](got_d)
	free(id_d)

	# (e) A self-referential chain (base id == its own id): must fail
	# after a bounded number of hops, not recurse forever.
	char* id_e = vcdt_fake_id('f')
	string_builder* sb_e = string_new()
	string_append(sb_e, c"base ")
	string_append(sb_e, id_e)
	string_append(sb_e, c"\ntype blob\ndepth 1\nlength 0\n\n")
	wresult[char*]* put_e = cas_put_raw(s, id_e, DELTA_OBJECT_TYPE(), sb_e.data, sb_e.length)
	assert1(result_is_ok[char*](put_e))
	free(result_value[char*](put_e))
	result_free[char*](put_e)
	vcdt_track(id_e)
	string_free(sb_e)
	wresult[wcas_object*]* got_e = cas_get_resolved(s, id_e)
	assert1(result_is_error[wcas_object*](got_e))
	assert_equal(DELTA_ERR_MALFORMED(), result_code[wcas_object*](got_e))
	result_free[wcas_object*](got_e)
	free(id_e)

	free(base_content)
	cas_close(s)


# Runs last (tests execute in definition order): removes exactly the
# objects the run created, then asserts the store directories rmdir
# cleanly -- which also proves no temp files leaked from the put paths.
void test_delta_cleanup_store():
	wcas* s = vcdt_open()
	assert1(vcdt_ids != 0)
	for char* id in vcdt_ids:
		string_builder* p = string_new()
		string_append(p, vcdt_root())
		string_append(p, c"/objects/")
		string_append_char(p, id[0])
		string_append_char(p, id[1])
		string_append_char(p, '/')
		string_append(p, id + 2)
		vcs_unlink(p.data)   # duplicates return -2; ignored
		string_free(p)
	for char* fan_id in vcdt_ids:
		string_builder* d = string_new()
		string_append(d, vcdt_root())
		string_append(d, c"/objects/")
		string_append_char(d, fan_id[0])
		string_append_char(d, fan_id[1])
		rmdir(d.data)    # duplicates return -2; ignored
		string_free(d)
	char* objects = path_join(vcdt_root(), c"objects")
	assert_equal(0, rmdir(objects))
	free(objects)
	assert_equal(0, rmdir(vcdt_root()))
	cas_close(s)
