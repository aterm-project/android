use atermius_server::{
    Config, activate_pg_restore_stage, create_account_invitation, create_bootstrap_token,
    fence_pg_restore_stage_rollback, install_configured_admin_restore_stage, open_state,
    recover_server_generation, restore_instance_with_runtime_policy_drift,
    rotate_instance_signing_key, rotate_mfa_seed_encryption_key_for_selected_backend,
    run_maintenance, run_object_store_migration, run_operator_backup, serve_from_config,
    verify_instance_backup,
};
use base64::Engine as _;
use sha2::Digest as _;
use std::{
    io::{BufRead, BufReader, Write},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream},
    str::FromStr,
    time::Duration,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let command = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "serve".to_owned());
    if command == "healthcheck" {
        return healthcheck();
    }
    if command == "install-restore-stage"
        && std::env::args().nth(2).as_deref() == Some("--help")
        && std::env::args().nth(3).is_none()
    {
        print_install_restore_stage_help();
        return Ok(());
    }
    if command == "activate-pg-restore-stage"
        && std::env::args().nth(2).as_deref() == Some("--help")
        && std::env::args().nth(3).is_none()
    {
        print_activate_pg_restore_stage_help();
        return Ok(());
    }
    if command == "fence-pg-restore-stage-rollback"
        && std::env::args().nth(2).as_deref() == Some("--help")
        && std::env::args().nth(3).is_none()
    {
        print_fence_pg_restore_stage_rollback_help();
        return Ok(());
    }
    if command == "rotate-mfa-key"
        && std::env::args().nth(2).as_deref() == Some("--help")
        && std::env::args().nth(3).is_none()
    {
        print_rotate_mfa_key_help();
        return Ok(());
    }
    if command == "maintenance" {
        parse_maintenance_args(std::env::args().skip(2))?;
    }
    let config = Config::from_env();
    let database_url = database_url(&config);
    require_default_database_url(&config.data_dir, &database_url)?;
    if std::env::var("ATERMIUS_SYNC_BACKEND").is_ok_and(|value| value == "postgres")
        && !matches!(
            command.as_str(),
            "serve"
                | "bootstrap"
                | "create-account-invite"
                | "rotate-mfa-key"
                | "maintenance"
                | "activate-pg-restore-stage"
                | "fence-pg-restore-stage-rollback"
        )
    {
        return Err(
            "the restricted PostgreSQL runtime supports only serve, bootstrap, create-account-invite, rotate-mfa-key, maintenance, activate-pg-restore-stage, and fence-pg-restore-stage-rollback commands"
                .into(),
        );
    }
    if command == "install-restore-stage" {
        let (job_id, target) = parse_install_restore_stage_args(std::env::args().skip(2))?;
        let generation = install_configured_admin_restore_stage(config, &job_id, &target).await?;
        println!(
            "Restore stage installed at {} with generation {}. The source volume was not changed. This command does not switch the deployment or Compose volumes.",
            target.display(),
            generation
        );
        return Ok(());
    }
    if command == "activate-pg-restore-stage" {
        let job_id = parse_activate_pg_restore_stage_args(std::env::args().skip(2))?;
        let state = open_state(&database_url, config).await?;
        let activation = activate_pg_restore_stage(&state, &job_id).await?;
        println!(
            "{}",
            serde_json::json!({
                "status": activation.status,
                "job_id": activation.job_id,
                "target_database_name": activation.target_database_name,
                "target_database_oid": activation.target_database_oid,
                "schema": activation.schema,
                "generation": activation.generation,
                "object_store_id": activation.object_store_id,
                "restored_objects": activation.restored_objects,
                "activation_timestamp": activation.activation_timestamp,
            })
        );
        return Ok(());
    }
    if command == "fence-pg-restore-stage-rollback" {
        let job_id = parse_fence_pg_restore_stage_rollback_args(std::env::args().skip(2))?;
        let state = open_state(&database_url, config)
            .await
            .map_err(|_| "PostgreSQL restore rollback fence could not be completed")?;
        let fence = fence_pg_restore_stage_rollback(&state, &job_id).await?;
        println!(
            "{}",
            serde_json::json!({
                "status": fence.status,
                "job_id": fence.job_id,
                "target_database_name": fence.target_database_name,
                "target_database_oid": fence.target_database_oid,
                "schema": fence.schema,
                "generation": fence.generation,
                "object_store_id": fence.object_store_id,
                "restored_objects": fence.restored_objects,
                "rollback_timestamp": fence.rollback_timestamp,
            })
        );
        return Ok(());
    }
    if command == "restore" {
        let (archive, key_file, target, server_stopped, accept_runtime_policy_drift) =
            parse_restore_args()?;
        if !server_stopped {
            return Err("restore requires --server-stopped and an offline data directory".into());
        }
        let result = restore_instance_with_runtime_policy_drift(
            config,
            &archive,
            &key_file,
            &target,
            accept_runtime_policy_drift,
        )
        .await?;
        println!(
            "Validated restore staged at {} with new server generation {}. The active data directory was preserved; switch ATERMIUS_DATA_DIR only after reviewing the runbook.",
            target.display(),
            result.generation
        );
        if !result.accepted_runtime_policy_drift_fields.is_empty() {
            eprintln!(
                "WARNING: explicitly accepted runtime policy drift in fields: {}",
                result.accepted_runtime_policy_drift_fields.join(", ")
            );
        }
        return Ok(());
    }
    if command == "backup" {
        let (archive, key_file) = parse_backup_args()?;
        run_operator_backup(&config, &database_url, &archive, &key_file).await?;
        println!("Encrypted instance backup written to {}", archive.display());
        return Ok(());
    }
    if command == "verify-backup" {
        let (archive, key_file) = parse_archive_key_args("verify-backup")?;
        let result = verify_instance_backup(&config.data_dir, &archive, &key_file).await?;
        println!(
            "Backup verified: {} encrypted files; database migration version {}.",
            result.file_count, result.migration_version
        );
        return Ok(());
    }
    if command == "migrate-user-objects" {
        let migration_id = parse_object_store_migration_args()?;
        let migrated = run_object_store_migration(&config, &database_url, &migration_id).await?;
        println!("User object migration complete: {migrated} object(s) verified.");
        return Ok(());
    }
    if command == "rotate-mfa-key" {
        let (old_key_file, new_key_file) = parse_rotate_mfa_key_args(std::env::args().skip(2))?;
        let summary = rotate_mfa_seed_encryption_key_for_selected_backend(
            &config.data_dir,
            &database_url,
            &old_key_file,
            &new_key_file,
        )
        .await?;
        println!(
            "MFA seed encryption key rotation completed: {} active and {} pending seed envelope(s) re-encrypted. Configure the new key before restarting the server.",
            summary.active_envelopes, summary.pending_envelopes
        );
        return Ok(());
    }
    if command == "serve" {
        let bind = std::env::var("ATERMIUS_BIND").unwrap_or_else(|_| "0.0.0.0:8080".into());
        let address = SocketAddr::from_str(&bind)?;
        tracing::info!(%address,"starting Atermius server");
        serve_from_config(&database_url, config, address).await?;
        return Ok(());
    }
    let state = open_state(&database_url, config).await?;
    match command.as_str() {
        "bootstrap" => {
            let token = create_bootstrap_token(&state).await?;
            println!("Atermius one-time setup token (store securely; shown once):\n{token}");
            Ok(())
        }
        "create-account-invite" => {
            let mut username = None;
            let mut expires_in_seconds = None;
            let mut args = std::env::args().skip(2);
            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--username" => {
                        if username.is_some() {
                            return Err("--username may only be provided once".into());
                        }
                        username = Some(
                            args.next()
                                .ok_or("--username requires an email-like account name")?,
                        );
                    }
                    "--expires-in-seconds" => {
                        if expires_in_seconds.is_some() {
                            return Err("--expires-in-seconds may only be provided once".into());
                        }
                        let value = args
                            .next()
                            .ok_or("--expires-in-seconds requires an integer")?
                            .parse::<i64>()?;
                        expires_in_seconds = Some(value);
                    }
                    _ => return Err(format!("unknown account-invite option {arg:?}").into()),
                }
            }
            let username = username.ok_or("create-account-invite requires --username")?;
            let (token, normalized, expires_at) =
                create_account_invitation(&state, &username, expires_in_seconds).await?;
            println!(
                "Atermius account invitation (one-time; username={normalized}; expires_at={expires_at}):\n{token}"
            );
            Ok(())
        }
        "recover-generation" => {
            let mut args = std::env::args().skip(2);
            if args.next().as_deref() != Some("--server-stopped") || args.next().is_some() {
                return Err(
                    "recover-generation requires only --server-stopped; stop the server first"
                        .into(),
                );
            }
            let generation = recover_server_generation(&state).await?;
            println!(
                "Server generation changed to {generation}. Keep the server stopped until this command exits, then restart it."
            );
            Ok(())
        }
        "rotate-instance-key" => {
            let mut args = std::env::args().skip(2);
            if args.next().as_deref() != Some("--server-stopped") || args.next().is_some() {
                return Err(
                    "rotate-instance-key requires only --server-stopped; stop the server first"
                        .into(),
                );
            }
            let (public_key, generation) = rotate_instance_signing_key(&state).await?;
            let public_key_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(public_key)
                .map_err(|_| "rotated instance public key is invalid")?;
            let fingerprint = base64::engine::general_purpose::STANDARD
                .encode(sha2::Sha256::digest(public_key_bytes))
                .trim_end_matches('=')
                .to_owned();
            println!(
                "Instance signing key rotated; old-key transition recorded; generation changed to {generation}.\nNew public-key fingerprint: SHA256:{fingerprint}"
            );
            Ok(())
        }
        "maintenance" => {
            run_maintenance(&state).await?;
            println!("Maintenance completed.");
            Ok(())
        }
        _ => Err(format!(
            "unknown command {command:?}; expected `bootstrap`, `serve`, `healthcheck`, `create-account-invite`, `recover-generation`, `rotate-instance-key`, `rotate-mfa-key`, `maintenance`, `backup`, `verify-backup`, `migrate-user-objects`, `restore`, `install-restore-stage`, `activate-pg-restore-stage` or `fence-pg-restore-stage-rollback`"
        )
        .into()),
    }
}

fn parse_maintenance_args<I>(args: I) -> Result<(), Box<dyn std::error::Error>>
where
    I: Iterator<Item = String>,
{
    if args.into_iter().next().is_some() {
        return Err("maintenance accepts no arguments".into());
    }
    Ok(())
}

fn parse_activate_pg_restore_stage_args<I>(
    mut args: I,
) -> Result<String, Box<dyn std::error::Error>>
where
    I: Iterator<Item = String>,
{
    if args.next().as_deref() != Some("--job-id") {
        return Err(
            "activate-pg-restore-stage requires --job-id <canonical-lowercase-uuid>".into(),
        );
    }
    let job_id = args
        .next()
        .ok_or("activate-pg-restore-stage --job-id requires a UUID")?;
    let parsed = uuid::Uuid::parse_str(&job_id)?;
    if parsed.to_string() != job_id {
        return Err("--job-id must be a canonical lowercase UUID".into());
    }
    if args.next().is_some() {
        return Err("activate-pg-restore-stage accepts only --job-id <UUID>".into());
    }
    Ok(job_id)
}

fn print_activate_pg_restore_stage_help() {
    println!(
        "Usage: atermius-server activate-pg-restore-stage --job-id <canonical-lowercase-uuid>\n\nRecords a durable activation marker in the promoted PostgreSQL restore target. Run after switching ATERMIUS_SYNC_PG_URL to that target and before opening external traffic. The restore-stage receipt and target marker must match; the activation operation serializes with restore-stage discard. The command prints one safe JSON status line."
    );
}

fn parse_fence_pg_restore_stage_rollback_args<I>(
    mut args: I,
) -> Result<String, Box<dyn std::error::Error>>
where
    I: Iterator<Item = String>,
{
    if args.next().as_deref() != Some("--job-id") {
        return Err(
            "fence-pg-restore-stage-rollback requires --job-id <canonical-lowercase-uuid>".into(),
        );
    }
    let job_id = args
        .next()
        .ok_or("fence-pg-restore-stage-rollback --job-id requires a UUID")?;
    let parsed = uuid::Uuid::parse_str(&job_id)?;
    if parsed.to_string() != job_id {
        return Err("--job-id must be a canonical lowercase UUID".into());
    }
    if args.next().is_some() {
        return Err("fence-pg-restore-stage-rollback accepts only --job-id <UUID>".into());
    }
    Ok(job_id)
}

fn print_fence_pg_restore_stage_rollback_help() {
    println!(
        "Usage: atermius-server fence-pg-restore-stage-rollback --job-id <canonical-lowercase-uuid>\n\nRecords a durable rollback fence in the promoted PostgreSQL restore target. Run after switching ATERMIUS_SYNC_PG_URL to that target and before rollback teardown. The restore-stage receipt and target marker must match; this operation serializes with activation and discard. The command prints one safe JSON status line."
    );
}

fn parse_install_restore_stage_args<I>(
    args: I,
) -> Result<(String, std::path::PathBuf), Box<dyn std::error::Error>>
where
    I: Iterator<Item = String>,
{
    let mut restore_job_id = None;
    let mut target_data_dir = None;
    let mut server_stopped = false;
    let mut args = args;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--restore-job-id" => {
                if restore_job_id.is_some() {
                    return Err("--restore-job-id may only be provided once".into());
                }
                let value = args.next().ok_or("--restore-job-id requires a UUID")?;
                let parsed = uuid::Uuid::parse_str(&value)?;
                if parsed.to_string() != value {
                    return Err("--restore-job-id must be a canonical lowercase UUID".into());
                }
                restore_job_id = Some(value);
            }
            "--target-data-dir" => {
                if target_data_dir.is_some() {
                    return Err("--target-data-dir may only be provided once".into());
                }
                target_data_dir = Some(std::path::PathBuf::from(
                    args.next().ok_or("--target-data-dir requires a path")?,
                ));
            }
            "--server-stopped" if !server_stopped => server_stopped = true,
            "--server-stopped" => {
                return Err("--server-stopped may only be provided once".into());
            }
            _ => return Err(format!("unknown install-restore-stage option {arg:?}").into()),
        }
    }
    if !server_stopped {
        return Err(
            "install-restore-stage requires --server-stopped; stop the server first".into(),
        );
    }
    Ok((
        restore_job_id.ok_or("install-restore-stage requires --restore-job-id")?,
        target_data_dir.ok_or("install-restore-stage requires --target-data-dir")?,
    ))
}

fn print_install_restore_stage_help() {
    println!(
        "Usage: atermius-server install-restore-stage --restore-job-id UUID --target-data-dir <new-volume>/data --server-stopped\n\nInstalls a completed Web restore stage into a new, absent data directory.\nThe server must be stopped. The source data directory is opened read-only; an existing, unlocked server.lock is required.\nAfter an offline SQLite checkpoint and full close, source -wal, -shm and -journal sidecars must all be absent.\nThe stage must have been prepared under the current runtime policy. Legacy stages must be staged again.\nThis offline command does not call the API, modify the source volume, or switch a Compose/container volume."
    );
}

fn parse_object_store_migration_args() -> Result<String, Box<dyn std::error::Error>> {
    let mut migration_id = None;
    let mut server_stopped = false;
    let mut args = std::env::args().skip(2);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--migration-id" => {
                if migration_id.is_some() {
                    return Err("--migration-id may only be provided once".into());
                }
                let value = args.next().ok_or("--migration-id requires a UUID")?;
                let parsed = uuid::Uuid::parse_str(&value)?;
                if parsed.to_string() != value {
                    return Err("--migration-id must be a canonical lowercase UUID".into());
                }
                migration_id = Some(value);
            }
            "--server-stopped" if !server_stopped => server_stopped = true,
            "--server-stopped" => return Err("--server-stopped may only be provided once".into()),
            _ => return Err("unknown migrate-user-objects option".into()),
        }
    }
    if !server_stopped {
        return Err("migrate-user-objects requires --server-stopped; stop the server first".into());
    }
    migration_id.ok_or_else(|| "migrate-user-objects requires --migration-id".into())
}

fn parse_rotate_mfa_key_args<I>(
    args: I,
) -> Result<(std::path::PathBuf, std::path::PathBuf), Box<dyn std::error::Error>>
where
    I: Iterator<Item = String>,
{
    let mut old_key_file = None;
    let mut new_key_file = None;
    let mut server_stopped = false;
    let mut args = args;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--old-key-file" => {
                if old_key_file.is_some() {
                    return Err("--old-key-file may only be provided once".into());
                }
                old_key_file = Some(std::path::PathBuf::from(
                    args.next().ok_or("--old-key-file requires a path")?,
                ));
            }
            "--new-key-file" => {
                if new_key_file.is_some() {
                    return Err("--new-key-file may only be provided once".into());
                }
                new_key_file = Some(std::path::PathBuf::from(
                    args.next().ok_or("--new-key-file requires a path")?,
                ));
            }
            "--server-stopped" if !server_stopped => server_stopped = true,
            "--server-stopped" => {
                return Err("--server-stopped may only be provided once".into());
            }
            _ => return Err(format!("unknown rotate-mfa-key option {arg:?}").into()),
        }
    }
    if !server_stopped {
        return Err("rotate-mfa-key requires --server-stopped; stop the server first".into());
    }
    Ok((
        old_key_file.ok_or("rotate-mfa-key requires --old-key-file")?,
        new_key_file.ok_or("rotate-mfa-key requires --new-key-file")?,
    ))
}

fn print_rotate_mfa_key_help() {
    println!(
        "Usage: atermius-server rotate-mfa-key --old-key-file <current-key> --new-key-file <staged-key> --server-stopped\n\nRe-encrypts active and pending TOTP seed envelopes in one transaction. SQLite remains the default; PostgreSQL is selected only with ATERMIUS_SYNC_BACKEND=postgres and the configured shared schema. Both key files must be owner-only regular files with different 32-byte keys. PostgreSQL rotation takes an exclusive database advisory lock and refuses while any other client session remains. This command does not replace either key file; point ATERMIUS_MFA_ENCRYPTION_KEY_FILE at the new key before restarting the server."
    );
}

fn database_url(config: &Config) -> String {
    std::env::var("ATERMIUS_DATABASE_URL").unwrap_or_else(|_| {
        format!(
            "sqlite://{}/atermius.db?mode=rwc",
            config.data_dir.display()
        )
    })
}

fn require_default_database_url(
    data_dir: &std::path::Path,
    database_url: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let expected = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
    if database_url != expected {
        return Err("the main application database must be SQLite at ATERMIUS_DATA_DIR/atermius.db; external or custom database URLs are rejected".into());
    }
    match std::fs::symlink_metadata(data_dir.join("atermius.db")) {
        Ok(metadata) if metadata.file_type().is_file() => {}
        Ok(_) => {
            return Err("the instance database path must be a regular non-symlink file".into());
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
    };

    use uuid::Uuid;

    use super::{
        parse_activate_pg_restore_stage_args, parse_fence_pg_restore_stage_rollback_args,
        parse_install_restore_stage_args, parse_maintenance_args, parse_rotate_mfa_key_args,
        require_default_database_url,
    };

    fn temp_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!("atermius-main-db-{}", Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        path
    }

    fn expected_url(data_dir: &Path) -> String {
        format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display())
    }

    #[test]
    fn maintenance_cli_rejects_all_arguments_before_opening_runtime_state() {
        assert!(parse_maintenance_args(std::iter::empty()).is_ok());
        assert!(parse_maintenance_args(vec!["--unknown".to_owned()].into_iter()).is_err());
        assert!(parse_maintenance_args(vec!["--help".to_owned()].into_iter()).is_err());
        assert!(
            parse_maintenance_args(vec!["--retention-days".to_owned(), "1".to_owned()].into_iter())
                .is_err()
        );
    }

    #[test]
    fn activate_pg_restore_stage_cli_accepts_only_one_canonical_lowercase_job_id() {
        let job_id = Uuid::new_v4().to_string();
        assert_eq!(
            parse_activate_pg_restore_stage_args(
                vec!["--job-id".to_owned(), job_id.clone()].into_iter()
            )
            .unwrap(),
            job_id
        );
        for args in [
            vec![],
            vec!["--job-id".to_owned()],
            vec!["--job-id".to_owned(), "not-a-uuid".to_owned()],
            vec![
                "--job-id".to_owned(),
                Uuid::new_v4().to_string().to_uppercase(),
            ],
            vec![
                "--job-id".to_owned(),
                Uuid::new_v4().to_string(),
                "--force".to_owned(),
            ],
            vec!["--force".to_owned(), Uuid::new_v4().to_string()],
        ] {
            assert!(parse_activate_pg_restore_stage_args(args.into_iter()).is_err());
        }
    }

    #[test]
    fn fence_pg_restore_stage_rollback_cli_accepts_only_one_canonical_lowercase_job_id() {
        let job_id = Uuid::new_v4().to_string();
        assert_eq!(
            parse_fence_pg_restore_stage_rollback_args(
                vec!["--job-id".to_owned(), job_id.clone()].into_iter()
            )
            .unwrap(),
            job_id
        );
        for args in [
            vec![],
            vec!["--job-id".to_owned()],
            vec!["--job-id".to_owned(), "not-a-uuid".to_owned()],
            vec![
                "--job-id".to_owned(),
                Uuid::new_v4().to_string().to_uppercase(),
            ],
            vec![
                "--job-id".to_owned(),
                Uuid::new_v4().to_string(),
                "--force".to_owned(),
            ],
            vec!["--force".to_owned(), Uuid::new_v4().to_string()],
        ] {
            assert!(parse_fence_pg_restore_stage_rollback_args(args.into_iter()).is_err());
        }
    }

    #[test]
    fn only_database_inside_data_dir_is_supported() {
        let data_dir = temp_dir();
        let expected = expected_url(&data_dir);
        require_default_database_url(&data_dir, &expected).unwrap();
        assert!(
            require_default_database_url(&data_dir, "sqlite:///shared/atermius.db?mode=rwc")
                .is_err()
        );
        fs::remove_dir_all(data_dir).unwrap();
    }

    #[test]
    fn install_restore_stage_cli_requires_exact_canonical_offline_arguments() {
        let job_id = Uuid::new_v4().to_string();
        let parsed = parse_install_restore_stage_args(
            vec![
                "--restore-job-id".to_owned(),
                job_id.clone(),
                "--target-data-dir".to_owned(),
                "/new-volume/data".to_owned(),
                "--server-stopped".to_owned(),
            ]
            .into_iter(),
        )
        .unwrap();
        assert_eq!(parsed.0, job_id);
        assert_eq!(parsed.1, PathBuf::from("/new-volume/data"));

        let invalid_id = Uuid::new_v4().to_string().to_uppercase();
        assert!(
            parse_install_restore_stage_args(
                vec![
                    "--restore-job-id".to_owned(),
                    invalid_id,
                    "--target-data-dir".to_owned(),
                    "/new-volume/data".to_owned(),
                    "--server-stopped".to_owned(),
                ]
                .into_iter(),
            )
            .is_err()
        );
        assert!(
            parse_install_restore_stage_args(
                vec![
                    "--restore-job-id".to_owned(),
                    Uuid::new_v4().to_string(),
                    "--target-data-dir".to_owned(),
                    "/new-volume/data".to_owned(),
                ]
                .into_iter(),
            )
            .is_err()
        );
        assert!(
            parse_install_restore_stage_args(
                vec![
                    "--restore-job-id".to_owned(),
                    Uuid::new_v4().to_string(),
                    "--target-data-dir".to_owned(),
                    "/new-volume/data".to_owned(),
                    "--server-stopped".to_owned(),
                    "--force".to_owned(),
                ]
                .into_iter(),
            )
            .is_err()
        );
    }

    #[test]
    fn rotate_mfa_key_cli_requires_both_key_files_and_explicit_offline_confirmation() {
        let parsed = parse_rotate_mfa_key_args(
            vec![
                "--old-key-file".to_owned(),
                "/secrets/mfa-old.key".to_owned(),
                "--new-key-file".to_owned(),
                "/secrets/mfa-next.key".to_owned(),
                "--server-stopped".to_owned(),
            ]
            .into_iter(),
        )
        .unwrap();
        assert_eq!(parsed.0, PathBuf::from("/secrets/mfa-old.key"));
        assert_eq!(parsed.1, PathBuf::from("/secrets/mfa-next.key"));
        assert!(
            parse_rotate_mfa_key_args(
                vec![
                    "--old-key-file".to_owned(),
                    "/old.key".to_owned(),
                    "--new-key-file".to_owned(),
                    "/new.key".to_owned(),
                ]
                .into_iter(),
            )
            .is_err()
        );
        assert!(
            parse_rotate_mfa_key_args(vec!["--server-stopped".to_owned()].into_iter(),).is_err()
        );
        assert!(
            parse_rotate_mfa_key_args(
                vec![
                    "--old-key-file".to_owned(),
                    "/old.key".to_owned(),
                    "--old-key-file".to_owned(),
                    "/second-old.key".to_owned(),
                    "--new-key-file".to_owned(),
                    "/new.key".to_owned(),
                    "--server-stopped".to_owned(),
                ]
                .into_iter(),
            )
            .is_err()
        );
        assert!(
            parse_rotate_mfa_key_args(
                vec![
                    "--old-key-file".to_owned(),
                    "/old.key".to_owned(),
                    "--new-key-file".to_owned(),
                    "/new.key".to_owned(),
                    "--server-stopped".to_owned(),
                    "--server-stopped".to_owned(),
                ]
                .into_iter(),
            )
            .is_err()
        );
        assert!(
            parse_rotate_mfa_key_args(
                vec![
                    "--old-key-file".to_owned(),
                    "/old.key".to_owned(),
                    "--new-key-file".to_owned(),
                    "/new.key".to_owned(),
                    "--server-stopped".to_owned(),
                    "--database-url".to_owned(),
                    "postgresql://unexpected".to_owned(),
                ]
                .into_iter(),
            )
            .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn database_symlink_is_rejected_before_sqlite_opens_it() {
        use std::os::unix::fs::symlink;

        let data_dir = temp_dir();
        let outside = data_dir.with_extension("outside.db");
        fs::write(&outside, b"do not open this file").unwrap();
        symlink(&outside, data_dir.join("atermius.db")).unwrap();
        assert!(require_default_database_url(&data_dir, &expected_url(&data_dir)).is_err());
        fs::remove_dir_all(&data_dir).unwrap();
        fs::remove_file(outside).unwrap();
    }
}

fn parse_backup_args()
-> Result<(std::path::PathBuf, std::path::PathBuf), Box<dyn std::error::Error>> {
    parse_archive_key_args("backup")
}

fn parse_archive_key_args(
    command: &str,
) -> Result<(std::path::PathBuf, std::path::PathBuf), Box<dyn std::error::Error>> {
    let mut archive = None;
    let mut key_file = None;
    let mut args = std::env::args().skip(2);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--archive" => {
                if archive.is_some() {
                    return Err(format!("--archive may only be provided once for {command}").into());
                }
                archive = Some(
                    args.next()
                        .ok_or_else(|| format!("--archive requires a path for {command}"))?
                        .into(),
                );
            }
            "--key-file" => {
                if key_file.is_some() {
                    return Err(
                        format!("--key-file may only be provided once for {command}").into(),
                    );
                }
                key_file = Some(
                    args.next()
                        .ok_or_else(|| format!("--key-file requires a path for {command}"))?
                        .into(),
                );
            }
            _ => return Err(format!("unknown {command} option {arg:?}").into()),
        }
    }
    Ok((
        archive.ok_or_else(|| format!("{command} requires --archive"))?,
        key_file.ok_or_else(|| format!("{command} requires --key-file"))?,
    ))
}

fn parse_restore_args() -> Result<
    (
        std::path::PathBuf,
        std::path::PathBuf,
        std::path::PathBuf,
        bool,
        bool,
    ),
    Box<dyn std::error::Error>,
> {
    let mut archive = None;
    let mut key_file = None;
    let mut target = None;
    let mut server_stopped = false;
    let mut accept_runtime_policy_drift = false;
    let mut args = std::env::args().skip(2);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--archive" => {
                if archive.is_some() {
                    return Err("--archive may only be provided once".into());
                }
                archive = Some(args.next().ok_or("--archive requires a path")?.into());
            }
            "--key-file" => {
                if key_file.is_some() {
                    return Err("--key-file may only be provided once".into());
                }
                key_file = Some(args.next().ok_or("--key-file requires a path")?.into());
            }
            "--target-data-dir" => {
                if target.is_some() {
                    return Err("--target-data-dir may only be provided once".into());
                }
                target = Some(
                    args.next()
                        .ok_or("--target-data-dir requires a path")?
                        .into(),
                );
            }
            "--server-stopped" => {
                if server_stopped {
                    return Err("--server-stopped may only be provided once".into());
                }
                server_stopped = true;
            }
            "--accept-runtime-policy-drift" => {
                if accept_runtime_policy_drift {
                    return Err("--accept-runtime-policy-drift may only be provided once".into());
                }
                accept_runtime_policy_drift = true;
            }
            _ => return Err(format!("unknown restore option {arg:?}").into()),
        }
    }
    Ok((
        archive.ok_or("restore requires --archive")?,
        key_file.ok_or("restore requires --key-file")?,
        target.ok_or("restore requires --target-data-dir")?,
        server_stopped,
        accept_runtime_policy_drift,
    ))
}

/// Performs the same-origin HTTP readiness check without initializing a second
/// database pool. This keeps container health probes self-contained in the
/// minimal runtime image (no curl/wget package needed).
fn healthcheck() -> Result<(), Box<dyn std::error::Error>> {
    let bind = std::env::var("ATERMIUS_BIND").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let address = SocketAddr::from_str(&bind)?;
    let loopback = SocketAddr::new(
        if address.is_ipv4() {
            IpAddr::V4(Ipv4Addr::LOCALHOST)
        } else {
            IpAddr::V6(Ipv6Addr::LOCALHOST)
        },
        address.port(),
    );
    let stream = TcpStream::connect_timeout(&loopback, Duration::from_secs(2))?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut reader = BufReader::new(stream);
    reader
        .get_mut()
        .write_all(b"GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")?;
    let mut status_line = String::new();
    reader.read_line(&mut status_line)?;
    if status_line.starts_with("HTTP/1.") && status_line.split_whitespace().nth(1) == Some("200") {
        Ok(())
    } else {
        Err(format!("readiness endpoint returned an unhealthy response: {status_line:?}").into())
    }
}
