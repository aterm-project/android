# Share a Host

[中文](SHARING.md) · [First use](GETTING_STARTED.en.md)

## Registered users and teams

1. Sign in to the same instance. In Account settings, open organizations and create/join the appropriate organization. The server normally restricts organization creation to configured instance administrators.
2. Add members/teams or issue an organization join link. Recipients still need an account permitted by the instance's account-registration policy.
3. Open the Host menu → **Share…** → members/teams. Prefer a dedicated sharing Vault for only the selected Host. Review every copied key, group or jump-host dependency; whole-Vault sharing is a separate choice.
4. Set the desired role, verify the recipient device fingerprint and explicitly deliver the encrypted key. An organization administrator cannot obtain a Vault key just by adding a grant. Pending-key states are not an active cryptographic membership.
5. When changing an accepted member's role, use the owner-confirmed Make Editor/Viewer action. Removing a member restricts server access immediately; the Vault owner still needs key rotation, and any credentials already seen by the recipient should be changed.

## Temporary browser links

The operator must first enable SQLite cloud access, guacd, an exact HTTPS public origin, a gateway key and narrow target CIDR/port rules. See the server's [deployment guide](https://github.com/aterm-project/server/blob/main/docs/CLOUD-SHARING.md).

1. Establish the target's trusted SSH host key or RDP certificate pin.
2. In **Share…**, select temporary access and choose the start/expiry, custom address, openings, connection/concurrency limits and clipboard/read-only policy.
3. Copy the complete link once. The secret cannot be displayed again; rotate it if lost. Anyone holding the link may use it within its policy.
4. The visitor opens the link in a browser, clicks **Continue** to redeem and **Connect** to open a session. Nothing redeems or connects automatically. Refresh resumes only the same link's session.
5. Use activity to inspect sessions or terminate access; pause, revoke or rotate the link when required.

The gateway can decrypt login capsules and observe the session; this temporary-access mode is not zero-knowledge. Guests do not receive the login through the sharing API, but the remote account's own permissions still determine what they can do. File/drive/printing/recording channels are not offered by this guest flow. VNC is opt-in and not live-validated.

Openings are counted on redemption. Connection attempts count when the gateway admits an attempt; capacity/concurrency refusals do not consume that attempt, while target/login failure after admission may. Links use UTC time windows. Recurring schedules are not implemented.

## Missing Share controls

Check server capabilities, SQLite mode, account/Vault role and target trust. Switching account, instance or Vault while sharing cancels stale operations; an error may report a step already committed on the old server. It does not silently roll back that step or install old keys into a new session.
