# Encrypted data and recovery notes

[中文上手](GETTING_STARTED.md) · [English first use](GETTING_STARTED.en.md)

Protocol/storage details retained from the application documentation. These are data-format and recovery boundaries, not a new full-suite or native-device acceptance claim.

### Encrypted record object references

The generic record envelope supports an optional `header.object_refs` extension, derived from plaintext `_manifest.object_refs`. References are lowercase canonical UUIDs in strictly ascending order, unique, with a maximum of 1024 entries. The header is covered by both the AEAD associated data and device signature. Empty or omitted references retain the legacy envelope shape without an empty header field. Decryption rejects malformed references or any header/manifest mismatch. Record DTOs and conflict resolution preserve `_manifest` when records are edited or re-encrypted.

Host cards include an encrypted attachment manager for upload, download and removal. Each attachment has a random object key; the client encrypts file content in 4 MiB logical AES-GCM chunks and puts its name, media type and key in the encrypted Host manifest. The server stores opaque object ciphertext and signed references. Persistent transfer jobs support retry, cancel and Range download continuation; Web acceptance covers lost upload acknowledgements, expired upload reservations, page reload and Chromium process restart. The client still caps a file at 256 MiB and uses whole-file picker/decrypt buffers; native cross-platform transfer acceptance remains.


Archive restore is restricted to the same server space and Vault; cross-space remapping/resigning is rejected. The archive cannot recover data already purged by the server unless a prior archive exists. Historical attachment/object bytes are included when reachable from signed records or retained in the local encrypted-object cache. The client calls `GET /api/v1/vaults/{vault_id}/devices` to validate historical signatures and fails closed if signer ownership cannot be verified.

### Permanent record purge

The Web recycle bin exposes permanent purge only to the active Vault Owner and only after the displayed restore deadline. The confirmation requires an explicit acknowledgement and sends the tombstone revision ID and sequence shown by the current snapshot; SQLite and restricted PostgreSQL recheck the owner, exact current tombstone, retention deadline, unresolved conflicts and verified redaction-v1 support for every active Vault device. Purge removes payloads from active server state and clients verify and apply the signed redaction through sync before advancing their cursor. It cannot erase offline device copies or retained backups; restoring a pre-purge backup may restore old payloads.

The Owner automatic-purge control stores consent separately for each exact tombstone. It calls `PUT /api/v1/vaults/{vault_id}/records/{record_id}/automatic-purge` with the strict body `{expected_deleted_revision_id,expected_deleted_seq,expected_policy_revision,enabled}`. Consent defaults to off, compare-and-set uses the policy revision, restore and a later delete reset the new tombstone to off at revision 0, and re-enabling after opt-out advances the revision. The existing hourly and administrator Maintenance paths run a bounded scan; the exact purge transaction rechecks Owner consent, restore deadline, and its other safety conditions. Enabling consent does not purge the record immediately. Backup restore opts any enabled consent out, and legacy backups without the exact tombstone policy remain opted out. Consent does not erase offline device copies, exports, or older encrypted backups; restoring a pre-purge backup may restore ciphertext.
