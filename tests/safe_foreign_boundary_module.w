# The audited boundary of tests/safe_foreign_owner_runtime_fixture.w. Its raw
# code stands in for a foreign library. The fixture attests this exact file
# by SHA-256, so an edit here needs a reviewed digest update there.
import lib.safe_foreign_owner


struct Resource:
	int value
	int serial


int resource_opened
int resource_released


void resource_release(void* raw):
	resource_released = resource_released + 1
	free(raw)


# Releases an object adopted at an odd address one byte into its allocation.
void resource_release_shifted(void* raw):
	resource_released = resource_released + 1
	free(cast(void*, cast(int, raw) - 1))


optown WForeign[Resource]* resource_open(int value):
	Resource* raw = cast(Resource*, malloc(sizeof(Resource)))
	raw.value = value
	raw.serial = resource_opened
	resource_opened = resource_opened + 1
	return foreign_adopt[Resource](raw, cast(WForeignRelease*, resource_release))


optown WForeign[Resource]* resource_open_null():
	return foreign_adopt[Resource](cast(Resource*, 0), cast(WForeignRelease*, resource_release))


optown WForeign[Resource]* resource_open_misaligned():
	int base = cast(int, malloc(sizeof(Resource) * 2))
	resource_opened = resource_opened + 1
	return foreign_adopt[Resource](cast(Resource*, base + 1), cast(WForeignRelease*, resource_release_shifted))


int resource_value(ref WForeign[Resource]* handle):
	Resource* raw = foreign_raw[Resource](handle)
	return raw.value


void resource_add(refmut WForeign[Resource]* handle, int amount):
	Resource* raw = foreign_raw[Resource](cast(ref WForeign[Resource]*, handle))
	raw.value = raw.value + amount


# The foreign side takes the object, and later releases it, only when
# accept is set. Otherwise the caller gets its owner back.
optown WForeign[Resource]* resource_give(own WForeign[Resource]* handle, int accept):
	if (accept == 0):
		WForeign[Resource]* kept = cast(WForeign[Resource]*, handle)
		WForeign[Resource]** cleared = cast(WForeign[Resource]**, &handle)
		*cleared = cast(WForeign[Resource]*, 0)
		return cast(optown WForeign[Resource]*, kept)
	Resource* raw = foreign_disown[Resource](handle)
	resource_release(cast(void*, raw))
	return cast(optown WForeign[Resource]*, 0)


int resource_live():
	return resource_opened - resource_released
