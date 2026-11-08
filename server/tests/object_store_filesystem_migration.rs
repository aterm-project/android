use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

#[tokio::test]
async fn migration_0035_preserves_s3_rows_and_adds_checked_filesystem_backend() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(":memory:")
                .foreign_keys(true),
        )
        .await
        .expect("create in-memory SQLite database");
    sqlx::raw_sql(
        "CREATE TABLE users(user_id TEXT PRIMARY KEY); \
         CREATE TABLE vaults(vault_id TEXT PRIMARY KEY,owner_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE); \
         INSERT INTO users VALUES('user'); INSERT INTO vaults VALUES('vault','user'); \
         CREATE TABLE blob_objects(vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,object_id TEXT NOT NULL,bytes BLOB NOT NULL,size INTEGER NOT NULL,sha256 TEXT NOT NULL,created_at TEXT NOT NULL,gc_after INTEGER,storage_backend TEXT NOT NULL DEFAULT 'sqlite' CHECK(storage_backend IN ('sqlite','s3')),storage_key TEXT,storage_store_id TEXT,storage_state TEXT NOT NULL DEFAULT 'available' CHECK(storage_state IN ('available','deleting')),PRIMARY KEY(vault_id,object_id)); \
         CREATE INDEX idx_blob_objects_gc_after ON blob_objects(gc_after) WHERE gc_after IS NOT NULL; \
         CREATE TABLE object_references(vault_id TEXT NOT NULL,revision_id TEXT NOT NULL,object_id TEXT NOT NULL,PRIMARY KEY(vault_id,revision_id,object_id),FOREIGN KEY(vault_id,object_id) REFERENCES blob_objects(vault_id,object_id) ON DELETE CASCADE); \
         CREATE TABLE uploads(upload_id TEXT PRIMARY KEY,vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,user_id TEXT NOT NULL REFERENCES users(user_id),object_id TEXT NOT NULL,expected_size INTEGER NOT NULL,expected_sha256 TEXT NOT NULL,chunk_size INTEGER NOT NULL,state TEXT NOT NULL DEFAULT 'open',expires_at TEXT NOT NULL,created_at TEXT NOT NULL,storage_backend TEXT NOT NULL DEFAULT 'sqlite' CHECK(storage_backend IN ('sqlite','s3')),storage_store_id TEXT); \
         CREATE TABLE upload_chunks(upload_id TEXT NOT NULL REFERENCES uploads(upload_id) ON DELETE CASCADE,chunk_index INTEGER NOT NULL,bytes BLOB NOT NULL,sha256 TEXT NOT NULL,PRIMARY KEY(upload_id,chunk_index)); \
         CREATE TABLE object_delete_queue(queue_id TEXT PRIMARY KEY,storage_backend TEXT NOT NULL CHECK(storage_backend='s3'),storage_key TEXT NOT NULL,storage_store_id TEXT NOT NULL,expected_size INTEGER NOT NULL CHECK(expected_size>0),expected_sha256 TEXT NOT NULL CHECK(length(expected_sha256)=64),state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','retry_wait','quarantined')),attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count>=0),next_attempt_at INTEGER NOT NULL,last_failure_category TEXT CHECK(last_failure_category IS NULL OR last_failure_category IN ('remote_unavailable','integrity_mismatch')),created_at TEXT NOT NULL,UNIQUE(storage_store_id,storage_key)); \
         CREATE INDEX idx_object_delete_queue_due ON object_delete_queue(state,next_attempt_at,created_at,queue_id); \
         INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after,storage_backend,storage_key,storage_store_id,storage_state) VALUES('vault','object',X'',8,lower(hex(randomblob(32))),'created',NULL,'s3','key','s3-store','available'); \
         INSERT INTO object_references VALUES('vault','revision','object'); \
         INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at,storage_backend,storage_store_id) VALUES('upload','vault','user','object',8,lower(hex(randomblob(32))),4,'open','later','created','s3','s3-store'); \
         INSERT INTO upload_chunks VALUES('upload',0,X'01020304','chunk-sha'); \
         INSERT INTO object_delete_queue(queue_id,storage_backend,storage_key,storage_store_id,expected_size,expected_sha256,next_attempt_at,created_at) VALUES('delete','s3','orphan-key','s3-store',8,lower(hex(randomblob(32))),0,'created');",
    )
    .execute(&pool)
    .await
    .expect("create the v34 schema and seed durable data");

    sqlx::raw_sql(include_str!(
        "../migrations/0035_user_object_filesystem_storage.sql"
    ))
    .execute(&pool)
    .await
    .expect("widen v34 backend constraints without dropping rows");

    let object: (String, String, Option<String>) = sqlx::query_as(
        "SELECT storage_backend,storage_key,storage_store_id FROM blob_objects WHERE vault_id='vault' AND object_id='object'",
    )
    .fetch_one(&pool)
    .await
    .expect("read preserved S3 blob metadata");
    assert_eq!(
        object,
        (
            "s3".to_owned(),
            "key".to_owned(),
            Some("s3-store".to_owned())
        )
    );
    let reference_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM object_references WHERE revision_id='revision'")
            .fetch_one(&pool)
            .await
            .expect("read preserved object reference");
    assert_eq!(reference_count, 1);
    let chunk: Vec<u8> =
        sqlx::query_scalar("SELECT bytes FROM upload_chunks WHERE upload_id='upload'")
            .fetch_one(&pool)
            .await
            .expect("read preserved upload chunk");
    assert_eq!(chunk, [1, 2, 3, 4]);
    let queue_backend: String = sqlx::query_scalar(
        "SELECT storage_backend FROM object_delete_queue WHERE queue_id='delete'",
    )
    .fetch_one(&pool)
    .await
    .expect("read preserved deletion intent");
    assert_eq!(queue_backend, "s3");

    sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,storage_backend,storage_key,storage_store_id) VALUES('vault','file-object',X'',8,lower(hex(randomblob(32))),'created','filesystem','key-fs','fs-store')")
        .execute(&pool)
        .await
        .expect("accept filesystem object rows");
    sqlx::query("INSERT INTO object_delete_queue(queue_id,storage_backend,storage_key,storage_store_id,expected_size,expected_sha256,next_attempt_at,created_at) VALUES('file-delete','filesystem','key-fs','fs-store',8,lower(hex(randomblob(32))),0,'created')")
        .execute(&pool)
        .await
        .expect("accept filesystem deletion intents");
    assert!(
        sqlx::query(
            "UPDATE blob_objects SET storage_backend='other' WHERE object_id='file-object'"
        )
        .execute(&pool)
        .await
        .is_err()
    );
    assert!(
        sqlx::query("UPDATE uploads SET storage_backend='other' WHERE upload_id='upload'")
            .execute(&pool)
            .await
            .is_err()
    );
    assert!(
        sqlx::query(
            "UPDATE object_delete_queue SET storage_backend='sqlite' WHERE queue_id='file-delete'"
        )
        .execute(&pool)
        .await
        .is_err()
    );
    let foreign_key_errors: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM pragma_foreign_key_check")
            .fetch_one(&pool)
            .await
            .expect("check migrated foreign keys");
    assert_eq!(foreign_key_errors, 0);
    pool.close().await;
}
