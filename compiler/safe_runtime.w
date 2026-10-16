# Audited runtime implementation pins for the experimental safe subset.
# Only the call allowlist in safe.w exposes entry points. Any edit to this
# closure requires review of allocation, bounds and output contracts and
# an updated SHA-256 here; alternate import roots cannot inherit trust.
import lib.sha256

char* safe_runtime_digest(char* path):
	if (ends_with(path, c"/lib/__arch__/win64/android.w")): return c"c3dedd9815d6a3b7af6d035889328b6028af988db1caac5b10e6beba63413ee3"
	if (ends_with(path, c"/lib/__arch__/win64/context.w")): return c"f046288e32fb6135d7b485b97a13beae0b44e22cd8306f9b86957c1234326c81"
	if (ends_with(path, c"/lib/__arch__/win64/syscalls.w")): return c"546c896edff94904739f5b8ac252f248f6b19cf9ddcae11ebd0dac2a28ca13e2"
	if (ends_with(path, c"/code_generator/integer.w")): return c"fc29beab52cc9fc74d3db3e3bcdc99e299514b590ce1450626270e924f594bbb"
	if (ends_with(path, c"/lib/__arch__/x64/android.w")): return c"c3dedd9815d6a3b7af6d035889328b6028af988db1caac5b10e6beba63413ee3"
	if (ends_with(path, c"/lib/__arch__/x64/context.w")): return c"ee3c5d5dc3c91bc1b7c13cf690bf1da4eda806216ee600b2981d5fe793fda032"
	if (ends_with(path, c"/lib/__arch__/x64/syscalls.w")): return c"acd91dabd567bd150ef64d210e56c81ed49a09bbbd115b9831784165912bcedc"
	if (ends_with(path, c"/lib/__arch__/x86/android.w")): return c"c3dedd9815d6a3b7af6d035889328b6028af988db1caac5b10e6beba63413ee3"
	if (ends_with(path, c"/lib/__arch__/x86/context.w")): return c"0260a9bcfb6bf0e19709785fe03b3eeb330976067253acbafd7917b5129211b8"
	if (ends_with(path, c"/lib/__arch__/x86/syscalls.w")): return c"2fd9083ac4915daaa40834a06d36e616e8dc9496ac4a7567b8951d5d73369ea8"
	if (ends_with(path, c"/lib/context_x86_64.w")): return c"b55b46dadbea0b84030851baff0547a270d22ec48223f758726e4ab9296f50f7"
	if (ends_with(path, c"/lib/hex.w")): return c"1139d5bf87e30a02ca930bb263328ae9a98de64ff4677f997beb933b091d4b8a"
	if (ends_with(path, c"/lib/lib.w")): return c"daf4b14f5e2158d41c808a6b5da1729df00fffad23e2a4d544f305d7d5c23be3"
	if (ends_with(path, c"/lib/linux.w")): return c"e0ba57f22d74e271a6a6db7c55cef38a2943b7fe75a446ba152f766ef36b4cf6"
	if (ends_with(path, c"/lib/memory.w")): return c"82f5225c2eeff87f429a0268de52c84458c3c40e39918b3e384ca391c386b981"
	if (ends_with(path, c"/lib/memory_debug.w")): return c"cb9d16f42f4adee7a6980e44102ae054b222126dcb424740a22771808c24e4a0"
	if (ends_with(path, c"/lib/memory_freelist.w")): return c"3914deeecbd1076336d7d71c7ef948d437b5f2784de641b5e9b73134acdfd317"
	if (ends_with(path, c"/lib/not_android.w")): return c"0b7879e15efa239e400be597aea6bf591c1348a81c35c76b2fe598a194903032"
	if (ends_with(path, c"/lib/page_size.w")): return c"3bb1e2cc78bf4dea25ab2c2b59af56be951f5b8fbf8de281710c5ab866c7f572"
	if (ends_with(path, c"/lib/safe_buffer.w")): return c"4b8efc51230de13849f81ec1dfbcf27cd995c1f2e0df9c09aa3a6caeea283b12"
	if (ends_with(path, c"/lib/stack_trace.w")): return c"91290aa483be398e3b118ca5debc70e9b3f77c88bb422a6fc7337444d8e77f72"
	if (ends_with(path, c"/lib/syscalls_linux_x86.w")): return c"8f9eeccd5c165f9c89b482c2e97b0b5d6171c6aff16b538ce383bd4b0fe5119d"
	if (ends_with(path, c"/lib/valgrind.w")): return c"793fe83498d76b5e8840c7ecdd807de90b935cd20a57eee6ec532105d93459dd"
	if (ends_with(path, c"/lib/win32_stubs.w")): return c"7a5c41c01f0b3278c637301f2797b2e5002231003d12b696220c63c361b704f1"
	if (ends_with(path, c"/structures/hash_table.w")): return c"d0d9411e5cc530b3b4cbb14f76ccf7ccdbf37fd9c51b7073c8cddd133e08c8ef"
	if (ends_with(path, c"/structures/prelude.w")): return c"f31e10b8d3101e7087b15f61307bfafd3a3ab8af534ccc91d1a1d73151786867"
	if (ends_with(path, c"/structures/w_list.w")): return c"b875e28fb7e09e3278943aa95e6586f41973654ad903dca29369f534abd09a25"
	return 0
