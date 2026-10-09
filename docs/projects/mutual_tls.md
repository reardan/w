# Mutual certificate TLS authentication

`lib/transport_tls.w` and `libs/standard/net/tls.w` support TLS 1.3 client
certificate authentication during the initial handshake. Existing server-only
TLS remains the default. The cipher suite remains
`TLS_CHACHA20_POLY1305_SHA256`, with X25519 exchange and ECDSA P-256 client
credentials. Post-handshake authentication and session resumption are not
implemented.

Configure the client with borrowed PEM paths in `tls_config`:

```w
cfg.client_cert_chain_path = c"client-chain.pem"
cfg.client_key_path = c"client-key.pem"
cfg.require_client_auth = 1
```

The chain is leaf first; the private key is P-256 PKCS#8 or SEC1. Paths need
remain valid only through the checked constructor. The usual
`trust_store_path` and expected server DNS name still authenticate the server.
`require_client_auth` rejects a server which omits `CertificateRequest` or a
request for which the client cannot supply a compatible credential. Its
default is zero, preserving server-only compatibility. A client only sends
credentials when requested, after verifying the server flight. If a compatible
credential is requested, a configured but unreadable certificate or key fails
the handshake.

Configure the server independently:

```w
server.client_auth = TLS_CLIENT_AUTH_REQUIRED
server.client_trust_store_path = c"authorized-client-issuers.pem"
```

`TLS_CLIENT_AUTH_NONE` sends no request and accepts anonymous clients.
`TLS_CLIENT_AUTH_OPTIONAL` requests a certificate, allows an exactly empty
Certificate message, and rejects any invalid certificate that is supplied.
`TLS_CLIENT_AUTH_REQUIRED` rejects missing certificates, omitted Certificate or
CertificateVerify messages, and invalid proofs. Both requesting modes require
an explicit client trust bundle; they never silently use the system's public
server trust roots. The configured CA bundle is an issuer trust policy, not an
application authorization list.

Client chain verification checks signatures, validity, CA constraints,
digitalSignature key usage and clientAuth extended key usage when present.
Purpose-restricted intermediates and trust anchors also have to permit
clientAuth; serverAuth-only issuers cannot delegate client authentication.
It does not impose a DNS hostname requirement on clients. A serverAuth-only
certificate cannot authenticate a client. `has_now_unix`/`now_unix` on the
server configuration allow deterministic verification time in tests, like the
existing client options. There is no insecure client-verification override on
the server. The client cannot label an insecurely verified server as
authenticated.

CertificateRequest includes a mandatory signature_algorithms extension;
CertificateVerify uses the RFC's distinct client role context. Both client
Certificate and CertificateVerify enter the client Finished transcript while
application secrets retain the transcript ending at server Finished. The
server verifies the Finished before exposing authenticated client identity.
Malformed or duplicate request extensions and malformed certificate framing
fail closed. Requests without the supported P-256 signature scheme, with incompatible
certificate-signature constraints, or with OID filters this implementation
cannot evaluate, receive an empty Certificate (or fail with
`require_client_auth`). The separate signature_algorithms_cert extension
advertises the verifier's ECDSA SHA-256 and RSA PKCS#1/PSS SHA-256/SHA-384
certificate signatures. Client selection checks each configured certificate
against this extension, falling back to signature_algorithms when absent. CA-name hints do not select among credentials; the
client uses its one configured chain, and the server validates it against its
own trust store.

On an authenticated server transport, `transport_authenticated(t)` is one
and `transport_peer(t)` is `tls-client-sha256:` followed by the lowercase
SHA-256 digest of the verified leaf certificate DER. This owned identity
survives freeing the borrowed configuration and closing the transport. An
anonymous optional client retains the caller's untrusted peer label and
`authenticated=0`. Client transports retain the verified `tls:<DNS name>`
identity. The lower-level `tls_peer_certificate_sha256(c)` returns a borrowed
fingerprint only on a verified, unbroken connection.

Applications must map the certificate fingerprint to their own principal and
permissions, account for certificate rotation, and reject anonymous transports
where needed. A certificate signed by a trusted CA proves possession of that
certificate's key, not permission to access every application resource. TLS
client certificates are separate from Raft's encrypted client-credential
protocol. Certificate revocation and application account lifecycle remain the
application's responsibility.

TLS 1.3 sends the server Finished before the client's proof. Consequently a
client constructor can return before the server rejects a client certificate;
the fatal alert is then observed on the first read. Applications needing
confirmation of authorization must wait for an application response before
claiming that the server accepted them.

Checked constructors consume their socket on every path. The existing
absolute deadline, task cancellation, partial-record poisoning, per-connection
errors and close_notify cleanup also cover the client-auth flight. TLS keeps
full close semantics; a raw socket half-close is not a TLS shutdown.

`transport_mutual_tls_test` and its x64 twin cover trusted required/optional
handshakes, identity, missing/untrusted/expired/wrong-purpose/non-signing
certificates and purpose-restricted issuers, mismatched private keys,
cross-role signatures, absent/forged Finished, mandatory-request omission, malformed
requests and certificates, absent trust/credential configuration, insecure
server verification, cancellation and timeout while awaiting client proof,
and clean shutdown. Existing `transport_tls_test`, `net_tls_test`,
`net_tls_server_test`, `net_tls_alpn_test` and `net_x509_test` cover the shared
server-only, record, downgrade, partial-progress and error-shutdown paths.
All test certificates and keys under `tls_mutual_fixtures` are public test data;
regeneration needs Python cryptography, but normal builds/tests do not.
A supplementary OpenSSL smoke verified both mutual-TLS roles on x86/x64
using the existing `tests/openssl_tls_interop.w` harness pattern with the
checked-in client credentials, strict peer verification and required client
authentication; OpenSSL remains outside the normal test dependencies.

Protocol references: [RFC 8446, CertificateRequest and authentication](https://www.rfc-editor.org/rfc/rfc8446.html#section-4.3.2),
[RFC 5280, extended key usage](https://www.rfc-editor.org/rfc/rfc5280.html#section-4.2.1.12).
