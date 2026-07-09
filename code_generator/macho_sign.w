/*
In-house ad-hoc Mach-O code signing for arm64_darwin — Phase 5 of
docs/projects/arm64_stage45_plan.md.

macOS on Apple Silicon refuses to exec an unsigned arm64 main executable,
so every binary the Mach-O writer produces must carry a code signature.
Until now that was `codesign -s -` on the host; this module lets the W
compiler sign its own output, so a cross-compiled binary runs on the Mac
with nothing but a chmod +x.

An ad-hoc signature is a certificate-free SHA-256 tree over the file:

  __LINKEDIT tail:  CS_SuperBlob {
                      CodeDirectory   (per-page SHA-256 + special slots)
                      Requirements    (empty, 12 bytes)
                      CMS wrapper     (empty, 8 bytes — adhoc has no CMS)
                    }

The kernel recomputes the CodeDirectory hash (the "cdhash") at exec and,
for the adhoc flag, trusts it without a cert chain. All multi-byte fields
in the signature are big-endian (network order), unlike the little-endian
Mach-O structures around them, so everything here goes through the be32
helpers rather than emit_int32.

Layout coordination with macho_64.w: the signature data starts at codeLimit
(the current 16-byte-aligned end of file) and becomes __LINKEDIT's tail; a
LC_CODE_SIGNATURE load command pointing at it is appended in the headerpad
at macho_lc_end. Everything up to codeLimit is hashed, so the finish pass
must have patched every header byte (including this signature's own load
command and the __LINKEDIT sizes) before the hashes are computed; the
signature blob itself lies past codeLimit and is not self-referential.
*/
import code_generator.code_emitter
import lib.sha256


int strlen(char *s);
void error(char *s);
int op(int msb, int low);   /* arm64.w */


char* macho_sig_buf
int macho_sig_size
int macho_sig_cap


# CodeDirectory version 0x20400 (adds the exec-segment fields the arm64
# kernel requires), SHA-256, code-signing page size = the 16 KB VM page.
int macho_cd_page_log2():
	return 14


int macho_cd_hash_size():
	return 32


int macho_cd_special_slots():
	return 2   /* -1 Info.plist (absent), -2 Requirements */


# Total size of the embedded-signature SuperBlob for a given hashed length
# and identifier. Depends only on the layout (page count + identifier), not
# on file content, so macho_finish_arm64 can size LC_CODE_SIGNATURE and
# __LINKEDIT before the hashes exist.
int macho_sig_length(int code_limit, char* ident):
	int page = 1 << macho_cd_page_log2()
	int n_code_slots = (code_limit + page - 1) / page
	int hash_size = macho_cd_hash_size()
	int ident_len = strlen(ident) + 1
	int cd_length = 88 + ident_len + macho_cd_special_slots() * hash_size + n_code_slots * hash_size
	# SuperBlob header (12) + 3 index entries (24) + CD + Requirements (12)
	# + empty CMS wrapper (8).
	return 36 + cd_length + 12 + 8


void macho_sig_reserve(int extra):
	if (macho_sig_cap < macho_sig_size + extra):
		int x = (macho_sig_size + extra) << 1
		if (x < 4096):
			x = 4096
		macho_sig_buf = realloc(macho_sig_buf, macho_sig_cap, x)
		macho_sig_cap = x


void macho_sig_be32(int v):
	macho_sig_reserve(4)
	macho_sig_buf[macho_sig_size] = (v >> 24) & 255
	macho_sig_buf[macho_sig_size + 1] = (v >> 16) & 255
	macho_sig_buf[macho_sig_size + 2] = (v >> 8) & 255
	macho_sig_buf[macho_sig_size + 3] = v & 255
	macho_sig_size = macho_sig_size + 4


void macho_sig_int8(int v):
	macho_sig_reserve(1)
	macho_sig_buf[macho_sig_size] = v & 255
	macho_sig_size = macho_sig_size + 1


void macho_sig_bytes(char* p, int n):
	macho_sig_reserve(n)
	int i = 0
	while (i < n):
		macho_sig_buf[macho_sig_size] = p[i]
		macho_sig_size = macho_sig_size + 1
		i = i + 1


# Build the embedded-signature SuperBlob into macho_sig_buf/macho_sig_size.
#   img       : the finished file bytes, contiguous, at least code_limit long
#   code_limit: hashed length = file offset where the signature begins
#   text_size : __TEXT filesize (execSegLimit)
#   ident     : signing identifier (NUL-terminated)
# The produced size equals macho_sig_length(code_limit, ident).
void macho_build_signature(char* img, int code_limit, int text_size, char* ident):
	macho_sig_buf = 0
	macho_sig_cap = 0
	macho_sig_size = 0

	int page = 1 << macho_cd_page_log2()
	int n_code_slots = (code_limit + page - 1) / page
	int n_special = macho_cd_special_slots()
	int hash_size = macho_cd_hash_size()
	int ident_len = strlen(ident) + 1

	# Empty CSMAGIC_REQUIREMENTS SuperBlob (12 bytes); its SHA-256 fills
	# special slot -2. Slot -1 (Info.plist) stays zero.
	char* reqs = malloc(12)
	int z = 0
	while (z < 12):
		reqs[z] = 0
		z = z + 1
	reqs[0] = 250
	reqs[1] = 222
	reqs[2] = 12
	reqs[3] = 1     /* 0xfade0c01 */
	reqs[7] = 12    /* length */

	int header_size = 88
	int ident_off = header_size
	int hash_off = ident_off + ident_len + n_special * hash_size
	int cd_length = hash_off + n_code_slots * hash_size

	int cd_off = 36
	int reqs_off = cd_off + cd_length
	int cms_off = reqs_off + 12
	int total = cms_off + 8

	# --- SuperBlob header + index (CodeDirectory, Requirements, CMS) ---
	macho_sig_be32(op(0xfa, 0xde0cc0))   /* CSMAGIC_EMBEDDED_SIGNATURE */
	macho_sig_be32(total)
	macho_sig_be32(3)
	macho_sig_be32(0)                    /* CSSLOT_CODEDIRECTORY */
	macho_sig_be32(cd_off)
	macho_sig_be32(2)                    /* CSSLOT_REQUIREMENTS */
	macho_sig_be32(reqs_off)
	macho_sig_be32(op(0x00, 0x010000))   /* CSSLOT_SIGNATURESLOT */
	macho_sig_be32(cms_off)

	# --- CodeDirectory ---
	macho_sig_be32(op(0xfa, 0xde0c02))   /* CSMAGIC_CODEDIRECTORY */
	macho_sig_be32(cd_length)
	macho_sig_be32(op(0x00, 0x020400))   /* version */
	macho_sig_be32(2)                    /* flags: adhoc */
	macho_sig_be32(hash_off)
	macho_sig_be32(ident_off)
	macho_sig_be32(n_special)
	macho_sig_be32(n_code_slots)
	macho_sig_be32(code_limit)
	macho_sig_int8(hash_size)
	macho_sig_int8(2)                    /* hashType SHA-256 */
	macho_sig_int8(0)                    /* platform */
	macho_sig_int8(macho_cd_page_log2())
	macho_sig_be32(0)                    /* spare2 */
	macho_sig_be32(0)                    /* scatterOffset (v0x20100) */
	macho_sig_be32(0)                    /* teamOffset (v0x20200) */
	macho_sig_be32(0)                    /* spare3 (v0x20300) */
	macho_sig_be32(0)                    /* codeLimit64 hi */
	macho_sig_be32(0)                    /* codeLimit64 lo */
	macho_sig_be32(0)                    /* execSegBase hi */
	macho_sig_be32(0)                    /* execSegBase lo (fileoff 0) */
	macho_sig_be32(0)                    /* execSegLimit hi */
	macho_sig_be32(text_size)            /* execSegLimit lo */
	macho_sig_be32(0)                    /* execSegFlags hi */
	macho_sig_be32(1)                    /* execSegFlags lo: MAIN_BINARY */

	macho_sig_bytes(ident, ident_len)

	# Special slots stored low-index-last: slot -2 (requirements hash),
	# then slot -1 (absent Info.plist = zero). hashOffset points past them.
	char* digest = malloc(hash_size)
	sha256(reqs, 12, digest)
	macho_sig_bytes(digest, hash_size)   /* slot -2 */
	z = 0
	while (z < hash_size):
		macho_sig_int8(0)                /* slot -1 */
		z = z + 1

	# Code slots: SHA-256 of each page of the file up to code_limit.
	int slot = 0
	while (slot < n_code_slots):
		int start = slot * page
		int len = page
		if (start + len > code_limit):
			len = code_limit - start
		sha256(img + start, len, digest)
		macho_sig_bytes(digest, hash_size)
		slot = slot + 1

	# --- Requirements (slot 2) ---
	macho_sig_bytes(reqs, 12)

	# --- CMS wrapper (slot 0x10000): empty for adhoc ---
	macho_sig_be32(op(0xfa, 0xde0b01))   /* CSMAGIC_BLOBWRAPPER */
	macho_sig_be32(8)

	free(digest)
	free(reqs)
