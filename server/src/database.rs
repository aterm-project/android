//! Main application database URL selection.
//!
//! The account, lifecycle, object, maintenance, and application stores remain
//! SQLite-backed. The separately configured restricted PostgreSQL sync-core
//! connection is opened by `pg_sync_runtime`; do not pass its URL through this
//! parser or mistake SQLx parser behavior for general PostgreSQL support.

use std::str::FromStr;

use axum::http::StatusCode;
use sqlx::sqlite::SqliteConnectOptions;

use crate::ApiError;

pub(crate) fn parse_sqlite_database_url(
    database_url: &str,
) -> Result<SqliteConnectOptions, ApiError> {
    let scheme = database_url.split_once(':').map(|(scheme, _)| scheme);
    if scheme != Some("sqlite") {
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "UNSUPPORTED_DATABASE_BACKEND",
            "the main application database supports SQLite only",
        ));
    }

    SqliteConnectOptions::from_str(database_url).map_err(ApiError::internal)
}

#[cfg(test)]
mod tests {
    use super::parse_sqlite_database_url;
    use crate::{Config, open_state};

    #[test]
    fn main_database_accepts_sqlite_and_rejects_other_backends_without_echoing_urls() {
        for url in [
            "sqlite::memory:",
            "sqlite:///var/lib/atermius/atermius.db?mode=rwc",
        ] {
            assert!(parse_sqlite_database_url(url).is_ok(), "{url}");
        }

        for url in [
            "postgres://operator:do-not-log@db.example/vault",
            "postgresql://operator:do-not-log@db.example/vault",
            "mysql://operator:do-not-log@db.example/vault",
        ] {
            let error = parse_sqlite_database_url(url).unwrap_err();
            assert_eq!(error.body.code, "UNSUPPORTED_DATABASE_BACKEND");
            assert_eq!(
                error.body.message,
                "the main application database supports SQLite only"
            );
            assert!(!error.to_string().contains("do-not-log"));
        }
    }

    #[tokio::test]
    async fn open_state_rejects_postgresql_before_creating_data_directory() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-unsupported-db-{}", uuid::Uuid::new_v4()));
        let mut config = Config::from_env();
        config.data_dir = data_dir.clone();

        let error = match open_state(
            "postgresql://operator:do-not-log@127.0.0.1/atermius",
            config,
        )
        .await
        {
            Ok(_) => panic!("PostgreSQL URL unexpectedly opened a server state"),
            Err(error) => error,
        };

        assert_eq!(error.body.code, "UNSUPPORTED_DATABASE_BACKEND");
        assert!(!error.to_string().contains("do-not-log"));
        assert!(!data_dir.exists());
    }
}
