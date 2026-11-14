//! Internal identity used by the shared tombstone-redaction transaction.
//!
//! The HTTP route can construct only `Owner` after normal authentication.
//! Maintenance callers use a separate guarded repository entry point and do
//! not synthesize account or device identities.

use crate::auth::AuthUser;

#[derive(Clone, Copy)]
pub(crate) enum RecordPurgeActor<'a> {
    Owner(&'a AuthUser),
    #[allow(dead_code)] // Constructed only through dormant internal maintenance entrypoints.
    Maintenance,
}
