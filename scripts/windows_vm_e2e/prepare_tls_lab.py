from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def write_leaf(
    output_directory: Path,
    name: str,
    issuer_certificate: x509.Certificate,
    issuer_key: rsa.RSAPrivateKey,
    not_before: dt.datetime,
    not_after: dt.datetime,
    san: x509.GeneralName,
) -> None:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer_certificate.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(x509.SubjectAlternativeName([san]), critical=False)
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
            critical=False,
        )
        .sign(issuer_key, hashes.SHA256())
    )
    (output_directory / f"{name}.key.pem").write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    (output_directory / f"{name}.cert.pem").write_bytes(
        certificate.public_bytes(serialization.Encoding.PEM)
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root-certificate", required=True, type=Path)
    parser.add_argument("--root-key", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    arguments = parser.parse_args()

    output_directory = arguments.output_directory.resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    issuer_certificate = x509.load_pem_x509_certificate(
        arguments.root_certificate.read_bytes()
    )
    issuer_key = serialization.load_pem_private_key(
        arguments.root_key.read_bytes(), password=None
    )
    if not isinstance(issuer_key, rsa.RSAPrivateKey):
        raise TypeError("The isolated lab root must use an RSA private key")

    now = dt.datetime.now(dt.timezone.utc)
    guest_host = x509.IPAddress(ipaddress.ip_address("10.0.2.2"))
    write_leaf(
        output_directory,
        "valid-ip",
        issuer_certificate,
        issuer_key,
        now - dt.timedelta(days=1),
        now + dt.timedelta(days=7),
        guest_host,
    )
    write_leaf(
        output_directory,
        "hostname-mismatch",
        issuer_certificate,
        issuer_key,
        now - dt.timedelta(days=1),
        now + dt.timedelta(days=7),
        x509.DNSName("mismatch.invalid"),
    )
    write_leaf(
        output_directory,
        "expired-ip",
        issuer_certificate,
        issuer_key,
        now - dt.timedelta(days=14),
        now - dt.timedelta(days=7),
        guest_host,
    )


if __name__ == "__main__":
    main()
