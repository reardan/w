# MIME type <-> filename extension mapping, after Python's `mimetypes`
# (plan 08, parity chunk P4.4).
#
# The tables are CPython 3.13's built-in defaults (_types_map_default,
# _common_types_default, _encodings_map_default, _suffix_map_default),
# embedded at the bottom of this file. Unlike Python's module-level
# functions, nothing is read from /etc/mime.types or similar, so results
# match `mimetypes.MimeTypes()` built with no files, on every host.
#
# Semantics follow MimeTypes:
# - Suffix aliases (.tgz -> .tar.gz, .svgz -> .svg.gz, ...) are expanded
#   first, matched case-insensitively.
# - Encoding suffixes (.gz .Z .bz2 .xz .br) are matched case-SENSITIVELY.
# - The type extension is then lowercased (ASCII only) and looked up in
#   the strict table; with strict == 0 the "common but non-standard"
#   table (.jpg image/jpg, .rtf, .mid, ...) is consulted afterwards.
# - guess_type treats a string with a scheme of two or more characters
#   as a URL: the query, fragment and (for http/https/ftp/...) ;params
#   are ignored, and data: URLs yield their declared media type.
#   Anything else is a POSIX path; extensions come from the last path
#   component, and leading dots (".bashrc") are not extensions.
# - add_type keeps Python's quirks: the extension is stored exactly as
#   given (lookups lowercase the query, so add ".foo", not ".FOO"), a
#   later add overrides the default type for that extension, and the
#   extension is appended to the type's reverse list without removing
#   it from any other type's list.
#
# Public API (every returned string is malloc'd and owned by the caller):
#   MimeGuess* mimetypes_guess_type(char* url, int strict = 1)
#   MimeGuess* mimetypes_guess_file_type(char* path, int strict = 1)
#       Never 0; .type / .encoding are 0 when unknown (Python's None).
#   void mime_guess_free(MimeGuess* guess)
#   char* mimetypes_guess_extension(char* type, int strict = 1)  ".ext" or 0
#   list[char*] mimetypes_guess_all_extensions(char* type, int strict = 1)
#   void mimetypes_free_extensions(list[char*] extensions)
#   void mimetypes_add_type(char* type, char* ext, int strict = 1)
#   void mimetypes_init()   forget every add_type, back to the defaults
#
# Differences from Python: lowercasing is ASCII-only; URLs that Python's
# urlparse rejects (bad IPv6 brackets) are not rejected here; there is no
# read()/readfp() of mime.types files and encodings_map/suffix_map are
# not mutable.
import lib.lib
import lib.str


# Result of guess_type: both fields malloc'd or 0 (unknown / no encoding).
struct MimeGuess:
	char* type
	char* encoding


# One add_type registration; type and ext are owned copies.
struct MimeAdded:
	char* type
	char* ext
	int strict


# ---- Generated from CPython 3.13 mimetypes defaults (MimeTypes() with no
# files); do not edit by hand.
int mime_types_count
char*[154] mime_types_key
char*[154] mime_types_value
int mime_common_count
char*[8] mime_common_key
char*[8] mime_common_value
int mime_encodings_count
char*[5] mime_encodings_key
char*[5] mime_encodings_value
int mime_suffixes_count
char*[6] mime_suffixes_key
char*[6] mime_suffixes_value


void mimetypes_load_types():
	mime_types_key[0] = c".js"
	mime_types_value[0] = c"text/javascript"
	mime_types_key[1] = c".mjs"
	mime_types_value[1] = c"text/javascript"
	mime_types_key[2] = c".json"
	mime_types_value[2] = c"application/json"
	mime_types_key[3] = c".webmanifest"
	mime_types_value[3] = c"application/manifest+json"
	mime_types_key[4] = c".doc"
	mime_types_value[4] = c"application/msword"
	mime_types_key[5] = c".dot"
	mime_types_value[5] = c"application/msword"
	mime_types_key[6] = c".wiz"
	mime_types_value[6] = c"application/msword"
	mime_types_key[7] = c".nq"
	mime_types_value[7] = c"application/n-quads"
	mime_types_key[8] = c".nt"
	mime_types_value[8] = c"application/n-triples"
	mime_types_key[9] = c".bin"
	mime_types_value[9] = c"application/octet-stream"
	mime_types_key[10] = c".a"
	mime_types_value[10] = c"application/octet-stream"
	mime_types_key[11] = c".dll"
	mime_types_value[11] = c"application/octet-stream"
	mime_types_key[12] = c".exe"
	mime_types_value[12] = c"application/octet-stream"
	mime_types_key[13] = c".o"
	mime_types_value[13] = c"application/octet-stream"
	mime_types_key[14] = c".obj"
	mime_types_value[14] = c"application/octet-stream"
	mime_types_key[15] = c".so"
	mime_types_value[15] = c"application/octet-stream"
	mime_types_key[16] = c".oda"
	mime_types_value[16] = c"application/oda"
	mime_types_key[17] = c".pdf"
	mime_types_value[17] = c"application/pdf"
	mime_types_key[18] = c".p7c"
	mime_types_value[18] = c"application/pkcs7-mime"
	mime_types_key[19] = c".ps"
	mime_types_value[19] = c"application/postscript"
	mime_types_key[20] = c".ai"
	mime_types_value[20] = c"application/postscript"
	mime_types_key[21] = c".eps"
	mime_types_value[21] = c"application/postscript"
	mime_types_key[22] = c".trig"
	mime_types_value[22] = c"application/trig"
	mime_types_key[23] = c".m3u"
	mime_types_value[23] = c"application/vnd.apple.mpegurl"
	mime_types_key[24] = c".m3u8"
	mime_types_value[24] = c"application/vnd.apple.mpegurl"
	mime_types_key[25] = c".xls"
	mime_types_value[25] = c"application/vnd.ms-excel"
	mime_types_key[26] = c".xlb"
	mime_types_value[26] = c"application/vnd.ms-excel"
	mime_types_key[27] = c".ppt"
	mime_types_value[27] = c"application/vnd.ms-powerpoint"
	mime_types_key[28] = c".pot"
	mime_types_value[28] = c"application/vnd.ms-powerpoint"
	mime_types_key[29] = c".ppa"
	mime_types_value[29] = c"application/vnd.ms-powerpoint"
	mime_types_key[30] = c".pps"
	mime_types_value[30] = c"application/vnd.ms-powerpoint"
	mime_types_key[31] = c".pwz"
	mime_types_value[31] = c"application/vnd.ms-powerpoint"
	mime_types_key[32] = c".wasm"
	mime_types_value[32] = c"application/wasm"
	mime_types_key[33] = c".bcpio"
	mime_types_value[33] = c"application/x-bcpio"
	mime_types_key[34] = c".cpio"
	mime_types_value[34] = c"application/x-cpio"
	mime_types_key[35] = c".csh"
	mime_types_value[35] = c"application/x-csh"
	mime_types_key[36] = c".dvi"
	mime_types_value[36] = c"application/x-dvi"
	mime_types_key[37] = c".gtar"
	mime_types_value[37] = c"application/x-gtar"
	mime_types_key[38] = c".hdf"
	mime_types_value[38] = c"application/x-hdf"
	mime_types_key[39] = c".h5"
	mime_types_value[39] = c"application/x-hdf5"
	mime_types_key[40] = c".latex"
	mime_types_value[40] = c"application/x-latex"
	mime_types_key[41] = c".mif"
	mime_types_value[41] = c"application/x-mif"
	mime_types_key[42] = c".cdf"
	mime_types_value[42] = c"application/x-netcdf"
	mime_types_key[43] = c".nc"
	mime_types_value[43] = c"application/x-netcdf"
	mime_types_key[44] = c".p12"
	mime_types_value[44] = c"application/x-pkcs12"
	mime_types_key[45] = c".pfx"
	mime_types_value[45] = c"application/x-pkcs12"
	mime_types_key[46] = c".ram"
	mime_types_value[46] = c"application/x-pn-realaudio"
	mime_types_key[47] = c".pyc"
	mime_types_value[47] = c"application/x-python-code"
	mime_types_key[48] = c".pyo"
	mime_types_value[48] = c"application/x-python-code"
	mime_types_key[49] = c".sh"
	mime_types_value[49] = c"application/x-sh"
	mime_types_key[50] = c".shar"
	mime_types_value[50] = c"application/x-shar"
	mime_types_key[51] = c".swf"
	mime_types_value[51] = c"application/x-shockwave-flash"
	mime_types_key[52] = c".sv4cpio"
	mime_types_value[52] = c"application/x-sv4cpio"
	mime_types_key[53] = c".sv4crc"
	mime_types_value[53] = c"application/x-sv4crc"
	mime_types_key[54] = c".tar"
	mime_types_value[54] = c"application/x-tar"
	mime_types_key[55] = c".tcl"
	mime_types_value[55] = c"application/x-tcl"
	mime_types_key[56] = c".tex"
	mime_types_value[56] = c"application/x-tex"
	mime_types_key[57] = c".texi"
	mime_types_value[57] = c"application/x-texinfo"
	mime_types_key[58] = c".texinfo"
	mime_types_value[58] = c"application/x-texinfo"
	mime_types_key[59] = c".roff"
	mime_types_value[59] = c"application/x-troff"
	mime_types_key[60] = c".t"
	mime_types_value[60] = c"application/x-troff"
	mime_types_key[61] = c".tr"
	mime_types_value[61] = c"application/x-troff"
	mime_types_key[62] = c".man"
	mime_types_value[62] = c"application/x-troff-man"
	mime_types_key[63] = c".me"
	mime_types_value[63] = c"application/x-troff-me"
	mime_types_key[64] = c".ms"
	mime_types_value[64] = c"application/x-troff-ms"
	mime_types_key[65] = c".ustar"
	mime_types_value[65] = c"application/x-ustar"
	mime_types_key[66] = c".src"
	mime_types_value[66] = c"application/x-wais-source"
	mime_types_key[67] = c".xsl"
	mime_types_value[67] = c"application/xml"
	mime_types_key[68] = c".rdf"
	mime_types_value[68] = c"application/xml"
	mime_types_key[69] = c".wsdl"
	mime_types_value[69] = c"application/xml"
	mime_types_key[70] = c".xpdl"
	mime_types_value[70] = c"application/xml"
	mime_types_key[71] = c".zip"
	mime_types_value[71] = c"application/zip"
	mime_types_key[72] = c".3gp"
	mime_types_value[72] = c"audio/3gpp"
	mime_types_key[73] = c".3gpp"
	mime_types_value[73] = c"audio/3gpp"
	mime_types_key[74] = c".3g2"
	mime_types_value[74] = c"audio/3gpp2"
	mime_types_key[75] = c".3gpp2"
	mime_types_value[75] = c"audio/3gpp2"
	mime_types_key[76] = c".aac"
	mime_types_value[76] = c"audio/aac"
	mime_types_key[77] = c".adts"
	mime_types_value[77] = c"audio/aac"
	mime_types_key[78] = c".loas"
	mime_types_value[78] = c"audio/aac"
	mime_types_key[79] = c".ass"
	mime_types_value[79] = c"audio/aac"
	mime_types_key[80] = c".au"
	mime_types_value[80] = c"audio/basic"
	mime_types_key[81] = c".snd"
	mime_types_value[81] = c"audio/basic"
	mime_types_key[82] = c".mp3"
	mime_types_value[82] = c"audio/mpeg"
	mime_types_key[83] = c".mp2"
	mime_types_value[83] = c"audio/mpeg"
	mime_types_key[84] = c".opus"
	mime_types_value[84] = c"audio/opus"
	mime_types_key[85] = c".aif"
	mime_types_value[85] = c"audio/x-aiff"
	mime_types_key[86] = c".aifc"
	mime_types_value[86] = c"audio/x-aiff"
	mime_types_key[87] = c".aiff"
	mime_types_value[87] = c"audio/x-aiff"
	mime_types_key[88] = c".ra"
	mime_types_value[88] = c"audio/x-pn-realaudio"
	mime_types_key[89] = c".wav"
	mime_types_value[89] = c"audio/x-wav"
	mime_types_key[90] = c".avif"
	mime_types_value[90] = c"image/avif"
	mime_types_key[91] = c".bmp"
	mime_types_value[91] = c"image/bmp"
	mime_types_key[92] = c".gif"
	mime_types_value[92] = c"image/gif"
	mime_types_key[93] = c".ief"
	mime_types_value[93] = c"image/ief"
	mime_types_key[94] = c".jpg"
	mime_types_value[94] = c"image/jpeg"
	mime_types_key[95] = c".jpe"
	mime_types_value[95] = c"image/jpeg"
	mime_types_key[96] = c".jpeg"
	mime_types_value[96] = c"image/jpeg"
	mime_types_key[97] = c".heic"
	mime_types_value[97] = c"image/heic"
	mime_types_key[98] = c".heif"
	mime_types_value[98] = c"image/heif"
	mime_types_key[99] = c".png"
	mime_types_value[99] = c"image/png"
	mime_types_key[100] = c".svg"
	mime_types_value[100] = c"image/svg+xml"
	mime_types_key[101] = c".tiff"
	mime_types_value[101] = c"image/tiff"
	mime_types_key[102] = c".tif"
	mime_types_value[102] = c"image/tiff"
	mime_types_key[103] = c".ico"
	mime_types_value[103] = c"image/vnd.microsoft.icon"
	mime_types_key[104] = c".webp"
	mime_types_value[104] = c"image/webp"
	mime_types_key[105] = c".ras"
	mime_types_value[105] = c"image/x-cmu-raster"
	mime_types_key[106] = c".pnm"
	mime_types_value[106] = c"image/x-portable-anymap"
	mime_types_key[107] = c".pbm"
	mime_types_value[107] = c"image/x-portable-bitmap"
	mime_types_key[108] = c".pgm"
	mime_types_value[108] = c"image/x-portable-graymap"
	mime_types_key[109] = c".ppm"
	mime_types_value[109] = c"image/x-portable-pixmap"
	mime_types_key[110] = c".rgb"
	mime_types_value[110] = c"image/x-rgb"
	mime_types_key[111] = c".xbm"
	mime_types_value[111] = c"image/x-xbitmap"
	mime_types_key[112] = c".xpm"
	mime_types_value[112] = c"image/x-xpixmap"
	mime_types_key[113] = c".xwd"
	mime_types_value[113] = c"image/x-xwindowdump"
	mime_types_key[114] = c".eml"
	mime_types_value[114] = c"message/rfc822"
	mime_types_key[115] = c".mht"
	mime_types_value[115] = c"message/rfc822"
	mime_types_key[116] = c".mhtml"
	mime_types_value[116] = c"message/rfc822"
	mime_types_key[117] = c".nws"
	mime_types_value[117] = c"message/rfc822"
	mime_types_key[118] = c".css"
	mime_types_value[118] = c"text/css"
	mime_types_key[119] = c".csv"
	mime_types_value[119] = c"text/csv"
	mime_types_key[120] = c".html"
	mime_types_value[120] = c"text/html"
	mime_types_key[121] = c".htm"
	mime_types_value[121] = c"text/html"
	mime_types_key[122] = c".md"
	mime_types_value[122] = c"text/markdown"
	mime_types_key[123] = c".markdown"
	mime_types_value[123] = c"text/markdown"
	mime_types_key[124] = c".n3"
	mime_types_value[124] = c"text/n3"
	mime_types_key[125] = c".txt"
	mime_types_value[125] = c"text/plain"
	mime_types_key[126] = c".bat"
	mime_types_value[126] = c"text/plain"
	mime_types_key[127] = c".c"
	mime_types_value[127] = c"text/plain"
	mime_types_key[128] = c".h"
	mime_types_value[128] = c"text/plain"
	mime_types_key[129] = c".ksh"
	mime_types_value[129] = c"text/plain"
	mime_types_key[130] = c".pl"
	mime_types_value[130] = c"text/plain"
	mime_types_key[131] = c".srt"
	mime_types_value[131] = c"text/plain"
	mime_types_key[132] = c".rtx"
	mime_types_value[132] = c"text/richtext"
	mime_types_key[133] = c".rtf"
	mime_types_value[133] = c"text/rtf"
	mime_types_key[134] = c".tsv"
	mime_types_value[134] = c"text/tab-separated-values"
	mime_types_key[135] = c".vtt"
	mime_types_value[135] = c"text/vtt"
	mime_types_key[136] = c".py"
	mime_types_value[136] = c"text/x-python"
	mime_types_key[137] = c".rst"
	mime_types_value[137] = c"text/x-rst"
	mime_types_key[138] = c".etx"
	mime_types_value[138] = c"text/x-setext"
	mime_types_key[139] = c".sgm"
	mime_types_value[139] = c"text/x-sgml"
	mime_types_key[140] = c".sgml"
	mime_types_value[140] = c"text/x-sgml"
	mime_types_key[141] = c".vcf"
	mime_types_value[141] = c"text/x-vcard"
	mime_types_key[142] = c".xml"
	mime_types_value[142] = c"text/xml"
	mime_types_key[143] = c".mp4"
	mime_types_value[143] = c"video/mp4"
	mime_types_key[144] = c".mpeg"
	mime_types_value[144] = c"video/mpeg"
	mime_types_key[145] = c".m1v"
	mime_types_value[145] = c"video/mpeg"
	mime_types_key[146] = c".mpa"
	mime_types_value[146] = c"video/mpeg"
	mime_types_key[147] = c".mpe"
	mime_types_value[147] = c"video/mpeg"
	mime_types_key[148] = c".mpg"
	mime_types_value[148] = c"video/mpeg"
	mime_types_key[149] = c".mov"
	mime_types_value[149] = c"video/quicktime"
	mime_types_key[150] = c".qt"
	mime_types_value[150] = c"video/quicktime"
	mime_types_key[151] = c".webm"
	mime_types_value[151] = c"video/webm"
	mime_types_key[152] = c".avi"
	mime_types_value[152] = c"video/x-msvideo"
	mime_types_key[153] = c".movie"
	mime_types_value[153] = c"video/x-sgi-movie"
	mime_types_count = 154


void mimetypes_load_common():
	mime_common_key[0] = c".rtf"
	mime_common_value[0] = c"application/rtf"
	mime_common_key[1] = c".midi"
	mime_common_value[1] = c"audio/midi"
	mime_common_key[2] = c".mid"
	mime_common_value[2] = c"audio/midi"
	mime_common_key[3] = c".jpg"
	mime_common_value[3] = c"image/jpg"
	mime_common_key[4] = c".pict"
	mime_common_value[4] = c"image/pict"
	mime_common_key[5] = c".pct"
	mime_common_value[5] = c"image/pict"
	mime_common_key[6] = c".pic"
	mime_common_value[6] = c"image/pict"
	mime_common_key[7] = c".xul"
	mime_common_value[7] = c"text/xul"
	mime_common_count = 8


void mimetypes_load_encodings():
	mime_encodings_key[0] = c".gz"
	mime_encodings_value[0] = c"gzip"
	mime_encodings_key[1] = c".Z"
	mime_encodings_value[1] = c"compress"
	mime_encodings_key[2] = c".bz2"
	mime_encodings_value[2] = c"bzip2"
	mime_encodings_key[3] = c".xz"
	mime_encodings_value[3] = c"xz"
	mime_encodings_key[4] = c".br"
	mime_encodings_value[4] = c"br"
	mime_encodings_count = 5


void mimetypes_load_suffixes():
	mime_suffixes_key[0] = c".svgz"
	mime_suffixes_value[0] = c".svg.gz"
	mime_suffixes_key[1] = c".tgz"
	mime_suffixes_value[1] = c".tar.gz"
	mime_suffixes_key[2] = c".taz"
	mime_suffixes_value[2] = c".tar.gz"
	mime_suffixes_key[3] = c".tz"
	mime_suffixes_value[3] = c".tar.gz"
	mime_suffixes_key[4] = c".tbz2"
	mime_suffixes_value[4] = c".tar.bz2"
	mime_suffixes_key[5] = c".txz"
	mime_suffixes_value[5] = c".tar.xz"
	mime_suffixes_count = 6

# ---- End of generated tables.


int mime_loaded
list[MimeAdded*] mime_added


void mimetypes_ensure_loaded():
	if (mime_loaded): return
	mimetypes_load_types()
	mimetypes_load_common()
	mimetypes_load_encodings()
	mimetypes_load_suffixes()
	mime_loaded = 1


# Drop every add_type registration, restoring the default tables
# (Python's mimetypes.init() without files).
void mimetypes_init():
	if (mime_added != 0):
		for MimeAdded* entry in mime_added:
			free(entry.type)
			free(entry.ext)
			free(entry)
		mime_added.free()
		mime_added = 0


void mime_guess_free(MimeGuess* guess):
	if (guess == 0): return
	if (guess.type != 0): free(guess.type)
	if (guess.encoding != 0): free(guess.encoding)
	free(guess)


void mimetypes_free_extensions(list[char*] extensions):
	if (extensions == 0): return
	for char* ext in extensions: free(ext)
	extensions.free()


char* mime_lower(char* s):
	char* result = strclone(s)
	int i = 0
	while (result[i] != 0):
		if ((result[i] >= 'A') && (result[i] <= 'Z')): result[i] = result[i] + 32
		i = i + 1
	return result


char* mime_copy_or_zero(char* s):
	if (s == 0): return 0
	return strclone(s)


# Index of a key in one of the default tables, or -1.
int mime_table_find(char** keys, int count, char* key):
	int i = 0
	while (i < count):
		if (strcmp(keys[i], key) == 0): return i
		i = i + 1
	return -1


# posixpath.splitext: the index where the extension starts, or
# strlen(p) when there is none. The extension is the last '.' of the
# last component, unless every character before it in that component
# is also a '.' (".bashrc", "..", "a/.x").
int mime_splitext(char* p):
	int length = strlen(p)
	int sep = -1
	int dot = -1
	int i = 0
	while (i < length):
		if (p[i] == '/'): sep = i
		if (p[i] == '.'): dot = i
		i = i + 1
	if (dot > sep):
		int name = sep + 1
		while (name < dot):
			if (p[name] != '.'): return dot
			name = name + 1
	return length


# Forward lookup of an already-lowercased extension in one table
# (strict or non-strict): the latest add_type wins over the default.
char* mime_lookup_ext(char* ext, int strict):
	if (mime_added != 0):
		int i = mime_added.length - 1
		while (i >= 0):
			MimeAdded* entry = mime_added[i]
			if ((entry.strict == strict) && (strcmp(entry.ext, ext) == 0)): return entry.type
			i = i - 1
	int found = -1
	if (strict):
		found = mime_table_find(mime_types_key, mime_types_count, ext)
		if (found >= 0): return mime_types_value[found]
		return 0
	found = mime_table_find(mime_common_key, mime_common_count, ext)
	if (found >= 0): return mime_common_value[found]
	return 0


# MimeTypes._guess_file_type with posixpath.splitext.
MimeGuess* mimetypes_guess_path(char* path, int strict):
	mimetypes_ensure_loaded()
	MimeGuess* guess = new MimeGuess
	guess.type = 0
	guess.encoding = 0
	char* current = strclone(path)
	int dot = mime_splitext(current)
	while (1):
		char* lowered = mime_lower(&current[dot])
		int alias = mime_table_find(mime_suffixes_key, mime_suffixes_count, lowered)
		free(lowered)
		if (alias < 0): break
		current[dot] = 0
		char* expanded = strjoin(current, mime_suffixes_value[alias])
		free(current)
		current = expanded
		dot = mime_splitext(current)
	int coding = mime_table_find(mime_encodings_key, mime_encodings_count, &current[dot])
	if (coding >= 0):
		guess.encoding = strclone(mime_encodings_value[coding])
		current[dot] = 0
		dot = mime_splitext(current)
	char* ext = mime_lower(&current[dot])
	char* found = mime_lookup_ext(ext, 1)
	if ((found == 0) && (strict == 0)): found = mime_lookup_ext(ext, 0)
	guess.type = mime_copy_or_zero(found)
	free(ext)
	free(current)
	return guess


# Python's guess_file_type: path is always a filesystem path.
MimeGuess* mimetypes_guess_file_type(char* path, int strict = 1):
	return mimetypes_guess_path(path, strict)


int mime_is_scheme_char(int c):
	if ((c >= 'a') && (c <= 'z')): return 1
	if ((c >= 'A') && (c <= 'Z')): return 1
	if ((c >= '0') && (c <= '9')): return 1
	return (c == '+') || (c == '-') || (c == '.')


# urlparse's uses_params: schemes whose last path segment loses ;params.
int mime_scheme_uses_params(char* scheme):
	char* names = c" ftp hdl prospero http imap https shttp rtsp rtsps rtspu sip sips mms sftp tel "
	char* needle = strjoin(c" ", scheme)
	char* padded = strjoin(needle, c" ")
	int found = contains(names, padded)
	free(needle)
	free(padded)
	return found


# First index >= start of any byte of chars in s[start, end), or -1.
int mime_find_any(char* s, int start, int end, char* chars):
	int i = start
	while (i < end):
		int j = 0
		while (chars[j] != 0):
			if (s[i] == chars[j]): return i
			j = j + 1
		i = i + 1
	return -1


# The type of a data: URL path ("text/html;charset=x,payload").
MimeGuess* mime_guess_data_url(char* url):
	MimeGuess* guess = new MimeGuess
	guess.type = 0
	guess.encoding = 0
	int comma = mime_find_any(url, 0, strlen(url), c",")
	if (comma < 0): return guess
	int end = mime_find_any(url, 0, comma, c";")
	if (end < 0): end = comma
	char* media = str_copy_range(url, 0, end)
	if ((mime_find_any(media, 0, end, c"=") >= 0) || (mime_find_any(media, 0, end, c"/") < 0)):
		free(media)
		media = strclone(c"text/plain")
	guess.type = media
	return guess


# Guess (type, encoding) for a path or URL, like Python's guess_type.
MimeGuess* mimetypes_guess_type(char* url, int strict = 1):
	# urlsplit: strip leading C0/space, drop every tab, CR and LF.
	int start = 0
	while ((url[start] != 0) && ((url[start] & 255) <= 32)): start = start + 1
	int length = strlen(url)
	char* clean = cast(char*, malloc(length - start + 1))
	int n = 0
	int i = start
	while (i < length):
		if ((url[i] != 9) && (url[i] != 10) && (url[i] != 13)):
			clean[n] = url[i]
			n = n + 1
		i = i + 1
	clean[n] = 0
	int colon = mime_find_any(clean, 0, n, c":")
	int scheme_ok = colon > 1
	if (scheme_ok):
		scheme_ok = ((clean[0] >= 'a') && (clean[0] <= 'z')) || ((clean[0] >= 'A') && (clean[0] <= 'Z'))
	i = 0
	while (scheme_ok && (i < colon)):
		if (mime_is_scheme_char(clean[i]) == 0): scheme_ok = 0
		i = i + 1
	if (scheme_ok == 0):
		free(clean)
		return mimetypes_guess_path(url, strict)
	char* raw_scheme = str_copy_range(clean, 0, colon)
	char* scheme = mime_lower(raw_scheme)
	free(raw_scheme)
	int begin = colon + 1
	int end = n
	if ((clean[begin] == '/') && (clean[begin + 1] == '/')):
		int slash = mime_find_any(clean, begin + 2, end, c"/?#")
		if (slash < 0): begin = end
		else: begin = slash
	int cut = mime_find_any(clean, begin, end, c"#")
	if (cut >= 0): end = cut
	cut = mime_find_any(clean, begin, end, c"?")
	if (cut >= 0): end = cut
	char* path = str_copy_range(clean, begin, end)
	free(clean)
	if (mime_scheme_uses_params(scheme) && (mime_find_any(path, 0, strlen(path), c";") >= 0)):
		# _splitparams: ';' after the last '/' (or the first ';' when
		# there is no '/') starts the params.
		int path_length = strlen(path)
		int last_slash = -1
		i = 0
		while (i < path_length):
			if (path[i] == '/'): last_slash = i
			i = i + 1
		int semi = -1
		if (last_slash >= 0): semi = mime_find_any(path, last_slash, path_length, c";")
		else: semi = mime_find_any(path, 0, path_length, c";")
		if (semi >= 0): path[semi] = 0
	MimeGuess* guess = 0
	if (strcmp(scheme, c"data") == 0): guess = mime_guess_data_url(path)
	else: guess = mimetypes_guess_path(path, strict)
	free(scheme)
	free(path)
	return guess


int mime_list_has(list[char*] items, char* s):
	for char* item in items:
		if (strcmp(item, s) == 0): return 1
	return 0


# Append the extensions one table maps back to type (already lowercased):
# the defaults in table order, then add_type registrations.
void mime_collect_extensions(list[char*] out, char* type, int strict):
	char** keys = mime_common_key
	char** values = mime_common_value
	int count = mime_common_count
	if (strict):
		keys = mime_types_key
		values = mime_types_value
		count = mime_types_count
	int i = 0
	while (i < count):
		if ((strcmp(values[i], type) == 0) && (mime_list_has(out, keys[i]) == 0)): out.push(strclone(keys[i]))
		i = i + 1
	if (mime_added != 0):
		for MimeAdded* entry in mime_added:
			if ((entry.strict == strict) && (strcmp(entry.type, type) == 0) && (mime_list_has(out, entry.ext) == 0)):
				out.push(strclone(entry.ext))


# Every extension that maps to type, strict table first; empty when
# none. Free with mimetypes_free_extensions.
list[char*] mimetypes_guess_all_extensions(char* type, int strict = 1):
	mimetypes_ensure_loaded()
	char* lowered = mime_lower(type)
	list[char*] out = new list[char*]
	mime_collect_extensions(out, lowered, 1)
	if (strict == 0): mime_collect_extensions(out, lowered, 0)
	free(lowered)
	return out


# The first of guess_all_extensions, or 0.
char* mimetypes_guess_extension(char* type, int strict = 1):
	list[char*] all = mimetypes_guess_all_extensions(type, strict)
	char* first = 0
	if (all.length > 0): first = strclone(all[0])
	mimetypes_free_extensions(all)
	return first


# Map ext (with its leading '.') to type; an empty or 0 type is ignored.
void mimetypes_add_type(char* type, char* ext, int strict = 1):
	if ((type == 0) || (type[0] == 0)): return
	if (strict != 0): strict = 1
	if (mime_added == 0): mime_added = new list[MimeAdded*]
	MimeAdded* entry = new MimeAdded
	entry.type = strclone(type)
	entry.ext = strclone(ext)
	entry.strict = strict
	mime_added.push(entry)
