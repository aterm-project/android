"""Independent Python conformance checks for the shared sync record vector."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
from copy import deepcopy
from pathlib import Path

import pytest
from nacl.bindings import crypto_aead_xchacha20poly1305_ietf_decrypt
from nacl.exceptions import BadSignatureError
from nacl.signing import SigningKey, VerifyKey

from conftest import unb64url


VECTOR = (
    Path(__file__).resolve().parents[1]
    / "protocol"
    / "sync-fixtures"
    / "record-envelope-v1.json"
)


def _canonical_json(value: object) -> bytes:
    """RFC 8785-compatible for this fixture's ASCII keys and safe integers."""
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def _hkdf_sha256(ikm: bytes, salt: bytes, info: bytes) -> bytes:
    pseudorandom_key = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(pseudorandom_key, info + b"\x01", hashlib.sha256).digest()


def _assert_signature(envelope: dict, public_key: bytes) -> None:
    unsigned = {
        "header": envelope["header"],
        "nonce": envelope["nonce"],
        "ciphertext": envelope["ciphertext"],
    }
    VerifyKey(public_key).verify(
        _canonical_json(unsigned), unb64url(envelope["signature"])
    )


def _flip_first_byte(value: str) -> str:
    raw = bytearray(unb64url(value))
    raw[0] ^= 1
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def test_shared_sync_record_envelope_known_answer_and_tamper_rejection() -> None:
    vector = json.loads(VECTOR.read_text(encoding="utf-8"))
    envelope = vector["envelope"]
    unsigned = {
        "header": envelope["header"],
        "nonce": envelope["nonce"],
        "ciphertext": envelope["ciphertext"],
    }
    signed_bytes = _canonical_json(unsigned)
    assert signed_bytes.decode("utf-8") == vector["signed_payload_jcs_utf8"]
    assert hashlib.sha256(signed_bytes).hexdigest() == vector[
        "signed_payload_sha256"
    ]
    assert _canonical_json(envelope).decode("utf-8") == vector[
        "envelope_jcs_utf8"
    ]
    assert hashlib.sha256(_canonical_json(envelope)).hexdigest() == vector[
        "envelope_jcs_sha256"
    ]
    assert hashlib.sha256(unb64url(envelope["ciphertext"])).hexdigest() == vector[
        "ciphertext_sha256"
    ]

    test_only = vector["test_only"]
    seed = unb64url(test_only["signing_seed_base64url"])
    signing_key = SigningKey(seed)
    public_key = bytes(signing_key.verify_key)
    assert public_key == unb64url(test_only["signing_public_key_base64url"])
    assert unb64url(envelope["header"]["kdf_salt"]) == unb64url(
        test_only["kdf_salt_base64url"]
    )
    assert unb64url(envelope["nonce"]) == unb64url(test_only["nonce_base64url"])
    assert signing_key.sign(signed_bytes).signature == unb64url(
        envelope["signature"]
    )
    _assert_signature(envelope, public_key)

    header_bytes = _canonical_json(envelope["header"])
    assert header_bytes.decode("utf-8") == vector["header_jcs_utf8"]
    salt = unb64url(test_only["kdf_salt_base64url"])
    info = _canonical_json(
        [
            "atermius",
            "record",
            1,
            vector["context"]["vault_id"],
            vector["context"]["record_id"],
            vector["context"]["revision_id"],
        ]
    )
    assert info.decode("utf-8") == vector["record_hkdf_info_jcs_utf8"]
    record_key = _hkdf_sha256(
        unb64url(test_only["vault_key_base64url"]), salt, info
    )
    assert record_key.hex() == vector["record_key_hex"]
    clear = crypto_aead_xchacha20poly1305_ietf_decrypt(
        unb64url(envelope["ciphertext"]),
        header_bytes,
        unb64url(envelope["nonce"]),
        record_key,
    )
    assert clear.decode("utf-8") == vector["plaintext_jcs_utf8"]

    tampered_values = []
    tampered_header = deepcopy(envelope)
    tampered_header["header"]["operation"] = "update"
    tampered_values.append(tampered_header)
    for field in ("nonce", "ciphertext", "signature"):
        tampered = deepcopy(envelope)
        tampered[field] = _flip_first_byte(tampered[field])
        tampered_values.append(tampered)
    for tampered in tampered_values:
        with pytest.raises(BadSignatureError):
            _assert_signature(tampered, public_key)
