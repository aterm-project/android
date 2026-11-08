# Record redaction wire protocol v1

**Status: SQLite and restricted PostgreSQL read/write support is implemented for explicit Owner initiated purge and exact-tombstone automatic-purge consent; automatic redaction GC remains disabled.** The consent route is exposed, but no automatic purge worker or scheduler runs. The purge route shares each backend's Vault writer fence and preserves the same wire contract. A device capability report is only a support declaration. It does not prove that a device has already applied a redaction.

**Acceptance status (2026-10-11, v2.301):** the serial Rust suite, focused two-node PostgreSQL purge/migration runner, OpenAPI/device-capability checks, full Flutter suite and `WEB-SYNC-REDACTION-IDB-01` passed. The Chromium runner now writes a non-sensitive localStorage canary, requires a changed and stable Local Storage LevelDB before SIGKILL, and verifies the canary and original FlutterSecureStorage device row after reopening the same profile. Same-device sign-in submitted the exact device ID from initial registration and replayed the redacted feed from the old cursor and advanced to the target cursor while the proof and erased-record state remained durable. This verifies the current Chromium Web scenario and does not guarantee every browser timing or native secure storage. Other browser engines and native clients remain unverified; offline device copies and pre-purge backups remain outside the active-server purge guarantee.

## Goals and boundaries

- Remove a purged record's encrypted revision, conflict, snapshot, and object-reference payloads from active server state.
- Keep record IDs reserved so stale devices cannot recreate a purged record.
- Keep ordered change, revision-history, and conflict-feed positions stable. No cursor may silently skip a removed payload.
- Let supported clients verify the server's statement and erase local cached state before advancing a cursor.
- Make old clients fail closed before the server returns a page containing redacted protocol state.
- Keep the promise limited to active server state. Offline device copies, user exports, and retained encrypted backups cannot be remotely erased.

## Signed proof

The server creates one immutable redaction statement per purge. `redaction_id` is a canonical UUID generated for that purge. The server signs the statement with its current instance key when it is serialized for the change feed, history pages, snapshots, or direct revision lookups; the unsigned statement is stable across key rotations.

```json
{
  "format": "atermius-record-redaction-proof-v1",
  "redaction_id": "canonical-uuid",
  "instance_id": "canonical-uuid",
  "server_space_id": "canonical-uuid",
  "vault_id": "canonical-uuid",
  "record_id": "canonical-uuid",
  "deleted_revision_id": "canonical-uuid",
  "deleted_seq": "12",
  "redaction_seq": "45",
  "signing_public_key": "base64url-ed25519-public-key",
  "signature": "base64url-ed25519-signature"
}
```

`deleted_seq` is the commit sequence of the current tombstone revision that passed the restore-retention check. `redaction_seq` is the new change-feed sequence allocated by the purge. Both are canonical positive decimal strings. The signature is Ed25519 over UTF-8 RFC 8785 JCS of exactly the proof fields above except `signature`; `format` domain-separates the signature from all other server signatures. The serialized proof is signed with the current instance key, and `signing_public_key` must equal the current key from the client's already verified `/api/v1/instance` identity. The server may re-sign the same immutable redaction data after a key rotation; the stable identity is `redaction_id` plus the other unsigned fields. Clients never trust a key carried by a proof until they have verified and pinned the instance identity. `server_space_id` and `vault_id` prevent cross-space replay. The proof does not include the server generation: a restored database that contains the redaction ledger keeps the same proof valid when generation advances, while snapshots and cursors remain generation-bound by their existing contracts. Restoring a backup created before purge can restore the old record payload; that recovery limitation is outside the active-state purge guarantee and must be documented by restore UX/runbooks.

The proof contains identifiers and sequence metadata only. It must not contain the old envelope, plaintext, object IDs, object references, record names, or conflict payloads.

## Change feed

`GET /api/v1/vaults/{vault_id}/changes` keeps one monotonically ordered `commit_seq` stream. Purge allocates `last_committed_seq + 1`, stores one `record_redacted` event, and advances the normal opaque cursor through that sequence. Every earlier retained event for the purged record is projected as the same redaction marker while preserving its original `commit_seq`; unrelated events and all sequence positions remain unchanged.

```json
{
  "commit_seq": "45",
  "event_type": "record_redacted",
  "record_id": "canonical-uuid",
  "redaction": {
    "format": "atermius-record-redaction-proof-v1",
    "redaction_id": "canonical-uuid",
    "instance_id": "canonical-uuid",
    "server_space_id": "canonical-uuid",
    "vault_id": "canonical-uuid",
    "record_id": "canonical-uuid",
    "deleted_revision_id": "canonical-uuid",
    "deleted_seq": "12",
    "redaction_seq": "45",
    "signing_public_key": "base64url-ed25519-public-key",
    "signature": "base64url-ed25519-signature"
  }
}
```

Redacted events have exactly `{commit_seq,event_type,record_id,redaction}`; they have no `revision_id` and no `envelope` key. The marker is idempotent, so a client may safely replay it after a lost acknowledgement. A purge whose new marker is on a later page is still observed even when a device's cursor had already passed all of the record's original events.

## Revision history and direct revision reads

Snapshot-bound revision history keeps each retained `commit_seq` row. A purged revision is returned with `{record_id,revision_id,base_revision_id,commit_seq,operation,deleted,created_at,restore_until,envelope,redaction}`, where `operation:"redacted"`, `restore_until:null`, `envelope:null`, and `redaction` is the proof. `deleted` remains true only for the original tombstone revision. Its original `commit_seq` is not removed or reused. The old direct revision route returns `410 RECORD_REDACTED` with the proof and no envelope.

New revision-history responses include `restore_until`: a delete revision carries its frozen RFC3339 deadline, and other operations carry null. Older servers may omit this optional field. The deadline is read-side tombstone metadata; it is not part of the signed redaction proof, change-feed event, or encrypted revision envelope. A new delete fixes the deadline from its commit time and the effective restore-retention setting, so later configuration changes do not move an existing tombstone's cutoff.

Revision-history rows may also include the optional `auto_purge_enabled` boolean and canonical decimal-string `auto_purge_revision`. They are present only on unredacted delete rows and describe the current policy metadata for that exact delete revision, not whether it is still the current head or otherwise eligible for purge. New servers return false and revision `0` when no consent is enabled; older servers may omit either field. These read-time values are outside the snapshot sequence watermark and may change between history pages. The fields are omitted from redacted and non-delete rows.

Before redaction can be committed, all active snapshots for the Vault are marked `redacted` and their materialized page payloads are deleted. A continuation of one of those snapshots returns `410 SNAPSHOT_REDACTED`; it never returns a short page or a count-mismatch error. The same status applies to revision/conflict history requested with that snapshot ID.

## Conflict history and feed

An unresolved conflict branch is user work and blocks purge until it has been explicitly resolved or discarded by a separate supported operation. It is never silently deleted as part of record purge.

Resolved conflict rows retain their original `conflict_seq` and optional `resolution_seq` positions. A conflict-history row has exactly `{conflict_id,conflict_seq,record_id,base_revision_id,resolved_revision_id,resolution_seq,created_at,envelope,redaction}`; for a redacted row, `envelope:null`, `resolved_revision_id:null`, and `redaction` is the proof. In the incremental conflict feed, each original creation/resolution position is returned as exactly `{seq,type,conflict_id,record_id,redaction}`, with `type:"redacted"`. Both sequence positions remain pageable. A client retains any local conflicting outbox as a non-pushable, user-visible draft associated with the proof.

After an unresolved branch check succeeds, the server also clears the stored conflict digest, submitting-device attribution, and retry `op_id`; these fields are not needed to page history and can fingerprint the removed encrypted branch or its source. The opaque conflict ID, record ID, creation time, and original feed sequence positions remain as ordering metadata.

If conflict/revision metadata itself receives a future retention policy, each feed must have an independent contiguous minimum-available watermark and return an explicit `410` recovery response below it. The main changes-feed `minimum_available_seq` does not cover those independent streams.

## Snapshot manifest

New snapshots are an immutable, ID-ordered union of live heads and purged graveyard entries. A record ID appears exactly once.

```json
{"kind":"head","record_id":"...","revision_id":"...","commit_seq":"...","deleted":false,"envelope":{}}
{"kind":"graveyard","record_id":"...","deleted_revision_id":"...","deleted_seq":"...","redaction":{"format":"atermius-record-redaction-proof-v1","redaction_id":"...","instance_id":"...","server_space_id":"...","vault_id":"...","record_id":"...","deleted_revision_id":"...","deleted_seq":"...","redaction_seq":"...","signing_public_key":"...","signature":"..."}}
```

The existing `item_count`, page cursor, final-page cardinality check, 4 MiB page limit, and snapshot expiry apply to both kinds. `item_count` is the number of distinct live-head plus purged-graveyard IDs. A graveyard-only item has no envelope and no record plaintext. A current tombstone that has not been purged remains a normal `head` item with its signed delete envelope.

## Old-client and device compatibility gates

- Once a Vault contains a redaction, changes, snapshot, revision, conflict-history/feed, direct-revision, push, conflict creation/resolution, and object-storage routes require exactly one `X-Atermius-Redaction-Marker: v1` before returning or accepting record or attachment payloads. This includes `GET /vaults/{vault_id}/objects/{object_id}`, `POST /vaults/{vault_id}/uploads/init`, `PUT /uploads/{upload_id}/chunks/{index}`, and `POST /uploads/{upload_id}/complete`; upload routes resolve the owning Vault from the upload reservation. Otherwise they return `426 CLIENT_REDACTION_CAPABILITY_REQUIRED`, without an object body, accepted chunk, upload completion, conflict mutation, or cursor advancement. The marker is transport metadata only and does not replace verification of each redaction proof.
- The gate applies to every object ID in a redacted Vault, including objects whose final record reference has already been removed and objects that are not yet collectible. Knowing an old object ID cannot bypass redaction through the object route. A compatible client can download an object when a live reference exists in that Vault. There is one bounded upload-retry exception: the authenticated user who owns a still-unexpired `completed` upload reservation may verify that same available object before the signed revision has linked it. The exception is scoped to the reservation's Vault, object, and user; expired or collected reservations and other Vault members do not grant access. Physical bytes may remain during the GC grace period after the API stops serving an unreferenced object. SQLite and restricted PostgreSQL enforce this rule.
- A purge is rejected unless every active device of every active Vault member has a currently active, verified report with `sync_redaction_version:1`. An offline active device still participates. The owner must explicitly revoke or retire an unsupported device before retrying.
- The check and purge share the Vault writer fence with membership, enrollment, report invalidation, push, restore, snapshot creation, and conflict writes. A concurrent missing-marker request is ordered before or after purge; it cannot invalidate a report and then commit an old write after purge.
- Once a redaction exists, a client without the transport marker cannot use an older snapshot or cursor to read around it.

The report says the client can understand the format. It is not an acknowledgement that the client has erased its local cache. The product guarantee remains deletion from active server state, not remote erasure of offline devices or backups.

## Owner initiated purge request

The SQLite and restricted PostgreSQL endpoint is `POST /api/v1/vaults/{vault_id}/records/{record_id}/purge`. It requires the exact `X-Atermius-Redaction-Marker: v1` header and an active Vault owner session. The body is deliberately bound to the tombstone visible to the user's recycle-bin action:

```json
{
  "expected_deleted_revision_id": "canonical-uuid",
  "expected_deleted_seq": "12"
}
```

The server accepts the request only when the supplied revision and sequence still identify the current deleted head and its graveyard reservation, and the tombstone's persisted `restore_until` deadline has elapsed. Before making any change it rechecks that every active device of every active Vault member has a non-invalidated, signature-valid v1 report against that device's current signing key. Offline active devices count. Unsupported or report-less devices must be explicitly retired or upgraded before purge can proceed. An unresolved conflict branch blocks purge.

During rollout, existing tombstones are backfilled from the matching delete revision using the effective valid restore-retention configuration at upgrade time. This preserves the cutoff the prior runtime would advertise at that moment; the prior schema did not record per-delete policy history, so a different historical value cannot be recovered. When a backup is restored, legacy tombstones use the restore-retention value in that archive's runtime-policy manifest, even if an operator accepts drift from the target environment. Automatic time-based tombstone purge remains disabled.

An exact retry is idempotent and returns the original proof, including after a lost response. A request for another tombstone after restore/delete returns `409 RECORD_DELETE_CHANGED`; a request before the restore deadline returns `409 RECORD_PURGE_NOT_DUE` with `restore_until`. Only an explicit request is available in this slice; automatic time-based purge remains disabled.

## Per-tombstone automatic-purge consent (stored; worker inactive)

The exposed Owner control is `PUT /api/v1/vaults/{vault_id}/records/{record_id}/automatic-purge`. Its strict body is `{expected_deleted_revision_id,expected_deleted_seq,expected_policy_revision,enabled}`. Only the active Vault Owner can set or revoke consent, and the path plus expected revision ID and sequence must identify the exact current retained tombstone. `expected_policy_revision` is a canonical non-negative decimal string used for compare-and-set; a stale policy returns `409 RECORD_AUTO_PURGE_POLICY_REVISION_CONFLICT` with the current revision in error details. A stale or superseded tombstone returns `409 RECORD_TOMBSTONE_CHANGED`. A device with a published report must send exactly one canonical v1 redaction marker on the authenticated request. PostgreSQL additionally requires the caller's current redaction-capability report when the Vault already contains a redacted record.

Consent is stored on the exact `(vault_id,record_id,deleted_revision_id,deleted_seq)` graveyard row, defaults to disabled at policy revision `0`, and never carries forward to a later delete revision. A changed enabled value increments the policy revision and writes a Vault audit event with action `vault.record_auto_purge_opt_in_changed` and source `api`; repeating the same value is idempotent and does not duplicate the audit. The response is `{vault_id,record_id,deleted_revision_id,deleted_seq,enabled,policy_revision}`. Opting out and later re-enabling each advance the policy revision. Restore removes that tombstone's policy, so a subsequent delete starts disabled at revision `0`. Explicit purge consumes enabled consent and resets it to disabled, advancing the revision when consent was enabled. Setting consent does not purge immediately, change the immutable `restore_until`, bypass the active-device capability reports or any other purge validation, or alter the existing explicit Owner purge route.

No automatic purge worker or scheduler currently runs. Any future Maintenance purge must recheck the exact tombstone identity, stored enabled state, due deadline, current Vault fence, capability reports, conflict state, snapshots, and object-reference ownership atomically with redaction. Backup restore opts enabled policies out; legacy backups without the exact consent state remain opted out. Consent cannot erase offline device copies, user exports, or earlier encrypted backups. Restoring a pre-purge backup can restore ciphertext, which is outside the active-server deletion guarantee.

History retention is intentionally non-destructive in this slice: revision and conflict sequence positions and their metadata rows remain available, with payload fields scrubbed and projected as redacted markers after purge. Incremental change events continue to use the existing contiguous 90-day prefix retention and its `minimum_available_seq` recovery response. Snapshot-bound history remains available until the associated snapshot expires (currently 24 hours); a purge invalidates all prior snapshot materializations before scrubbing envelopes. This avoids introducing independent history watermarks while keeping every existing position pageable.

## Client apply order

For a change event, the client verifies the proof against its pinned instance identity and the current Vault/server-space scope. In one local transaction it stores the proof, removes the record from active cache, quarantines same-ID pending operations as a user-visible non-pushable draft, and records the applied redaction. Only after that transaction commits may it advance the page cursor. Duplicate proofs are idempotent.

For snapshot recovery, the client stages every page, verifies every proof and the exact final item count, applies heads and graveyard entries in one local transaction, preserves/quarantines pending outbox state, and then activates the new snapshot cursor. After activation it pulls changes after the snapshot watermark before pushing any local operation. A failed page, proof, local erase, or cursor write leaves the previous cache/checkpoint/outbox active.

## Transaction and object cleanup requirements

Purge validates the current deleted head, its exact tombstone revision and sequence, and that revision's persisted `restore_until` inside the Vault writer fence. It preserves the graveyard proof, operation/batch receipts, revision/conflict sequence positions, and record-ID reservation. It removes only payloads that the proof makes unreachable. Corresponding object references are deleted in the same transaction; an object enters the existing delayed delete queue only after the final live reference is gone, and the collector rechecks references and backup/snapshot pins before deleting bytes. Reference removal must preserve attachments still reachable from another live record. Purge also revokes any completed-upload retry grant for an object once its last live reference is gone, so the narrow pre-link retry path cannot serve a purged attachment during the GC grace period. Where legacy data makes reference ownership ambiguous (for example, a revision ID shared across records while references are keyed only by Vault and revision ID), purge must fail closed or use a migration that establishes unambiguous ownership; it must never queue an object based on an inferred last reference.

The purge transaction invalidates active snapshot pages before removing any envelope. The old snapshot then returns `410 SNAPSHOT_REDACTED`; a fresh snapshot exposes the graveyard union item. Owner authorization, report compatibility, tombstone retention, and exact row counts are checked before any deletion. SQLite and restricted PostgreSQL implement the explicit action with the same ordering and rollback behavior. Automatic time-based tombstone purge remains disabled; physical object deletion continues through the existing delayed object collector after its grace period and reference/pin checks.
