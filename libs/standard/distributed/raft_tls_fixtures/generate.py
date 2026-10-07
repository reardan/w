#!/usr/bin/env python3
"""Regenerate public TEST credentials (requires cryptography); never production."""
from datetime import datetime, timezone
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

out = Path(__file__).resolve().parent
ca_key = ec.generate_private_key(ec.SECP256R1())
key = ec.generate_private_key(ec.SECP256R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'W Raft TEST CA')])
start = datetime(2020, 1, 1, tzinfo=timezone.utc)
end = datetime(2040, 1, 1, tzinfo=timezone.utc)
ca = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
      .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
      .not_valid_before(start).not_valid_after(end)
      .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
      .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
      .sign(ca_key, hashes.SHA256()))
(out / 'ca.pem').write_bytes(ca.public_bytes(serialization.Encoding.PEM))
(out / 'server_key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
for filename, expiry in [('server.pem', end), ('expired.pem', datetime(2021, 1, 1, tzinfo=timezone.utc))]:
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'test.w.example')]))
            .issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(start).not_valid_after(expiry)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('test.w.example')]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    (out / filename).write_bytes(cert.public_bytes(serialization.Encoding.PEM))
