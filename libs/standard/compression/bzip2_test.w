# wbuild: x64
# wbuild: step="bin/bzip2_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
/*
libs/standard/compression/bzip2.w tests. The bz_fx_* fixtures were made
with CPython's bz2.compress (libbzip2 1.0.8); inputs too large to embed
are regenerated here by the same deterministic generators the fixture
script used:

  lcg(n, seed, f): x = (x * 1103515245 + 12345) & 0x7fffffff per byte
  letters = f(x) = 97 + (x >> 16) % 26, random = f(x) = (x >> 16) & 255
  bz_fx_small  = compress(b"Hello, bzip2! The quick brown fox jumps over the lazy dog.\n")
  bz_fx_all256 = compress(bytes(range(256)))
  bz_fx_runs   = compress(runs()): a run of (k*37+1)&255 of each length
                 1..8, 250..261, 300, 509, 1000, each followed by 0x7e
  bz_fx_multi  = compress(101-byte letters(seed 7) phrase repeated to
                 250000 bytes, level 1): three 100k blocks
  bz_fx_big    = compress(251-byte letters(seed 3) phrase repeated to
                 1000000 bytes, level 9): two 900k blocks
  bz_fx_random = compress(lcg(1500, 11, random))
  bz_fx_first / bz_fx_second = compress(b"first stream|") / (b"second stream")
  bz_fx_empty  = compress(b"")
*/
import lib.testing
import structures.string
import lib.hex
import libs.standard.compression.bzip2


char* bz_fx_empty(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a683917724538509000000000")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_small(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a683931415926535914c3b0a6000007df80001060051000004004003ffffff0200048a9ea66a1843468d184d9")
	string_append(s, c"21864c9810c00134f452791389bea1574fba6dbcc11209220495da2571a070e1be3f0c2cf352cba180377f4a1a17")
	string_append(s, c"724538509014c3b0a6")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_all256(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a6839314159265359b6b5ee950000007fffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
	string_append(s, c"ffffffffffb000c5520000000000000000000000000000000001300980000000000000000000004c0004c0049800")
	string_append(s, c"26000260000000000000000000000000000000000000000000000000000000024c00130001300000000000000000")
	string_append(s, c"0000000000000000000000000000000000000003f0080c1014181c2024282c3034383c4044484c5054585c606468")
	string_append(s, c"6c7074787c8084888c9094989ca0a4a8acb0b4b8bcc0c4c8ccd0d4d8dce0e4e8ecf0f4f8fd0105090d1115191d21")
	string_append(s, c"25292d3135393d4145494d5155595d6165696d7175797d8185898d9185898d9195999da1a5a9adb1b5b9bdc1c5c9")
	string_append(s, c"cdd1d5d9dde1e5e9edf1f5f9fe02060a0e12161a1e22262a2e32363a3e42464a565a5e62666a6e72767a7e82868a")
	string_append(s, c"8e92969a9ea2a6aaaeb2b6babec2c6caced2d6dadee2e6eaeef2f6faff03070b0f13171b171b1f23272b2f33373b")
	string_append(s, c"3f43474b4f53575b5f63676b6f73777b7f83878b8f93979b9fa3a7abafb3b7bbbfc3c7cbcfd3d7dbdfe3e7ebeff3")
	string_append(s, c"f45dc914e14242dad7ba54")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_runs(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a6839314159265359ca2a347800000156affc9001248009200049010248001240000000928001f82000742353")
	string_append(s, c"2a7a9a3027b50340d92834d28034d191932003173f384653ab000b47c4ae410b8bc70574aca1458008620ea86990")
	string_append(s, c"2cc214c6822863be3d5f355aad164d2e9e175614ba141a130619a186064e1c450c3832a8711430fcbb615bfb3e7e")
	string_append(s, c"09be2b2c7f8bb9229c284865151a3c00")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_multi(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a6831314159265359dbfd58220060ab01802ffffff040029c00000a0006819320a0006819320a00068193204d")
	string_append(s, c"554c44f2644f51e44d3ea08650430821a410ce0869043ee086504358219c10e5086a843f60879821d60879821c41")
	string_append(s, c"0d2086b0438421de086f0435821d60865043b410f50435821bc10c608730438821bc10da08730439821a410f1210")
	string_append(s, c"ca821e208710436421c410e9043a410f1043bc10f5043b7f210da086f0433821cc10d6086704308218c10e904338")
	string_append(s, c"21fb043dc10ca087e410de087a821ba10c208650436821ac10f5043cc10ec8437821d60875a0863043c410f70434")
	string_append(s, c"821f208730430821ee086c843e410d60861da0871043f208630432821cc10ef0432421e608630431821fe6282b24")
	string_append(s, c"ca6b3313fae26002a8903005fffffe0800538000014000d0326414000d0326414000d0326409aaa8c80c4d0c89a7")
	string_append(s, c"48218c10e3043b410eb043b410d608630432821d6086e843c67043dc10d60873821ac10da08778219c10da086504")
	string_append(s, c"3d410ce08728218c10e7043e410ca087a8218410de086a843cc10ce086f0437821da0869410c6821a410da086704")
	string_append(s, c"36821c20870821a410ef043e210fe8219c10f3043a410de0865043a410e30430421c20874821ee087d8218c10f50")
	string_append(s, c"43cc10f90435821c6086304334219410f9043c410e70435821ca0872210c20868843ec10ed043f410de0871421f6")
	string_append(s, c"0866843f410ca0873821b410f50439410c6086e843bc10c608788218410c2087f98a0ac9329acf3f99871800f7b0")
	string_append(s, c"0c017fffff820012e000014000d0326414000d0326414000d0326409aaa8c40d320c89a730863541c421d421d021")
	string_append(s, c"d421e0218d5067541d021bd5067541eea835aa0c821a84360875aa0cc21b55076aa0f210cc21904310872087c086")
	string_append(s, c"7541e42185506e10d821cbc843b8437086e10ec10d2aa0c410d2a8360869541b550700870086a10ec10f9541fd54")
	string_append(s, c"1dc21a043984370867541cc21c4218550700873aa0f610fb5418843d55079087c0878aa0e210c6a83bd506610f95")
	string_append(s, c"41ad5072aa0f010c8219021855069541f421d421f821bd5071aa0fb541dea83f0433aa0e410d821e82190431086f")
	string_append(s, c"541d8218d506b54180430087f8bb9229c28485c9cff278")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_big(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a6839314159265359060ced46041a7501803ffffff060077f00000000000000050000064c8280000326414000")
	string_append(s, c"019320a00000c99050000064c80a5546434d0099a69a9d500ac90057c802bdc015ca00ac900af6805744015dd00a")
	string_append(s, c"f88056f802b1802bea015e900ae880578802b720159c015c100ae08057b802b6402ba4015f100ae90056e402b840")
	string_append(s, c"15ee00ae080576802baa015e900ade805668057b802b82015e100aca00ad500ae68056d00578402b2802bc2015c1")
	string_append(s, c"00ada00ad500ae3005608056100572802bba015e900af90056a80571402b7a015da00af30057e4015d200af48056")
	string_append(s, c"100571402b1802b1402b82015fa00afe802b720158401584015f200ac100af08056c805628057e402bec015c500a")
	string_append(s, c"f50057b802b8c015c900ae48057d402bea01594015b4015ba00af48056c8056d00570402b1802bf2015fc8056900")
	string_append(s, c"56700572402ba2015c600ae280577802bac015ac015e900ae680577402b1802bca015c500aea805668056c805744")
	string_append(s, c"02bf2015aa015a2015f100ac900ac500aee8057b802bca015c500ac600ac900ae50056300578402b9a0158c015d9")
	string_append(s, c"00ad200aeb40158a015be00ad900ac100ad500aee80572802b0802b5802be4015960805608056f402b2402b82015")
	string_append(s, c"e200ade805688056f802b2402b4802be2015e500acd00ad600ade80577402bf4015c100ae100573402bc2015da00")
	string_append(s, c"add0057f4015dd00ad600afd0056a8056680573402bf4015d900ae7005668056300579802b6802ba4015ee00ad10")
	string_append(s, c"0ad900ac200aeb00565005628056f802bda015a2015f600afa805668056880574402b7a01582015b900ad100ae68")
	string_append(s, c"0571fe402b3802b6402b0802b3402bf100ad6802b5802b5402bec015e600ae500577802bac015ce00ad100aea805")
	string_append(s, c"7aa00ad200af080571802bda01584015ee00ae68056a402b5402b3802bba015e900ae480574402b2402b4802b480")
	string_append(s, c"2bca015b2015d900aff31415926535909c6212e0096fd81803ffffff050059c00000000000a00000c99050000064")
	string_append(s, c"c8280000326409aaa8c40013d34d350a00000c991da15394153e054cc2a710a9ca1533854eb054f10a9f21537854")
	string_append(s, c"c42a7d854f70a9d6153c854dd0a9d02a650a9942a661536854ea153e42a750a9ba15320a99854ca153b854ed0a9e")
	string_append(s, c"e1537c2a74854cc2a650a9e61539054d61539c2a6c153c854e4153cc2a650a9b054d61538054c02a601538854f10")
	string_append(s, c"a9ee153e054d6153842a6f854ee153d054fd054ea153dc2a60153842a621531854ca153f054fe0a9ba15300a9805")
	string_append(s, c"4f81530854f30a9b42a630a9fa153e854e10a9ec2a661538054e30a9c6153ec2a7d854e415360a9b82a7b854da15")
	string_append(s, c"360a9942a62153f054fe0a9a054e81538c2a75854e0153842a780a9d82a6a153dc2a73854f10a98854f50a9c2153")
	string_append(s, c"b42a74854da153ac2a7e854d61534854f90a9ca1531854f10a99854f50a9c215310a9ca1538854c42a79854e70a9")
	string_append(s, c"8854ee15340a9d90a98c2a6f0a9b42a6015350a9e21538854c02a6a153e054df0a9be153942a72854ca153c854df")
	string_append(s, c"0a9a42a6f0a9ca15340a9f2153d42a74854d42a6f854f10a9f82a650a99054e70a9e42a770a9b82a7f054f10a9a8")
	string_append(s, c"54fc15350a9d21539c2a7e0a9de1539854e90a98854f415360a9d42a661534854da15300a9d82a78e70a9942a601")
	string_append(s, c"533854d2153e854fb0a9d61534854ec1537c2a610a9ba1534854e70a99c2a740a9b42a73854e90a9f90a9aa153c8")
	string_append(s, c"54d6153e854f41538854cbc054ec1539854d02a76854f6854d02a79854e01537670a98054cc2a73854d6854d6153")
	string_append(s, c"a054f30a9de1538c2a75854e50a9a054d02a7a854da153b854ff17724538509005dffba2")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_random(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a68393141592653593ca07834000181fffffffffffffffffffffffffffffffffffffffbffffffffffffbfffff")
	string_append(s, c"ffffffffffd003fecb9bdb76f6f54eeeb4f57b20d351a3d41936a7910d9268f483218836a6d4d0c691a64d34d0f4")
	string_append(s, c"d43ca346046d4f49a7a19468f534cca6691b49a64c8c047a407a989a068da9ea310d3353d4da9a1e88f29e287926")
	string_append(s, c"c4d4f4d4f4d329b5368d104c0d119a011a64c4d1b44d3434d3136841b202604c99a09b24d943ca33530d023d10c2")
	string_append(s, c"32304c8c08f434983464d034232794da8f464461300d269800192313460934f4469a64d310643464da653d04304f")
	string_append(s, c"53684f53086ca66a1e49e9a04c0864c47a1a6a6653c8d32993693d26ca68c69a4f440d3693013430d4d068181184")
	string_append(s, c"34c130c81ea0027a6a7a840023d01a4600069326984cc930684c4c027a009868260260068004c0268c0068013001")
	string_append(s, c"31326684d30d130346846231a01a000004624da47e927ea99ea9ea7a13d4f24d3d3486d47a10fd537a4468d37a93")
	string_append(s, c"6d4834d3d27a4f48321ea0f50f49ed4201a191a191a6d4c4343c89e934f51b50311ea1a7a8c9a34f506d4681b51a")
	string_append(s, c"0c9ea6f49a9e931a8d3468f2990d25b9ef879004cc9f5fa159b4455c923cb146844e868cb27a8b06ce58c339ddb4")
	string_append(s, c"770ce95d4ac4818f08ccbe7de758d184454891076cf51602baa45b57436c16dea238277b350ad2c356788f6a183f")
	string_append(s, c"6030dc0f7d1526313f01e63b93c2e8f19f84736bc89f31a7138100b8be48213d533ed163fbc5422db8b3c39a578b")
	string_append(s, c"fae5bcf1b3e73936b5de4f6075e7422db61d915f28a32c2bff6a13444ce4e0c4947a64bc3baef56a98971f6438d5")
	string_append(s, c"0eb49040b43ca618f957fdfce15417b53f37689bf60d2a9cc952d5e789a2d9b1e4821ebd8640f0b5d0e72f2646ba")
	string_append(s, c"c35a135e4ef6eb0b00791b0fdba774005f27cac9f01ab86efd2b958df203ef2e2d475954262a9c660d6cc839a4bc")
	string_append(s, c"c402f144df364521d2eaf2208e9f9097379502cc881668af44ffab877f3848ae3dd8514bf0727fd596e0018cdc59")
	string_append(s, c"107aba60c9ccdb67a51e8caf5052840e89fef8ea51a3057ff8686b6387627a62b81e20b7bdfcbf35d6018e3b5b82")
	string_append(s, c"c2dc95c22d1397dda6b2519b06e3fa9b05edacf1ae7c4901eef378867c01e00280f777b9a05c9610b38b0f19ae80")
	string_append(s, c"d61871a2e8c41ba320371a238e69c2ee4e3450013804698fa1a1955539fc1949a10f9ffd980541fe7da7345feea4")
	string_append(s, c"c6fbb57275e8c18809b764b8beb7c647a4f67cbc982213b4233729eaceb75bf3eb0db471cf8b702ce5491a11b8de")
	string_append(s, c"75de42e71218ddca2744e5ef64984c2a257cc90ee3ac07842e5f75340b6f6d8f252c588e12dcae953bf190d28723")
	string_append(s, c"bd6622e17124c85e207fadddec7c3869488f7913ba50e4903f746957696186749522b6039aeccba24d81344d6e5f")
	string_append(s, c"b8424f4e64516b61e7f339f030be4c1bb5ab0cd98984c6f52ce8342d7232d20aff3919bb3aa65c066d847fdefde0")
	string_append(s, c"c3d1de3dc036c3ff9df54d6ca31aaed1b9adaa570d96defd45381285b17f820edc3a938c48526d7eb4bc0e6a7800")
	string_append(s, c"0ed0b8b29e82af2c884eda0c35df5a82a2c7a03fe822ce0ffc5ec7816df070030489694dfbe1c5118a6ae0474ded")
	string_append(s, c"c4b7258c51696dd5ad0495b6d4e559ea01de105d3dd36f31d674626cdee99f9eb0de0edff2b10b19fb77cc8a2e24")
	string_append(s, c"3a79e4447a64f60c4071f6010eb7fd7cd1c15a8ee6e23275153a8c258448264ba22e541d72e89571e9c0681edd53")
	string_append(s, c"59771605881a3d7adb5f3a71683d458876f3901201314625a62aa8fbf8f8fb53eaa854402bab0d1cd9ba36f81fd2")
	string_append(s, c"242bea70a58ca58a31f0e01a5da26fe52978bd647a69d00c5cb991066106945bc7816960a658939025d8f903155d")
	string_append(s, c"317c31ab121c30f2b5ecc62053886139d137ea644bdca4db1af81996288f7168be137f5cf15dd4a3fa8728f74817")
	string_append(s, c"e79f97cf145479835905b7b98662778e60824d25956686cdf01f6d550350947d7dad2871f38fe94f282bad43c756")
	string_append(s, c"a71526ca13c257f75774a7d8d5d2b0a0b62089493f0da0bdaac2030a6bcb25fba4e4f3a908fa6404a7fb47b83a00")
	string_append(s, c"514363e0691f972213b387d7dc24521c6181a652241640916a116d98b643760f2e22993afad8a3a421e3ae07b2c2")
	string_append(s, c"b1e2ee801334ef44cb4dffc6009af0612023045ed0e10817883939224c48f197007c4a8d34d9b6a3e0089229f1af")
	string_append(s, c"22d8c827a4807cda89266338e2684bbbe52972f099c252833f40293dbce79f1ded39e1c486f3042ea6c0aa58bd5a")
	string_append(s, c"2191419315910768ab7d1a19750cc9029640ab870e0fb7b1caaa48e8d495bb3265b04b848cad429d365340fa8209")
	string_append(s, c"e8d737a48783d656674679483916572c4e1b7d0c7187d48d9528546a9ea75d480e4af6383a860364fa05ed371f2e")
	string_append(s, c"a981fa723d728a9a64b5931902f9a67e6550f0e30cb58028183e55a82626825233bda62f788d72dc7d705c5f4bcd")
	string_append(s, c"10d57c385126d9a010b3e36c8f486141fd577a64dbb4afa3db0dfe3e827a9cd321b77615895212d8bc4186ab1466")
	string_append(s, c"70cb9c8579b7096459a36ce1311b4f0147f144cfa8652581e6530d280041e9121ea1890ab577668ade122216ca39")
	string_append(s, c"19e6b2ac8c052eaa7cdcd1ad95862e695d0635bd3bcb0d7083ba15fecbf05649168576c91772453850903ca07834")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_first(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a6839314159265359d0360d6d0000019180400023221c04200031003020189a76264841387e2ee48a70a121a0")
	string_append(s, c"6c1ada")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_fx_second(int* length):
	string_builder* s = string_new()
	string_append(s, c"425a6839314159265359f09397fb000005118040002e039c0020003100d34d0401a3255b0e20f24878bb9229c284")
	string_append(s, c"87849cbfd8")
	char* data = hex_decode(s.data, s.length, length)
	string_free(s)
	return data


char* bz_small_text():
	return c"Hello, bzip2! The quick brown fox jumps over the lazy dog.\n"


char* bz_concat(char* a, int na, char* b, int nb):
	char* out = cast(char*, malloc(na + nb + 1))
	for i in range(na): out[i] = a[i]
	for j in range(nb): out[na + j] = b[j]
	return out


char* bz_letters(int n, int seed):
	char* out = cast(char*, malloc(n + 1))
	int x = seed
	for i in range(n):
		x = (x * 1103515245 + 12345) & 0x7fffffff
		out[i] = 97 + (x >> 16) % 26
	return out


char* bz_periodic(int per, int n, int seed):
	char* p = bz_letters(per, seed)
	char* out = cast(char*, malloc(n + 1))
	for i in range(n): out[i] = p[i % per]
	free(p)
	return out


char* bz_random(int n, int seed):
	char* out = cast(char*, malloc(n + 1))
	int x = seed
	for i in range(n):
		x = (x * 1103515245 + 12345) & 0x7fffffff
		out[i] = (x >> 16) & 255
	return out


char* bz_runs(int* length):
	char* out = cast(char*, malloc(8192))
	int n = 0
	int k = 0
	int len = 1
	while (len <= 1000):
		for i in range(len):
			out[n] = (k * 37 + 1) & 255
			n = n + 1
		out[n] = 0x7e
		n = n + 1
		k = k + 1
		if (len == 8): len = 250
		else if (len == 261): len = 300
		else if (len == 300): len = 509
		else if (len == 509): len = 1000
		else if (len == 1000): len = 1001
		else: len = len + 1
	*length = n
	return out


# Decodes data and checks the output equals want[0..want_len).
void bz_expect(char* data, int length, char* want, int want_len):
	wresult[bzip2_result*]* res = bzip2_decompress(data, length, 0)
	if (result_is_error[bzip2_result*](res)):
		println(bzip2_error_string(result_code[bzip2_result*](res)))
	bzip2_result* r = result_expect[bzip2_result*](res)
	assert_equal(want_len, r.length)
	if (r.length == want_len): assert_bytes_equal(want, r.data, want_len)
	bzip2_result_free(r)


int bz_error_of(char* data, int length, int max_output):
	wresult[bzip2_result*]* res = bzip2_decompress(data, length, max_output)
	if (result_is_ok[bzip2_result*](res)):
		bzip2_result_free(result_value[bzip2_result*](res))
		result_free[bzip2_result*](res)
		return 0
	int code = result_code[bzip2_result*](res)
	result_free[bzip2_result*](res)
	return code


void test_bzip2_empty_stream():
	int fxn = 0
	char* fx = bz_fx_empty(&fxn)
	bz_expect(fx, fxn, c"", 0)
	free(fx)
	# bz2.decompress(b"") == b""
	bz_expect(c"", 0, c"", 0)


void test_bzip2_small_text():
	char* text = bz_small_text()
	int fxn = 0
	char* fx = bz_fx_small(&fxn)
	bz_expect(fx, fxn, text, strlen(text))
	free(fx)


void test_bzip2_all_byte_values():
	char* want = cast(char*, malloc(256))
	for i in range(256): want[i] = i
	int fxn = 0
	char* fx = bz_fx_all256(&fxn)
	bz_expect(fx, fxn, want, 256)
	free(fx)
	free(want)


void test_bzip2_runs():
	int n = 0
	char* want = bz_runs(&n)
	assert_equal(4934, n)
	int fxn = 0
	char* fx = bz_fx_runs(&fxn)
	bz_expect(fx, fxn, want, n)
	free(fx)
	free(want)


void test_bzip2_random_bytes():
	char* want = bz_random(1500, 11)
	int fxn = 0
	char* fx = bz_fx_random(&fxn)
	bz_expect(fx, fxn, want, 1500)
	free(fx)
	free(want)


void test_bzip2_multiple_blocks():
	char* want = bz_periodic(101, 250000, 7)
	int fxn = 0
	char* fx = bz_fx_multi(&fxn)
	bz_expect(fx, fxn, want, 250000)
	free(fx)
	free(want)


void test_bzip2_large_blocks():
	char* want = bz_periodic(251, 1000000, 3)
	int fxn = 0
	char* fx = bz_fx_big(&fxn)
	bz_expect(fx, fxn, want, 1000000)
	free(fx)
	free(want)


void test_bzip2_concatenated_streams():
	int na = 0
	int nb = 0
	char* a = bz_fx_first(&na)
	char* b = bz_fx_second(&nb)
	char* both = bz_concat(a, na, b, nb)
	bz_expect(both, na + nb, c"first stream|second stream", 26)
	free(both)

	int ne = 0
	char* e = bz_fx_empty(&ne)
	char* ea = bz_concat(e, ne, a, na)
	char* eae = bz_concat(ea, ne + na, e, ne)
	bz_expect(eae, ne + na + ne, c"first stream|", 13)
	char* ee = bz_concat(e, ne, e, ne)
	bz_expect(ee, ne + ne, c"", 0)
	free(ee)
	free(eae)
	free(ea)
	free(e)
	free(a)
	free(b)


void test_bzip2_trailing_data():
	int n = 0
	char* a = bz_fx_first(&n)
	# Not a stream: ignored once a stream decoded (CPython semantics).
	char* junk = bz_concat(a, n, c"garbage!", 8)
	bz_expect(junk, n + 8, c"first stream|", 13)
	free(junk)
	char* zeros = bz_concat(a, n, c"\0\0\0\0", 4)
	bz_expect(zeros, n + 4, c"first stream|", 13)
	free(zeros)
	# The start of a second stream that is cut short is an error.
	char* cut = bz_concat(a, n, c"BZh9", 4)
	assert_equal(BZIP2_ERR_TRUNCATED, bz_error_of(cut, n + 2, 0))
	assert_equal(BZIP2_ERR_TRUNCATED, bz_error_of(cut, n + 4, 0))
	free(cut)
	# Garbage alone (no stream decoded yet) is an error.
	assert_equal(BZIP2_ERR_BAD_MAGIC, bz_error_of(c"garbage!", 8, 0))
	free(a)


void test_bzip2_bad_magic():
	int n = 0
	char* a = bz_fx_small(&n)
	a[0] = 'X'
	assert_equal(BZIP2_ERR_BAD_MAGIC, bz_error_of(a, n, 0))
	a[0] = 'B'
	a[3] = '0'
	assert_equal(BZIP2_ERR_BAD_MAGIC, bz_error_of(a, n, 0))
	a[3] = '9'
	# A bad block magic is malformed data.
	a[4] = a[4] ^ 1
	assert_equal(BZIP2_ERR_BAD_DATA, bz_error_of(a, n, 0))
	free(a)


void test_bzip2_crc_mismatch():
	int n = 0
	char* a = bz_fx_small(&n)
	# Bytes 10..13 are the first block's stored CRC (byte aligned).
	a[12] = a[12] ^ 0x40
	assert_equal(BZIP2_ERR_BAD_BLOCK_CRC, bz_error_of(a, n, 0))
	a[12] = a[12] ^ 0x40
	# The stream CRC is the last 32 bits before the padding, so byte
	# n - 2 lies wholly inside it.
	a[n - 2] = a[n - 2] ^ 0x10
	assert_equal(BZIP2_ERR_BAD_STREAM_CRC, bz_error_of(a, n, 0))
	free(a)

	int ne = 0
	char* e = bz_fx_empty(&ne)
	e[ne - 1] = 1
	assert_equal(BZIP2_ERR_BAD_STREAM_CRC, bz_error_of(e, ne, 0))
	free(e)


void test_bzip2_randomised_block_rejected():
	int n = 0
	char* a = bz_fx_small(&n)
	assert_equal(0, a[14] & 128)
	a[14] = a[14] | 128
	assert_equal(BZIP2_ERR_RANDOMIZED, bz_error_of(a, n, 0))
	free(a)


void test_bzip2_every_truncation():
	int n = 0
	char* a = bz_fx_small(&n)
	int cut = 1
	while (cut < n):
		assert_equal(BZIP2_ERR_TRUNCATED, bz_error_of(a, cut, 0))
		cut = cut + 1
	free(a)
	char* m = bz_fx_multi(&n)
	cut = 1
	while (cut < n):
		assert_equal(BZIP2_ERR_TRUNCATED, bz_error_of(m, cut, 0))
		cut = cut + 41
	assert_equal(BZIP2_ERR_TRUNCATED, bz_error_of(m, n - 1, 0))
	free(m)


# Every single-byte corruption of two fixtures fails cleanly (CRCs catch
# whatever the structural checks let through) and never crashes.
void test_bzip2_every_byte_corrupted():
	int n = 0
	char* a = bz_fx_small(&n)
	for i in range(n):
		a[i] = a[i] ^ 0x55
		assert1(bz_error_of(a, n, 0) != 0)
		a[i] = a[i] ^ 0x55
	free(a)
	char* r = bz_fx_runs(&n)
	for j in range(n):
		r[j] = r[j] ^ 0xa3
		assert1(bz_error_of(r, n, 0) != 0)
		r[j] = r[j] ^ 0xa3
	free(r)


void test_bzip2_max_output():
	int n = 0
	char* m = bz_fx_multi(&n)
	assert_equal(BZIP2_ERR_TOO_LARGE, bz_error_of(m, n, 1000))
	assert_equal(BZIP2_ERR_TOO_LARGE, bz_error_of(m, n, 249999))
	assert_equal(0, bz_error_of(m, n, 250000))
	free(m)

	int na = 0
	int nb = 0
	char* a = bz_fx_first(&na)
	char* b = bz_fx_second(&nb)
	char* both = bz_concat(a, na, b, nb)
	assert_equal(BZIP2_ERR_TOO_LARGE, bz_error_of(both, na + nb, 13))
	assert_equal(BZIP2_ERR_TOO_LARGE, bz_error_of(both, na + nb, 25))
	assert_equal(0, bz_error_of(both, na + nb, 26))
	# A trailing empty stream fits an exhausted budget.
	int ne = 0
	char* e = bz_fx_empty(&ne)
	char* ae = bz_concat(a, na, e, ne)
	assert_equal(0, bz_error_of(ae, na + ne, 13))
	free(ae)
	free(e)
	free(both)
	free(a)
	free(b)


# Feeds `data` in chunks of `step` bytes and checks the joined output.
void bz_incremental(char* data, int length, int step, char* want, int want_len):
	bzip2_decompressor* d = bzip2_decompressor_new(0)
	char* got = cast(char*, malloc(want_len + 1))
	int got_len = 0
	int pos = 0
	while (pos < length):
		assert1(bzip2_decompressor_needs_input(d))
		assert_equal(0, bzip2_decompressor_eof(d))
		int k = step
		if (pos + k > length): k = length - pos
		bzip2_result* r = result_expect[bzip2_result*](bzip2_decompressor_decompress(d, &data[pos], k))
		assert1(got_len + r.length <= want_len)
		for i in range(r.length): got[got_len + i] = r.data[i]
		got_len = got_len + r.length
		bzip2_result_free(r)
		pos = pos + k
	assert1(bzip2_decompressor_eof(d))
	assert_equal(0, bzip2_decompressor_needs_input(d))
	assert_equal(want_len, got_len)
	assert_bytes_equal(want, got, want_len)
	free(got)
	bzip2_decompressor_free(d)


void test_bzip2_incremental():
	int n = 0
	char* m = bz_fx_multi(&n)
	char* want = bz_periodic(101, 250000, 7)
	bz_incremental(m, n, 1, want, 250000)
	bz_incremental(m, n, 7, want, 250000)
	bz_incremental(m, n, n, want, 250000)
	free(want)
	free(m)
	char* s = bz_fx_small(&n)
	char* text = bz_small_text()
	bz_incremental(s, n, 1, text, strlen(text))
	free(s)
	char* r = bz_fx_runs(&n)
	int nr = 0
	char* wr = bz_runs(&nr)
	bz_incremental(r, n, 3, wr, nr)
	free(wr)
	free(r)


void test_bzip2_incremental_unused_data_and_eof():
	int na = 0
	int nb = 0
	char* a = bz_fx_first(&na)
	char* b = bz_fx_second(&nb)
	char* both = bz_concat(a, na, b, nb)
	bzip2_decompressor* d = bzip2_decompressor_new(0)
	int unused = 0
	bzip2_decompressor_unused_data(d, &unused)
	assert_equal(0, unused)
	bzip2_result* r = result_expect[bzip2_result*](bzip2_decompressor_decompress(d, both, na + 5))
	assert_equal(13, r.length)
	assert_bytes_equal(c"first stream|", r.data, 13)
	bzip2_result_free(r)
	assert1(bzip2_decompressor_eof(d))
	char* rest = bzip2_decompressor_unused_data(d, &unused)
	assert_equal(5, unused)
	assert_bytes_equal(b, rest, 5)
	wresult[bzip2_result*]* again = bzip2_decompressor_decompress(d, &both[na + 5], nb - 5)
	assert_equal(BZIP2_ERR_EOF, result_code[bzip2_result*](again))
	result_free[bzip2_result*](again)
	bzip2_decompressor_free(d)
	free(both)
	free(a)
	free(b)


void test_bzip2_incremental_errors_are_sticky():
	int n = 0
	char* a = bz_fx_small(&n)
	a[12] = a[12] ^ 1
	bzip2_decompressor* d = bzip2_decompressor_new(0)
	wresult[bzip2_result*]* r1 = bzip2_decompressor_decompress(d, a, 20)
	assert1(result_is_ok[bzip2_result*](r1))
	bzip2_result_free(result_value[bzip2_result*](r1))
	result_free[bzip2_result*](r1)
	wresult[bzip2_result*]* r2 = bzip2_decompressor_decompress(d, &a[20], n - 20)
	assert_equal(BZIP2_ERR_BAD_BLOCK_CRC, result_code[bzip2_result*](r2))
	result_free[bzip2_result*](r2)
	wresult[bzip2_result*]* r3 = bzip2_decompressor_decompress(d, c"", 0)
	assert_equal(BZIP2_ERR_BAD_BLOCK_CRC, result_code[bzip2_result*](r3))
	result_free[bzip2_result*](r3)
	assert_equal(0, bzip2_decompressor_needs_input(d))
	bzip2_decompressor_free(d)
	free(a)

	bzip2_decompressor* cap = bzip2_decompressor_new(10)
	int nm = 0
	char* m = bz_fx_small(&nm)
	wresult[bzip2_result*]* r4 = bzip2_decompressor_decompress(cap, m, nm)
	assert_equal(BZIP2_ERR_TOO_LARGE, result_code[bzip2_result*](r4))
	result_free[bzip2_result*](r4)
	bzip2_decompressor_free(cap)
	free(m)


void test_bzip2_error_strings():
	assert_contains(bzip2_error_string(BZIP2_ERR_BAD_MAGIC), c"magic")
	assert_contains(bzip2_error_string(BZIP2_ERR_TRUNCATED), c"end-of-stream")
	assert_contains(bzip2_error_string(BZIP2_ERR_BAD_DATA), c"malformed")
	assert_contains(bzip2_error_string(BZIP2_ERR_BAD_BLOCK_CRC), c"block CRC")
	assert_contains(bzip2_error_string(BZIP2_ERR_BAD_STREAM_CRC), c"stream CRC")
	assert_contains(bzip2_error_string(BZIP2_ERR_RANDOMIZED), c"randomised")
	assert_contains(bzip2_error_string(BZIP2_ERR_TOO_LARGE), c"max_output")
	assert_contains(bzip2_error_string(BZIP2_ERR_EOF), c"end of stream")
	assert_contains(bzip2_error_string(0), c"ok")
	assert_contains(bzip2_error_string(999), c"unknown")
