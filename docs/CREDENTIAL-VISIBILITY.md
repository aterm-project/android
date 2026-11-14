# Credential visibility: private and administrator-visible accounts

[中文](CREDENTIAL-VISIBILITY.zh-CN.md) · [API contract](../protocol/API-CONTRACT.md#credential-visibility-v1) · [Documentation index](README.md)

Each account on a multi-user server has a **credential-visibility mode**. Only an
instance administrator can set it. Users cannot change their own mode, and their
client always shows which mode applies.

| Mode | What administrators can read | What the user sees |
| --- | --- | --- |
| `private` (default) | Nothing from saved Host credentials. This is the original zero-knowledge behavior. If the user forgets the master password, administrators cannot recover this data either. | A green "private" notice in account settings. |
| `admin_visible` | Everything in the Vaults the account belongs to: Host names and addresses, usernames, passwords, private keys, passphrases and other saved items. | An amber "administrators can see your credentials" notice, a persistent indicator, a one-time acknowledgement when the mode changes, and a list of recent administrator reads. |

The **master password is never sent to the server in either mode**, so no
administrator ever sees it. `admin_visible` does not let an administrator sign
in as the user, and it does not escrow the account key.

This document describes the server contract and trust model. The user
notices, automatic deposits and the administrator viewer are implemented by
the client apps.

Availability: SQLite deployments only. In the restricted PostgreSQL sync-core
runtime the routes are not registered, the `credential_visibility` capability
is not advertised and `/me` reports `credential_visibility: null`.

## How it works

1. **Escrow key.** An administrator's client creates an X25519 key pair and a
   20-byte recovery code. It uploads only the public key, a device-signed
   creation statement, the private key wrapped under that administrator's
   account key, and the private key wrapped under an Argon2id key derived from
   the recovery code. The server signs a descriptor of the public key with the
   instance key. Clients verify that signature against their pinned instance
   key before using it.
2. **Deposits.** The client of an `admin_visible` account seals each Vault key
   it holds (`crypto_box_seal`) to the escrow public key, signs the deposit with
   its device key and uploads it after sign-in, unlock, Vault creation, key
   rotation or a newly accepted share. The server stores ciphertext only.
3. **Reading.** An administrator re-enters their master password. Their client
   derives their account key, unwraps the escrow private key in memory,
   verifies and opens deposits, and decrypts the account's Vault records. The
   viewer is read-only and discards the key when it closes. A second
   administrator can open the key with the recovery code, then store their own
   wrap.
4. **Recording.** Every page of records read through the API writes an
   instance audit event (never coalesced) in the same transaction. The read is
   also written to the view log of **every active member of that Vault**, not
   only the account the administrator picked, because a shared Vault holds
   other members' entries too. It is also written to the view log of every
   account that authored a record on that page, even if that account's
   membership is now hidden by an organization `none` restriction or revoked
   (hiding is reversible, and the read exposed what that account saved).
   Each entry is coalesced per administrator, account and Vault for ten
   minutes, and the newest 200 entries per account are kept. Each affected
   account sees "administrator X viewed your credentials at T" and an account
   audit event. Listing an account's sealed deposits is not a view of
   anyone's credentials, but a listing that returns at least one deposit
   writes an instance audit event (`instance.credential_escrow_listed`).

The server and database never hold a key that can open a deposit, a wrap or a
record. A database dump together with every server key file cannot decrypt
anything here **without guessing an administrator's master password or the
recovery code**: the database holds each administrator's KDF salt, login
verifier and account-key envelope next to that administrator's wrap of the
escrow key (see [Trust model and limits](#trust-model-and-limits)). The
recovery code is high-entropy (160 bits), so the stored recovery wrap cannot
be guessed offline. Master passwords can be.

## Trust model and limits

Read these before enabling `admin_visible`:

* **It depends on the user's client.** Deposits are made by the user's own
  devices. A modified or outdated client can withhold deposits, or deposit a
  key that does not work. Administrators then see `pending`, or a decryption
  failure in the viewer. The server cannot force or verify the plaintext of a
  deposit.
* **Switching to private cannot undo past reads.** Switching an account to
  `private` immediately deletes the server-side deposits for its Vaults (unless
  another active member of a shared Vault is still `admin_visible`, see below)
  and blocks further reads. It cannot erase what an administrator already
  viewed, copied or wrote down. **After switching to private, change important
  passwords and keys.** Clients show this advice when the mode switches to
  private.
* **Shared Vaults.** If any active member of a Vault is `admin_visible`,
  administrators can read that whole Vault, including entries other members
  added. Vault lists show an "administrator visible" badge, and sharing flows
  warn members. Before an owner invites someone, or delivers a Vault key to an
  organization grantee, the owner's client asks the server whether that
  account is `admin_visible` and requires an explicit confirmation, because
  the share makes everything in the Vault, the owner's own passwords
  included, readable by administrators. The owner learns the recipient's mode
  this way, which the Vault badge would show anyway once the recipient
  joins. A `private` account that belongs to such a Vault is told so: its
  private-mode notice names the exception, and the account settings never
  claim that administrators can read nothing. Every active member, `private`
  ones included, and every author of a record that was read, sees each read
  of that Vault in their own view log. An administrator can still switch an
  existing member to `admin_visible` later; the badge is the only signal the
  other members get.
* **The weakest administrator master password protects every
  `admin_visible` account.** Each administrator's account key opens that
  administrator's wrap of the escrow key, which opens every deposit. Whoever
  obtains the database (a plaintext file, or an encrypted file together with
  its key file, or a backup together with the backup key) can guess any one
  administrator's master password offline from the stored KDF salt and
  verifier; one success opens every `admin_visible` account's Vaults. The
  server does not enforce administrator password strength or KDF parameters.
  Require long random master passwords for administrators, keep the set of
  administrators small, enable [database encryption](#data-at-rest-database-encryption),
  and keep the database key, the backup key and the data volume apart.
* **No admin_visible member, no deposits.** Deposits are kept only while at
  least one active member of the Vault is `admin_visible`. When the last one
  goes (switched to private, removed by the owner's key rotation or ownership
  transfer, restricted to `none` by an organization, or purged), the server
  deletes the Vault's deposits in the same transaction. If a remaining member
  is made `admin_visible` later, administrators can read the Vault only after
  that member's own client has deposited.
* **Administrators who also operate the server.** The view log covers reads
  through the API. Someone with both the escrow private key and direct database
  access (for example a server operator who is also an administrator) can
  decrypt deposits and records offline without creating a view entry.
  Database encryption at rest protects stolen database files and backups. It
  does not protect against the operator (see
  [Data at rest](#data-at-rest-database-encryption)).
* **Former administrators.** Removing a username from `ATERMIUS_ADMIN_USERNAMES`
  blocks the admin API immediately, but cannot erase a copy of the escrow key
  that person may have made. Reset the escrow key if a former administrator
  must lose access. Clients then deposit again under the new key.
* **Losing the key.** If every administrator wrap is lost and the recovery code
  is lost, nothing can be decrypted. Reset the key. `admin_visible` accounts
  then show `no_key` until a new key exists and `pending` until their clients
  deposit again.
* **Disabled accounts.** A disabled `admin_visible` account stays readable
  while its Vault memberships are active. This is intentional, so an
  organization can recover credentials after someone leaves. Its client
  cannot add new deposits while it is disabled. A read through a disabled (or
  deleting) account is still shown to every active member of the Vault; the
  disabled account itself sees it only if it is enabled again, and a deleted
  account's view log is removed when the account is purged.
* **Purged accounts.** When an account is purged, its device keys stay in the
  Vault's device archive, so its surviving deposits and records in shared
  Vaults remain verifiable by administrator clients. Vault IDs are cleared from
  its own account audit rows.
* **Interference between members.** Deposits are never overwritten. A
  malicious `admin_visible` member of a shared Vault could deposit an unusable
  key first. This only affects administrator visibility of that Vault, which
  the member could equally withhold. Resetting the key clears all deposits.

## Administration

* **Instance default.** New accounts get the instance default (`private` on a
  fresh server) unless their invitation names a mode. The bootstrap account
  uses the default. Changing the default never changes existing accounts. The
  registration screen shows the administrator-visible notice before the account
  is created when the default is `admin_visible` (`/api/v1/instance` returns
  `credential_visibility_default`).
* **Per account.** `PUT /api/v1/admin/accounts/{user_id}/credential-visibility`
  with `{"mode":"private"|"admin_visible"}`. Administrators may change their own
  account. Existing accounts became `private` when this feature was installed.
* **Per invitation.** `POST /api/v1/admin/account-invitations` accepts
  `credential_visibility`. The operator CLI accepts the same option:

  ```sh
  docker compose --env-file deploy/.env -f deploy/compose.yaml exec -T server \
    /usr/local/bin/atermius-server create-account-invite \
    --username 'person@example.com' --credential-visibility admin_visible
  ```

* **Escrow key.** Create it once from an administrator client. Store the
  recovery code offline; it is shown once. Other administrators open the key
  with the recovery code. Reset (`DELETE /api/v1/admin/credential-escrow/key`
  with `{"key_id":…,"confirm":"reset"}`) deletes the key, every administrator
  wrap and every deposit.
* **Status.** `GET /api/v1/admin/accounts` shows each account's mode and
  `escrow_status`: `not_required`, `no_key`, `pending` or `complete`.

### Audit events

| Event | Scope | When |
| --- | --- | --- |
| `instance.credential_policy_changed` | instance | The instance default changed |
| `instance.credential_visibility_changed` | instance | An account's mode changed (HMACed account ID) |
| `account.credential_visibility_changed` | affected account | Same change, visible to the user; actor = administrator account |
| `instance.credential_escrow_key_created` | instance | Escrow key registered |
| `instance.credential_escrow_key_wrap_stored` | instance | An administrator stored or replaced their own wrap |
| `instance.credential_escrow_key_reset` | instance | Key, wraps and deposits deleted |
| `instance.credential_escrow_listed` | instance | An administrator listed an account's Vaults and the listing returned at least one sealed deposit (HMACed account ID) |
| `instance.credential_escrow_viewed` | instance | Every page of records an administrator read (HMACed account ID of the named account) |
| `account.credential_viewed_by_admin` | every active member of the Vault, and every author of a served record | Same read, visible to each affected account; resource = Vault ID; coalesced per administrator, account and Vault for ten minutes |

Events contain no key, wrap, deposit, envelope or record content.

### Operational notes

* The record-read limit (120 pages per administrator per minute) is held in
  process memory. It is per server process and resets on restart.
* Backups contain the escrow tables like any other table. Deposits and wraps
  are ciphertext and cannot be opened without an administrator's account key or
  the recovery code. Modes, the instance default and the view log are plain
  rows, protected at rest only by
  [database encryption](#data-at-rest-database-encryption). After restoring an
  old backup, consider resetting the key if it was rotated or reset after that
  backup was made.
* After an instance signing-key rotation, the server re-signs the stored
  descriptor with the new key, but only if a key in the verified transition
  chain signed it originally. Clients keep verifying against their pinned key.
* Cross-implementation test vector: `protocol/test-vectors/credential-escrow-v1.json`.

## Data at rest: database encryption

The escrow state is stored in ordinary tables of the main SQLite database:
`instance_credential_policy`, `credential_escrow_keys`,
`credential_escrow_key_wraps`, `credential_escrow_envelopes`,
`credential_admin_views`, and the `credential_visibility` columns of `users`
and `account_invitations`. When
[database encryption at rest](runbooks/database-encryption.md) is enabled
(`ATERMIUS_DATABASE_KEY_FILE`), SQLCipher encrypts these tables together with
everything else: in `atermius.db`, its WAL, backup snapshots and restore
stages. There is no separate setting for escrow data. Administrators can check
`database_encryption` in `GET /api/v1/admin/overview`; the client's instance
overview and credential-visibility administration show a warning when it is
`disabled` (the database is not encrypted at rest) and a quiet "encrypted at
rest" status when it is `enabled`.

What SQLCipher adds for escrow data:

* **No offline attack from a stolen file.** Deposits and wraps are already
  ciphertext that the server cannot open. The weak point of a plaintext
  database is next to them: an administrator's KDF salt, login verifier and
  account-key envelope are in the same file as that administrator's wrap of the
  escrow key. Whoever copies a plaintext file can guess that administrator's
  master password offline and, if the guess succeeds, unwrap the escrow key and
  open every deposit. An encrypted database file, WAL, backup snapshot or
  volume copy gives nothing to guess against without the key file.
* **Hidden metadata.** Plain rows reveal which accounts are `admin_visible`,
  which Vaults have deposits, the instance default, the view log (which
  administrator read which account's credentials, and when) and usernames.
  SQLCipher hides all of these in stolen files.
* **Backups stay encrypted and complete.** A backup of an encrypted instance keeps
  the snapshot encrypted. Backup and restore, including a restore that rekeys
  the database or encrypts a legacy plaintext archive, carry the key,
  wraps, deposits, view log and modes unchanged.

What SQLCipher does not protect:

* **A running server.** While the server runs, the database key is in its
  memory and SQLite reads decrypted pages there. Root on the host, a memory
  dump or a debugger attached to the process sees the same rows as without
  encryption.
* **Anyone with both the key and the database.** An operator or attacker who
  holds the key file and the database file can open it like a plaintext
  database. The same applies to an encrypted backup archive together with
  `ATERMIUS_BACKUP_KEY_FILE`, because the archive carries the database key in
  its encrypted payload. They can read the metadata above and guess
  administrators' master passwords offline. Deposits are still sealed to the
  escrow key; opening them needs an administrator's account key or the
  recovery code, and **guessing any one administrator's master password
  yields that account key**, so the weakest administrator password guards
  every deposit. Keep the database key, the backup key and the data volume
  apart, and require strong master passwords for administrators.
* **Reads through the API.** Encryption at rest is transparent to the server.
  Administrator reads are accounted for by the view log, not by encryption.
* **Earlier plaintext copies.** Backups made before encryption was enabled,
  and storage that held the plaintext file before `database-encrypt`, still
  contain plaintext rows. See the runbook.

## Not covered

* PostgreSQL sync-core deployments (closed, see above).
* Pushing a notification to the user when a read happens. The read appears in
  account settings and in the user's audit feed the next time the client
  refreshes.
* Escrowing anything that is not in a Vault, such as local-only profiles,
  device-local SSH keys that were never saved to a Vault, or the master
  password.
