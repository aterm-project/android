"""Cross-language known-answer coverage for the Recovery v1 crypto contract."""

from __future__ import annotations

import hashlib
import hmac
import json
from pathlib import Path

from nacl.bindings import (
    crypto_aead_xchacha20poly1305_ietf_decrypt,
    crypto_box_seed_keypair,
)
from nacl.public import PrivateKey, SealedBox
from nacl.signing import VerifyKey

from conftest import jcs, unb64url


VECTOR = (
    Path(__file__).resolve().parents[1]
    / "protocol"
    / "test-vectors"
    / "account-recovery-v1.json"
)


def _hkdf_sha256(ikm: bytes, info: bytes) -> bytes:
    pseudorandom_key = hmac.new(bytes(32), ikm, hashlib.sha256).digest()
    return hmac.new(pseudorandom_key, info + b"\x01", hashlib.sha256).digest()


def test_account_recovery_shared_crypto_vector() -> None:
    vector = json.loads(VECTOR.read_text(encoding="utf-8"))
    context = vector["context"]
    recovery_code = unb64url(vector["recovery_code_base64url"])
    account_key = unb64url(vector["account_key_base64url"])
    signing_seed = unb64url(vector["signing_seed_base64url"])
    encryption_seed = unb64url(vector["encryption_seed_base64url"])
    assert len(recovery_code) == len(account_key) == len(signing_seed) == 32
    assert len(encryption_seed) == 32

    code_info = jcs(
        ["atermius", "account-recovery-envelope", 1, context]
    )
    account_info = jcs(
        ["atermius", "account-recovery-identity-wrap", 1, context]
    )
    code_key = _hkdf_sha256(recovery_code, code_info)
    account_key_derived = _hkdf_sha256(account_key, account_info)
    assert code_key.hex() == vector["recovery_code_wrapping_key_hex"]
    assert account_key_derived.hex() == vector["account_key_wrapping_key_hex"]
    assert code_info.decode() == vector["recovery_code_hkdf_info_utf8"]
    assert account_info.decode() == vector["account_key_hkdf_info_utf8"]

    identity_plaintext = vector["identity_plaintext_jcs_utf8"].encode()
    assert hashlib.sha256(identity_plaintext).hexdigest() == vector[
        "identity_plaintext_sha256"
    ]
    code_envelope = vector["recovery_envelope"]
    account_envelope = vector["account_key_envelope"]
    code_aad = jcs({"format": "atermius-account-recovery-v1", **context})
    account_aad = jcs(
        {"format": "atermius-account-recovery-identity-v1", **context}
    )
    assert code_aad.decode() == vector["recovery_envelope_aad_jcs_utf8"]
    assert account_aad.decode() == vector["account_key_envelope_aad_jcs_utf8"]
    code_clear = crypto_aead_xchacha20poly1305_ietf_decrypt(
        unb64url(code_envelope["ciphertext"]),
        code_aad,
        unb64url(code_envelope["nonce"]),
        code_key,
    )
    account_clear = crypto_aead_xchacha20poly1305_ietf_decrypt(
        unb64url(account_envelope["ciphertext"]),
        account_aad,
        unb64url(account_envelope["nonce"]),
        account_key_derived,
    )
    assert len(code_clear) == 512
    assert code_clear.rstrip(b" ") == identity_plaintext
    assert account_clear == identity_plaintext
    identity = json.loads(identity_plaintext)
    assert identity["q"] == vector["signing_seed_base64url"]
    assert identity["y"] == vector["encryption_seed_base64url"]

    descriptor = {
        "protocol": "atermius-account-recovery-descriptor-v1",
        "account_id": vector["account_id"],
        "instance_id": vector["instance_id"],
        "server_space_id": vector["server_space_id"],
        "recovery_generation": vector["recovery_generation"],
        "recovery_public_signing_key": vector["signing_public_key_base64url"],
        "recovery_public_encryption_key": vector[
            "encryption_public_key_base64url"
        ],
    }
    descriptor_hash = hashlib.sha256(jcs(descriptor)).hexdigest()
    assert jcs(descriptor).decode() == vector["descriptor_jcs_utf8"]
    assert descriptor_hash == vector["descriptor_sha256"] == identity["d"]
    signer = VerifyKey(unb64url(vector["signing_public_key_base64url"]))
    signer.verify(
        jcs(json.loads(vector["recovery_identity_proof_payload_jcs_utf8"])),
        unb64url(vector["recovery_identity_proof_signature_base64url"]),
    )

    keybox_ciphertext = unb64url(vector["keybox_envelope"]["ciphertext"])
    assert hashlib.sha256(keybox_ciphertext).hexdigest() == vector[
        "keybox_ciphertext_sha256"
    ]
    # The fixture stores the Curve25519 seed, while SealedBox expects the
    # expanded secret key returned by libsodium's seed-keypair operation.
    _, encryption_secret_key = crypto_box_seed_keypair(encryption_seed)
    keybox_plaintext = SealedBox(PrivateKey(encryption_secret_key)).decrypt(
        keybox_ciphertext
    )
    assert keybox_plaintext.decode() == vector["keybox_plaintext_jcs_utf8"]
    assert json.loads(keybox_plaintext)["vault_key"] == vector[
        "vault_key_base64url"
    ]
    signer.verify(
        jcs(json.loads(vector["keybox_signature_payload_jcs_utf8"])),
        unb64url(vector["keybox_recovery_signature_base64url"]),
    )
