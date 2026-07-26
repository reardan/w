# wbuild: x64
/*
Leak assertions for libs/extras/protobuf/message.w's decode paths under
the guard-page debug allocator (lib/memory_debug.w, forced on via
malloc_force_debug_mode() -- the same pattern as
tests/memory_debug_test.w). Every scenario that decodes successfully is
torn down through pb_free_decoded; every scenario that fails mid-decode
relies on pb_decode's own error-path cleanup; and
debug_alloc_report_leaks() must see zero unfreed blocks at the end.

Covers the stage-1 hardening backlog's leak items (docs/projects/
ai_tooling_next_steps.md): duplicate STRING and MESSAGE occurrences no
longer leaking the earlier allocation, decode errors no longer leaking
what the partial decode already stored into `out` (including a
partially-built ~150-level nesting chain cut off by the depth limit),
and the repeated-element staging buffer's own error path.

Descriptors mirror tests/protobuf_test.w's file-scope-global +
init-helper shape; wire bytes are hand-derived per the proto3 encoding
rules exactly as that file's vectors are.
*/
import lib.lib
import lib.assert
import lib.memory
import lib.result
import libs.extras.protobuf.varint
import libs.extras.protobuf.wire
import libs.extras.protobuf.message


# msg1: { int32 a = 1; string s = 2; } -- the duplicate/error workhorse.
struct pb_leak_msg:
	int32 a
	pb_bytes s


pb_field_desc[2] pb_leak_msg_fields
pb_message_desc pb_leak_msg_desc


void pb_leak_msg_desc_init():
	pb_leak_msg m
	pb_leak_msg_fields[0].number = 1
	pb_leak_msg_fields[0].kind = PB_KIND_INT32()
	pb_leak_msg_fields[0].offset = cast(int, &m.a) - cast(int, &m)
	pb_leak_msg_fields[0].aux = 0
	pb_leak_msg_fields[1].number = 2
	pb_leak_msg_fields[1].kind = PB_KIND_STRING()
	pb_leak_msg_fields[1].offset = cast(int, &m.s) - cast(int, &m)
	pb_leak_msg_fields[1].aux = 0
	pb_leak_msg_desc.field_count = 2
	pb_leak_msg_desc.fields = pb_leak_msg_fields
	pb_leak_msg_desc.struct_size = 4 + 2 * __word_size__


# pt: { int32 x = 1; int32 y = 2; } held singly by holder (field 3) for
# the duplicate-submessage merge scenario.
struct pb_leak_pt:
	int32 x
	int32 y


struct pb_leak_holder:
	pb_leak_pt* pt


pb_field_desc[2] pb_leak_pt_fields
pb_message_desc pb_leak_pt_desc
pb_field_desc[1] pb_leak_holder_fields
pb_message_desc pb_leak_holder_desc


void pb_leak_holder_desc_init():
	pb_leak_pt pt
	pb_leak_pt_fields[0].number = 1
	pb_leak_pt_fields[0].kind = PB_KIND_INT32()
	pb_leak_pt_fields[0].offset = cast(int, &pt.x) - cast(int, &pt)
	pb_leak_pt_fields[0].aux = 0
	pb_leak_pt_fields[1].number = 2
	pb_leak_pt_fields[1].kind = PB_KIND_INT32()
	pb_leak_pt_fields[1].offset = cast(int, &pt.y) - cast(int, &pt)
	pb_leak_pt_fields[1].aux = 0
	pb_leak_pt_desc.field_count = 2
	pb_leak_pt_desc.fields = pb_leak_pt_fields
	pb_leak_pt_desc.struct_size = 8

	pb_leak_holder hm
	pb_leak_holder_fields[0].number = 3
	pb_leak_holder_fields[0].kind = PB_KIND_MESSAGE()
	pb_leak_holder_fields[0].offset = cast(int, &hm.pt) - cast(int, &hm)
	pb_leak_holder_fields[0].aux = cast(int, &pb_leak_pt_desc)
	pb_leak_holder_desc.field_count = 1
	pb_leak_holder_desc.fields = pb_leak_holder_fields
	pb_leak_holder_desc.struct_size = __word_size__


# rep_str: { repeated string names = 4; } and rep_msg: { repeated msg1
# items = 5; } for the repeated-element error paths.
struct pb_leak_rep:
	char* items


pb_value_desc pb_leak_rep_str_elem
pb_field_desc[1] pb_leak_rep_str_fields
pb_message_desc pb_leak_rep_str_desc
pb_value_desc pb_leak_rep_msg_elem
pb_field_desc[1] pb_leak_rep_msg_fields
pb_message_desc pb_leak_rep_msg_desc


void pb_leak_rep_descs_init():
	pb_leak_rep rm
	pb_leak_rep_str_elem.kind = PB_KIND_STRING()
	pb_leak_rep_str_elem.aux = 0
	pb_leak_rep_str_fields[0].number = 4
	pb_leak_rep_str_fields[0].kind = PB_KIND_REPEATED()
	pb_leak_rep_str_fields[0].offset = cast(int, &rm.items) - cast(int, &rm)
	pb_leak_rep_str_fields[0].aux = cast(int, &pb_leak_rep_str_elem)
	pb_leak_rep_str_desc.field_count = 1
	pb_leak_rep_str_desc.fields = pb_leak_rep_str_fields
	pb_leak_rep_str_desc.struct_size = __word_size__

	pb_leak_rep_msg_elem.kind = PB_KIND_MESSAGE()
	pb_leak_rep_msg_elem.aux = cast(int, &pb_leak_msg_desc)
	pb_leak_rep_msg_fields[0].number = 5
	pb_leak_rep_msg_fields[0].kind = PB_KIND_REPEATED()
	pb_leak_rep_msg_fields[0].offset = cast(int, &rm.items) - cast(int, &rm)
	pb_leak_rep_msg_fields[0].aux = cast(int, &pb_leak_rep_msg_elem)
	pb_leak_rep_msg_desc.field_count = 1
	pb_leak_rep_msg_desc.fields = pb_leak_rep_msg_fields
	pb_leak_rep_msg_desc.struct_size = __word_size__


# Self-recursive message for the depth-limit error path (same builder
# idea as tests/protobuf_test.w's pb_test_build_deep: 6 bytes per
# level -- tag 0x0a plus the remaining byte count as a non-canonical
# 5-byte varint).
pb_field_desc[1] pb_leak_deep_fields
pb_message_desc pb_leak_deep_desc


void pb_leak_deep_desc_init():
	pb_leak_deep_fields[0].number = 1
	pb_leak_deep_fields[0].kind = PB_KIND_MESSAGE()
	pb_leak_deep_fields[0].offset = 0
	pb_leak_deep_fields[0].aux = cast(int, &pb_leak_deep_desc)
	pb_leak_deep_desc.field_count = 1
	pb_leak_deep_desc.fields = pb_leak_deep_fields
	pb_leak_deep_desc.struct_size = __word_size__


char* pb_leak_build_deep(int levels, int* out_len):
	int total = levels * 6
	char* buf = malloc(total)
	int i = 0
	while (i < levels):
		int pos = i * 6
		int payload = total - pos - 6
		buf[pos] = 0x0a
		buf[pos + 1] = 128 | (payload & 127)
		buf[pos + 2] = 128 | (shr(payload, 7) & 127)
		buf[pos + 3] = 128 | (shr(payload, 14) & 127)
		buf[pos + 4] = 128 | (shr(payload, 21) & 127)
		buf[pos + 5] = shr(payload, 28) & 127
		i = i + 1
	out_len[0] = total
	return buf


char* pb_leak_zeroed(int size):
	char* buf = malloc(size)
	int i = 0
	while (i < size):
		buf[i] = 0
		i = i + 1
	return buf


int main():
	malloc_force_debug_mode()
	pb_leak_msg_desc_init()
	pb_leak_holder_desc_init()
	pb_leak_rep_descs_init()
	pb_leak_deep_desc_init()

	# 1. Duplicate string, decode succeeds: the "hi" copy the first
	# occurrence allocated must have been freed when "world" replaced
	# it (proto3 last-one-wins).
	char* buf1 = pb_leak_zeroed(pb_leak_msg_desc.struct_size)
	wresult[char*]* r1 = pb_decode(&pb_leak_msg_desc, c"\x12\x02\x68\x69\x12\x05\x77\x6f\x72\x6c\x64", 11, buf1)
	asserts(c"dup string decodes", result_is_ok[char*](r1))
	pb_leak_msg* m1 = cast(pb_leak_msg*, buf1)
	asserts(c"dup string keeps last", m1.s.length == 5)
	asserts(c"dup string keeps last bytes", m1.s.data[0] == 'w')
	result_free[char*](r1)
	pb_free_decoded(&pb_leak_msg_desc, buf1)
	free(buf1)

	# 2. Error after a stored allocation: field 2 = "hi" decodes and
	# allocates, then field 1's varint payload is missing. The error
	# path must free the stored copy.
	char* buf2 = pb_leak_zeroed(pb_leak_msg_desc.struct_size)
	wresult[char*]* r2 = pb_decode(&pb_leak_msg_desc, c"\x12\x02\x68\x69\x08", 5, buf2)
	asserts(c"string-then-truncation errors", result_is_error[char*](r2))
	asserts(c"string-then-truncation is TRUNCATED", result_code[char*](r2) == PB_ERR_TRUNCATED())
	result_free[char*](r2)
	free(buf2)

	# 3. Duplicate submessage: merge, not replace-and-leak.
	char* buf3 = pb_leak_zeroed(pb_leak_holder_desc.struct_size)
	wresult[char*]* r3 = pb_decode(&pb_leak_holder_desc, c"\x1a\x02\x08\x01\x1a\x02\x10\x02", 8, buf3)
	asserts(c"dup message decodes", result_is_ok[char*](r3))
	pb_leak_holder* h3 = cast(pb_leak_holder*, buf3)
	asserts(c"dup message merged x", h3.pt.x == 1)
	asserts(c"dup message merged y", h3.pt.y == 2)
	result_free[char*](r3)
	pb_free_decoded(&pb_leak_holder_desc, buf3)
	free(buf3)

	# 4. Depth-limit bail-out with ~150 nesting levels already
	# allocated: the partial chain attached to `out` must be swept.
	int deep_len = 0
	char* deep = pb_leak_build_deep(PB_MAX_DECODE_DEPTH() + 50, &deep_len)
	char* buf4 = pb_leak_zeroed(pb_leak_deep_desc.struct_size)
	wresult[char*]* r4 = pb_decode(&pb_leak_deep_desc, deep, deep_len, buf4)
	asserts(c"deep nesting errors", result_is_error[char*](r4))
	asserts(c"deep nesting is DEPTH_EXCEEDED", result_code[char*](r4) == PB_ERR_DEPTH_EXCEEDED())
	result_free[char*](r4)
	free(buf4)
	free(deep)

	# 5. Repeated string: first element decodes (list + copy
	# allocated), second declares length 5 with 2 bytes present. Both
	# the list and the first element's copy must be swept.
	char* buf5 = pb_leak_zeroed(pb_leak_rep_str_desc.struct_size)
	wresult[char*]* r5 = pb_decode(&pb_leak_rep_str_desc, c"\x22\x02\x68\x69\x22\x05\x68\x69", 8, buf5)
	asserts(c"repeated string overrun errors", result_is_error[char*](r5))
	asserts(c"repeated string overrun kind", result_code[char*](r5) == PB_ERR_LENGTH_OVERRUN())
	result_free[char*](r5)
	free(buf5)

	# 6. Repeated message: element 1 (with its own string) lands in the
	# list; element 2's inner decode allocates its string "hi" and THEN
	# hits a truncated varint -- exercising both the staging-buffer
	# cleanup (element 2) and the list-element sweep (element 1).
	char* buf6 = pb_leak_zeroed(pb_leak_rep_msg_desc.struct_size)
	wresult[char*]* r6 = pb_decode(&pb_leak_rep_msg_desc, c"\x2a\x04\x12\x02\x68\x69\x2a\x05\x12\x02\x68\x69\x08", 13, buf6)
	asserts(c"repeated message inner error", result_is_error[char*](r6))
	asserts(c"repeated message inner error kind", result_code[char*](r6) == PB_ERR_TRUNCATED())
	result_free[char*](r6)
	free(buf6)

	asserts(c"protobuf decode paths leaked no blocks", debug_alloc_report_leaks() == 0)
	println2(c"protobuf_leak_test: OK")
	return 0
