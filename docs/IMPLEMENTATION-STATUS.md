# Implementation and verification boundaries

[Install](install/server.en.md) · [中文安装](install/server.md) · [Cloud behavior](CLOUD-SHARING.md)

This page describes the 2026-11-09 cloud integration baseline. Documentation updates do not establish new native builds or a hosted service. At that baseline the clients and the server were separate repositories, so "each platform repository" and "per repository" below refer to the pre-merge layout; since 2026-11-14 the client source is `apps/client/` in this repository, and the linked server CI run stays in the archived `server` repository.

| Area | Current boundary |
| --- | --- |
| SQLite Vault sync | Existing signed membership/device and encrypted-record/object protocol |
| Organizations and member Host sharing | Implemented; desired grants require owner-confirmed encrypted key delivery |
| Temporary browser SSH/RDP | Implemented opt-in trusted gateway with schedule, slug, quotas, activity and revocation |
| PostgreSQL | Restricted existing sync-core/allowlisted routes; cloud routes remain closed |
| Browser normal SSH/SFTP | Restricted Relay required; separate from the trusted guest gateway |
| Native clients | Source owned by each platform repository; platform build/signing and device acceptance are separate |
| Physical redirection/multiple monitors | Requires compatible hardware and separate acceptance; no new hardware pass is claimed |

## Verification

- [Server source CI](https://github.com/aterm-project/server/actions/runs/42584697609):426 Rust cases passed,0 failed,114 existing PG-gated ignores.
- Client source CI at the same integration:37 focused cases per repository; Web additionally built its JS release and verified the real pinned nginx runtime.
- Separate local merged-client acceptance covered134 unique cases, plus normal/guest startup browser checks.
- The isolated gateway suite passed12 cases; the final merged guest browser ran an additional actual SSH gateway flow with no skips. RDP checks establish certificate pinning and rendered frames, not full interactive Windows GUI or all device/hardware behavior. VNC through the temporary gateway has no live acceptance claim.
- The full Flutter suite has disclosed historical failures. Focused checks and missing-fixture skips are not represented as a full-suite pass.

The gateway can decrypt login capsules and observe sessions. Losing its separate key requires owners to reseal old capsules. Member removal restricts server access immediately but cannot erase credentials or keys a recipient already learned. Operational procedures and PostgreSQL evidence remain scoped to their own [runbooks](README.md).
