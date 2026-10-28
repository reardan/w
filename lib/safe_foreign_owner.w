# Foreign objects behind a checked owner. A WForeign[T] holds one object that
# foreign code allocated and the foreign function that releases it. Checked
# code can move, lend, close or drop the owner, and every path runs the release
# function exactly once. Adoption, raw borrowing and disowning have raw
# signatures, so only audited code calls them: this runtime and modules
# imported with an unsafe "<sha256>" attestation.
import structures.w_list


type WForeignRelease = fn(void*) -> void


struct WForeign[T]:
	T* raw
	WForeignRelease* release


struct __WForeignHeader:
	void* raw
	WForeignRelease* release


# The owner's drop: release the object once, then free the descriptor.
void __w_foreign_drop(void* value):
	__WForeignHeader* handle = cast(__WForeignHeader*, value)
	void* raw = handle.raw
	WForeignRelease* release = handle.release
	handle.raw = 0
	free(handle)
	release(raw)


# The largest power of two dividing size, up to the word size.
int __w_foreign_alignment(int size):
	int alignment = 1
	while ((size > 0) && (alignment < __word_size__) && ((size % (alignment * 2)) == 0)):
		alignment = alignment * 2
	return alignment


# Adoption takes ownership of raw on every path. A null pointer owns nothing
# and yields no owner. A pointer misaligned for T is released at once and
# yields no owner. Otherwise the new owner holds raw until it is dropped.
optown WForeign[T]* foreign_adopt[T](T* raw, WForeignRelease* release):
	if release == 0: __w_trap(c"foreign owner requires a release function")
	if raw == 0: return cast(optown WForeign[T]*, 0)
	if ((cast(int, raw) % __w_foreign_alignment(sizeof(T))) != 0):
		release(cast(void*, raw))
		return cast(optown WForeign[T]*, 0)
	WForeign[T]* handle = cast(WForeign[T]*, __w_new_object(sizeof(WForeign[T])))
	handle.raw = raw
	handle.release = release
	return cast(optown WForeign[T]*, handle)


# Lends the object to one synchronous foreign call. The owner keeps it, and
# the caller must not retain the pointer once the borrow ends.
T* foreign_raw[T](ref WForeign[T]* value):
	WForeign[T]* handle = cast(WForeign[T]*, value)
	return handle.raw


# Hands the object back to foreign code, which then owns it. The descriptor
# is freed without running the release function.
T* foreign_disown[T](own WForeign[T]* value):
	WForeign[T]* handle = cast(WForeign[T]*, value)
	T* raw = handle.raw
	WForeign[T]** transferred = cast(WForeign[T]**, &value)
	*transferred = cast(WForeign[T]*, 0)
	free(handle)
	return raw


# Releases the object now; dropping the consumed parameter runs the release.
void foreign_close[T](own WForeign[T]* value):
	return
