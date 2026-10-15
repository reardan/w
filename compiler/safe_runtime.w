# Audited runtime implementation pins for the experimental safe subset.
# Only the call allowlist in safe.w exposes entry points. Any edit to this
# closure requires review of allocation, bounds and output contracts and
# an updated SHA-256 here; alternate import roots cannot inherit trust.
import lib.sha256

char* safe_runtime_digest(char* path):
	if (ends_with(path, c"/code_generator/integer.w")): return c"fc29beab52cc9fc74d3db3e3bcdc99e299514b590ce1450626270e924f594bbb"
	if (ends_with(path, c"/lib/__arch__/x64/context.w")): return c"ee3c5d5dc3c91bc1b7c13cf690bf1da4eda806216ee600b2981d5fe793fda032"
	if (ends_with(path, c"/lib/__arch__/x64/syscalls.w")): return c"acd91dabd567bd150ef64d210e56c81ed49a09bbbd115b9831784165912bcedc"
	if (ends_with(path, c"/lib/__arch__/x86/context.w")): return c"0260a9bcfb6bf0e19709785fe03b3eeb330976067253acbafd7917b5129211b8"
	if (ends_with(path, c"/lib/__arch__/x86/syscalls.w")): return c"2fd9083ac4915daaa40834a06d36e616e8dc9496ac4a7567b8951d5d73369ea8"
	if (ends_with(path, c"/lib/context_x86_64.w")): return c"b55b46dadbea0b84030851baff0547a270d22ec48223f758726e4ab9296f50f7"
	if (ends_with(path, c"/lib/hex.w")): return c"1139d5bf87e30a02ca930bb263328ae9a98de64ff4677f997beb933b091d4b8a"
	if (ends_with(path, c"/lib/lib.w")): return c"99ff7467f4af58884c519cb12f17ba0b60b8a2995b647b6e01793b452090ee79"
	if (ends_with(path, c"/lib/linux.w")): return c"5ae29c4590b27cafc55ba12e2e937ebc7271573da57e45545572cec7153930f1"
	if (ends_with(path, c"/lib/memory.w")): return c"0a8898daf1efd532e9e313ae35805502b0af3ab34493b7092a6cdf9ea76764ae"
	if (ends_with(path, c"/lib/memory_debug.w")): return c"193aabc8ea6a07059341fc91401aaa016478a2aad2117dbd37ce243c059b46a5"
	if (ends_with(path, c"/lib/memory_freelist.w")): return c"dcfbe986693222b59979cd332c31d7721589931c71fd9493c72941b3dfeef1a0"
	if (ends_with(path, c"/lib/stack_trace.w")): return c"0d8df02d0e8de652d916098b838838c449411c8a7656bef81247ea15976bb340"
	if (ends_with(path, c"/lib/syscalls_linux_x86.w")): return c"8f9eeccd5c165f9c89b482c2e97b0b5d6171c6aff16b538ce383bd4b0fe5119d"
	if (ends_with(path, c"/lib/win32_stubs.w")): return c"7a5c41c01f0b3278c637301f2797b2e5002231003d12b696220c63c361b704f1"
	if (ends_with(path, c"/structures/hash_table.w")): return c"f68a73c653a288001a84af87d81b64f33dd64958e1558854eb6f7ce8ae1c665b"
	if (ends_with(path, c"/structures/prelude.w")): return c"f31e10b8d3101e7087b15f61307bfafd3a3ab8af534ccc91d1a1d73151786867"
	if (ends_with(path, c"/structures/w_list.w")): return c"36c99b6f29d206b33f872bd03b5e3a667edad7e16002836e786afb2285da31f6"
	return 0
