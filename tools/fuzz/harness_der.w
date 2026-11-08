# wbuild: target=wfuzz_der_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/der/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_der.w -o bin/wfuzz_der_harness"
# wbuild: step="rm -rf bin/wfuzz_der_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_der_harness --bytes --ext .der --corpus tools/fuzz/seeds/der --out bin/wfuzz_der_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_der tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_der.w -o bin/wfuzz_der_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_der_harness --bytes --ext .der --corpus tools/fuzz/seeds/der --out bin/wfuzz_der" timeout=3600000
# Fuzz harness for DER/ASN.1 (issue #842): libs/standard/net/asn1.w's
# reader walked over the whole TLV tree (every primitive also read as an
# INTEGER, small int, BOOLEAN and BIT STRING), then x509.w's certificate
# parser, chain verification of the certificate against itself (key and
# signature decoding), and the PKCS#8 / SEC1 EC private-key parsers.
import tools.fuzz.harness
import libs.standard.net.asn1
import libs.standard.net.x509


# Visits every element inside data[start, end); returns how many parsed.
int fh_der_walk(char* data, int start, int end, int depth):
	if (depth > 32): return 0
	asn1 r
	asn1_init(&r, data, start, end)
	int count = 0
	while (asn1_done(&r) == 0):
		int at = r.pos
		int tag = 0
		int content = 0
		int len = 0
		if (asn1_next(&r, &tag, &content, &len) == 0): return count
		fh_check((content > at) && (content + len <= end) && (r.pos == content + len), c"asn1_next returned an element outside its window")
		count = count + 1
		if ((tag & 32) != 0): count = count + fh_der_walk(data, content, content + len, depth + 1)
		else:
			# Re-read the element with each typed reader.
			asn1 e
			int s = 0
			int n = 0
			int v = 0
			asn1_init(&e, data, at, content + len)
			asn1_read_integer(&e, &s, &n)
			asn1_init(&e, data, at, content + len)
			asn1_read_small_int(&e, &v)
			asn1_init(&e, data, at, content + len)
			asn1_read_positive_integer(&e, &s, &n)
			asn1_init(&e, data, at, content + len)
			asn1_read_boolean(&e, &v)
			asn1_init(&e, data, at, content + len)
			if (asn1_read_bitstring_bytes(&e, &s, &n)): fh_check((s >= at) && (s + n <= content + len), c"BIT STRING bytes outside the element")
	return count


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	int accepted = 0
	if (fh_der_walk(data, 0, length, 0) > 0): accepted = 1
	x509_cert* cert = x509_parse(data, length)
	if (cert != 0):
		accepted = 1
		for char* name in cert.san_dns: x509_hostname_matches_pattern(name, c"www.example.com")
		x509_time_status(cert, 20000, 0)
		x509_trust_store* store = x509_store_new()
		x509_store_add(store, x509_parse(data, length))
		list[x509_cert*] extra = new list[x509_cert*]
		char* err = 0
		x509_verify_chain(cert, extra, store, c"www.example.com", 1700000000, &err)
		x509_verify_chain_no_hostname(cert, extra, store, 1700000000, &err)
		x509_store_free(store)
		x509_cert_free(cert)
	char* d32 = cast(char*, malloc(48))
	if (x509_parse_pkcs8_ec_key(data, 0, length, d32)): accepted = 1
	if (x509_parse_sec1_key(data, 0, length, 1, d32)): accepted = 1
	if (accepted): return 0
	return 1
