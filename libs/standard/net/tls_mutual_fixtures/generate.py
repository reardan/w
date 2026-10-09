#!/usr/bin/env python3
"""Regenerate public mutual-TLS TEST credentials; requires cryptography only here.

Runtime tests use checked-in PEM, never Python, OpenSSL, the network or clock.
These private keys are public test data and must never secure a real service.
"""
from datetime import datetime, timezone
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

out = Path(__file__).resolve().parent
ca_key = ec.derive_private_key(61101, ec.SECP256R1())
client_key = ec.derive_private_key(61102, ec.SECP256R1())
wrong_key = ec.derive_private_key(61103, ec.SECP256R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'W mutual TLS TEST CA')])
start = datetime(2020, 1, 1, tzinfo=timezone.utc)
end = datetime(2040, 1, 1, tzinfo=timezone.utc)
ca = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
      .public_key(ca_key.public_key()).serial_number(61101)
      .not_valid_before(start).not_valid_after(end)
      .add_extension(x509.BasicConstraints(ca=True, path_length=1), critical=True)
      .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
      .sign(ca_key, hashes.SHA256()))
(out / 'ca.pem').write_bytes(ca.public_bytes(serialization.Encoding.PEM))
for filename, key in [('client_key.pem', client_key), ('wrong_key.pem', wrong_key)]:
    (out / filename).write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
for serial, filename, expiry, purpose, signing in [
    (61102, 'client.pem', end, ExtendedKeyUsageOID.CLIENT_AUTH, True),
    (61103, 'expired.pem', datetime(2021, 1, 1, tzinfo=timezone.utc), ExtendedKeyUsageOID.CLIENT_AUTH, True),
    (61104, 'server_only.pem', end, ExtendedKeyUsageOID.SERVER_AUTH, True),
    (61105, 'no_signing.pem', end, ExtendedKeyUsageOID.CLIENT_AUTH, False),
]:
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'W TEST client')]))
            .issuer_name(name).public_key(client_key.public_key())
            .serial_number(serial).not_valid_before(start).not_valid_after(expiry)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(signing, False, not signing, False, False, False, False, False, False), critical=True)
            .add_extension(x509.ExtendedKeyUsage([purpose]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    (out / filename).write_bytes(cert.public_bytes(serialization.Encoding.PEM))

# A purpose-restricted root and intermediate must not delegate clientAuth.
restricted_ca = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
      .public_key(ca_key.public_key()).serial_number(61106)
      .not_valid_before(start).not_valid_after(end)
      .add_extension(x509.BasicConstraints(ca=True, path_length=1), critical=True)
      .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
      .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
      .sign(ca_key, hashes.SHA256()))
(out / 'restricted_ca.pem').write_bytes(restricted_ca.public_bytes(serialization.Encoding.PEM))
intermediate_key = ec.derive_private_key(61104, ec.SECP256R1())
intermediate_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'W TEST server-only issuer')])
intermediate = (x509.CertificateBuilder().subject_name(intermediate_name).issuer_name(name)
      .public_key(intermediate_key.public_key()).serial_number(61107)
      .not_valid_before(start).not_valid_after(end)
      .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
      .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
      .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
      .sign(ca_key, hashes.SHA256()))
indirect_client = (x509.CertificateBuilder()
      .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'W TEST indirect client')]))
      .issuer_name(intermediate_name).public_key(client_key.public_key()).serial_number(61108)
      .not_valid_before(start).not_valid_after(end)
      .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
      .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
      .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
      .sign(intermediate_key, hashes.SHA256()))
(out / 'restricted_chain.pem').write_bytes(indirect_client.public_bytes(serialization.Encoding.PEM)
                                         + intermediate.public_bytes(serialization.Encoding.PEM))
