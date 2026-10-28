# Audited runtime implementation pins for the experimental safe subset.
# Only the call allowlist in safe.w exposes entry points. Any edit to this
# closure requires review of allocation, bounds and output contracts and
# an updated SHA-256 here; alternate import roots cannot inherit trust.
import lib.sha256

char* safe_runtime_digest(char* path):
	if (ends_with(path, c"/lib/memory_provenance.w")): return c"88baf017bcdc13ec82c59c63d38fcf6b3e22be44c3e554c319259d22c64159fc"
	if (ends_with(path, c"/lib/safe_foreign_owner.w")): return c"0bddc7c2a00a2478f14e9aa0ab6b472e5f9c3ef20fcd5c5c56771f584b7d682e"
	if (ends_with(path, c"/lib/safe_typed_arena.w")): return c"93ea2de75ad2609d3d62578e48a75c8fc9eec565d47ec2f940a0c533780ee4d2"
	if (ends_with(path, c"/lib/safe_keyed_map.w")): return c"81d55248c6cc3e43a16ca73b9a701af63a7e20172767c94a8d598be5bf180dde"
	if (ends_with(path, c"/lib/safe_hash.w")): return c"d17e7e8030b112ef4532d71b1c1142f24dff5242fcba7b7576b86caa9bc59660"
	if (ends_with(path, c"/lib/safe_owned_vector.w")): return c"a2c00bac9caea4e5ad93e427ea794f80603fcd6ca610963c5ad210915e9a2630"
	if (ends_with(path, c"/lib/safe_vector.w")): return c"d430d21aaa3f39358a4ca381f6d519ae5f2ec90de9ed7aa3cfabba1db6c76757"
	if (ends_with(path, c"/lib/__arch__/arm64_darwin/android.w")): return c"c3dedd9815d6a3b7af6d035889328b6028af988db1caac5b10e6beba63413ee3"
	if (ends_with(path, c"/lib/__arch__/arm64_darwin/context.w")): return c"23abb972c712b19cdb7de44245451521ed6c6786039b51e5f4cb378f32e25547"
	if (ends_with(path, c"/lib/__arch__/arm64_darwin/syscalls.w")): return c"8b84efac43cc93406bd727f606b115f80b25b44ea5e90e962cba24958243c899"
	if (ends_with(path, c"/lib/darwin/context.w")): return c"64f2850916e604040424c9526d37dc186f5bd133570cad3877613ebe0b6fc511"
	# Metadata conversion uses fixed 144-byte input / 256-byte output bounds;
	# no allocation or ownership changes, and no new checked-call entry points.
	if (ends_with(path, c"/lib/darwin/syscalls.w")): return c"45c22f1278fe2e06a0548c78e3ebdcb0da7cb3b09b70f82b58f6e3315e582e61"
	if (ends_with(path, c"/lib/darwin/stat_layout.w")): return c"40e7339c326b459131b7a269db5a306d55f363e98f14750a96c78fb68a00a72c"
	if (ends_with(path, c"/lib/__arch__/arm64/android.w")): return c"c3dedd9815d6a3b7af6d035889328b6028af988db1caac5b10e6beba63413ee3"
	if (ends_with(path, c"/lib/__arch__/arm64/context.w")): return c"4a3249682fcff806dcc692c06388800598401f230dba49dc8deb231c28009438"
	if (ends_with(path, c"/lib/__arch__/arm64/syscalls.w")): return c"e4832ebe92ac88c25e42727364730a0b5fb1bde92409dad527047663ede683fa"
	if (ends_with(path, c"/lib/arm64/android_stat.w")): return c"01e04f94d5c3e5219a3e566c2acbd50146476f7d9ad4e009bdc642d437c1f483"
	if (ends_with(path, c"/lib/arm64/context.w")): return c"bdfaef1c545673869c21dea6e56c94fb161ffc2f00ea465e8149e472268f18f3"
	if (ends_with(path, c"/lib/arm64/syscalls.w")): return c"ed4eb5b28f5f92d6d8b9bbabd43002eada6f57f375295913c48a0d937c2c2514"
	if (ends_with(path, c"/lib/context_aarch64.w")): return c"fc896005c22d77c26b4e6f0a96aa744a6a8d854a69c2e6eebfb4542291a48fae"
	if (ends_with(path, c"/lib/fs_flags_arm64.w")): return c"fd653201b5973344f8bffe4dadf750c7f48d54c7b8e5c43e8a4ebc5a3b274fc6"
	if (ends_with(path, c"/lib/__arch__/wasm/android.w")): return c"c3dedd9815d6a3b7af6d035889328b6028af988db1caac5b10e6beba63413ee3"
	if (ends_with(path, c"/lib/__arch__/wasm/context.w")): return c"30ec7e03748df436e5789f2a421a8840c6e5fa92a658f5dbf83e1b85140449fa"
	if (ends_with(path, c"/lib/__arch__/wasm/syscalls.w")): return c"692d423a85153365205ff59d4e9fdaad144bbd42a3f1048b75d0b6e3bf671ebf"
	if (ends_with(path, c"/lib/__arch__/win64/android.w")): return c"c3dedd9815d6a3b7af6d035889328b6028af988db1caac5b10e6beba63413ee3"
	if (ends_with(path, c"/lib/__arch__/win64/context.w")): return c"f046288e32fb6135d7b485b97a13beae0b44e22cd8306f9b86957c1234326c81"
	# Wide (UTF-16) file, directory and startup calls: each conversion buffer
	# is a fresh VirtualAlloc released before the wrapper returns (getcwd
	# copies into the caller's buffer only after checking its size); the
	# startup argv/environment copies live for the process, as before. No
	# allocator or ownership changes, and no new checked-call entry points.
	if (ends_with(path, c"/lib/__arch__/win64/syscalls.w")): return c"cb7a286400f6bd79bf23995647931d29422d0acf4b377fc321f6c638dbc012cf"
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
	# malloc_host_freelist_mode only fixes the backend choice before the
	# first allocation; memory_debug retries a failed free-time mprotect
	# after draining its quarantine. No allocation, bounds or output change.
	if (ends_with(path, c"/lib/memory.w")): return c"6f777b0997260ae2c4ea8c527ad70b916a79d17e916148a70f901c9935699b7a"
	if (ends_with(path, c"/lib/memory_debug.w")): return c"e2ee8be6fca7a3510eb1cba141b6fd1702dc001a68a163e10600b36f906c3926"
	if (ends_with(path, c"/lib/memory_freelist.w")): return c"3914deeecbd1076336d7d71c7ef948d437b5f2784de641b5e9b73134acdfd317"
	if (ends_with(path, c"/lib/not_android.w")): return c"0b7879e15efa239e400be597aea6bf591c1348a81c35c76b2fe598a194903032"
	if (ends_with(path, c"/lib/page_size.w")): return c"3bb1e2cc78bf4dea25ab2c2b59af56be951f5b8fbf8de281710c5ab866c7f572"
	if (ends_with(path, c"/lib/safe_foreign.w")): return c"bc265181309880ad5416d81d722a18b08cd0df30a4fb8ce3cf045aba52d5c18d"
	if (ends_with(path, c"/lib/safe_buffer.w")): return c"4b8efc51230de13849f81ec1dfbcf27cd995c1f2e0df9c09aa3a6caeea283b12"
	if (ends_with(path, c"/lib/safe_thread.w")): return c"a064d476124a979d8d340b57a08dc64b7c62179c17466078baa7f5cfbcc591fa"
	# #699 review fixes: cond_wait reads seq atomically, the spawn ack reset
	# is an explicit relaxed store, and th_register clears a partial
	# registration; no allocation, ownership or entry-point changes.
	if (ends_with(path, c"/lib/thread.w")): return c"a73fd03167a42f4b152918f16ad7528dbcc9f0e74cd8c96dd9dd30b9884554f5"
	# The handler thunk also passes SysV registers (wllvm); its page and
	# allocation are unchanged.
	if (ends_with(path, c"/lib/signal.w")): return c"62ee27c31dbac1e17f4390b2824ca74e0279d9b039af6be8b005b67b2e148d57"
	if (ends_with(path, c"/lib/assert.w")): return c"56820763fe87be4f94c1212ac3d4badfc28baf6598137477e14ccdde0159c9d4"
	if (ends_with(path, c"/lib/thread_heap.w")): return c"d41ee413ab1b5f636599f62d7526c4d4b269010073e20d58810441fa3d68b01f"
	# st_call_site accepts LLVM's indirect call forms; reads stay bounded
	# by the same st_base check.
	if (ends_with(path, c"/lib/stack_trace.w")): return c"40acb1c77dba5d72aa0b2de333c115bc7284626ab1d114599c79fa4bb17a7b52"
	if (ends_with(path, c"/lib/syscalls_linux_x86.w")): return c"8f9eeccd5c165f9c89b482c2e97b0b5d6171c6aff16b538ce383bd4b0fe5119d"
	if (ends_with(path, c"/lib/valgrind.w")): return c"793fe83498d76b5e8840c7ecdd807de90b935cd20a57eee6ec532105d93459dd"
	if (ends_with(path, c"/lib/win32_stubs.w")): return c"7a5c41c01f0b3278c637301f2797b2e5002231003d12b696220c63c361b704f1"
	if (ends_with(path, c"/structures/hash_table.w")): return c"d0d9411e5cc530b3b4cbb14f76ccf7ccdbf37fd9c51b7073c8cddd133e08c8ef"
	if (ends_with(path, c"/structures/prelude.w")): return c"f31e10b8d3101e7087b15f61307bfafd3a3ab8af534ccc91d1a1d73151786867"
	if (ends_with(path, c"/structures/w_list.w")): return c"b875e28fb7e09e3278943aa95e6586f41973654ad903dca29369f534abd09a25"
	return 0
