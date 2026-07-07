import lib.testing

# The ops-struct vtable convention (docs/projects/linux_idioms.md): an
# "interface" is a struct of typed function pointers; each concrete
# type embeds a pointer to its shared static vtable as the first field
# (file_operations style). Dispatch helpers cast through void*, and the
# struct-method sugar makes s.area() a virtual call. The fat-pointer
# variant at the bottom (Go/Rust style) keeps concrete structs
# untouched instead.

# --- the interface: shape ---
type shape_area_fn = fn(void*) -> int
type shape_scale_fn = fn(void*, int) -> void

struct shape_vtable:
	shape_area_fn* area
	shape_scale_fn* scale


# Base "view" of any implementing object: vtable pointer first.
struct shape:
	shape_vtable* vt


int shape_area(shape* self):
	return self.vt.area(cast(void*, self))


void shape_scale(shape* self, int factor):
	self.vt.scale(cast(void*, self), factor)


# --- concrete type 1: rect ---
struct rect:
	shape_vtable* vt
	int w
	int h


int rect_area_impl(void* self):
	rect* r = cast(rect*, self)
	return r.w * r.h


void rect_scale_impl(void* self, int factor):
	rect* r = cast(rect*, self)
	r.w = r.w * factor
	r.h = r.h * factor


# Function addresses cannot appear in global initializers, so the
# constructor wires the shared vtable on first use.
shape_vtable rect_vtable

rect* rect_new(int w, int h):
	rect_vtable.area = rect_area_impl
	rect_vtable.scale = rect_scale_impl
	return new rect(&rect_vtable, w, h)


# --- concrete type 2: square ---
struct square:
	shape_vtable* vt
	int side


int square_area_impl(void* self):
	square* s = cast(square*, self)
	return s.side * s.side


void square_scale_impl(void* self, int factor):
	square* s = cast(square*, self)
	s.side = s.side * factor


shape_vtable square_vtable

square* square_new(int side):
	square_vtable.area = square_area_impl
	square_vtable.scale = square_scale_impl
	return new square(&square_vtable, side)


# --- polymorphic use ---
void test_dynamic_dispatch_through_vtable():
	shape* a = cast(shape*, rect_new(3, 4))
	shape* b = cast(shape*, square_new(5))
	assert_equal(12, shape_area(a))
	assert_equal(25, shape_area(b))
	free(a)
	free(b)


void test_heterogeneous_collection():
	list[shape*] shapes = new list[shape*]
	shapes.push(cast(shape*, rect_new(2, 3)))
	shapes.push(cast(shape*, square_new(4)))
	shapes.push(cast(shape*, rect_new(10, 10)))
	int total = 0
	for shape* s in shapes:
		total = total + shape_area(s)
	# 6 + 16 + 100
	assert_equal(122, total)


void test_mutation_through_interface():
	shape* s = cast(shape*, square_new(2))
	shape_scale(s, 3)
	assert_equal(36, shape_area(s))
	free(s)


# Method sugar composes: s.area() lowers to shape_area(s), which
# dispatches through the vtable. Callers get virtual-call syntax today.
void test_method_sugar_over_vtable():
	shape* s = cast(shape*, rect_new(4, 5))
	assert_equal(20, s.area())
	s.scale(2)
	assert_equal(80, s.area())
	free(s)


# --- alternative layout: fat pointer (Go/Rust style) ---
# The interface value is a {data, vtable} pair; concrete structs need
# no embedded vt field and can satisfy many interfaces retroactively.
struct shape_ref:
	void* data
	shape_vtable* vt


int shape_ref_area(shape_ref* self):
	return self.vt.area(self.data)


void test_fat_pointer_dispatch():
	rect* r = rect_new(6, 7)
	shape_ref ref
	ref.data = cast(void*, r)
	ref.vt = &rect_vtable
	assert_equal(42, shape_ref_area(&ref))
	free(r)
