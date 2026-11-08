-- Bind completed migration targets to the exact S3 namespace. Prefixes are
-- intentionally not part of storage_store_id, so the per-item keys from
-- existing journals are used to recover the prefix when possible.
ALTER TABLE object_store_migration_jobs
    ADD COLUMN target_s3_prefix TEXT
        CHECK(target_backend='s3' OR target_s3_prefix IS NULL);

-- A value that cannot pass S3 prefix validation is used for old S3 jobs whose
-- namespace cannot be proven (empty journal, missing item, mixed prefixes, or
-- malformed key). Startup then fails closed instead of guessing a namespace.
WITH item_prefixes AS (
    SELECT
        i.migration_id,
        CASE
            WHEN i.target_key =
                'atermius/objects/v1/' || instance.instance_id || '/' ||
                i.vault_id || '/' || i.object_id || '/' || i.migration_id
            THEN ''
            WHEN length(i.target_key) > length(
                    'atermius/objects/v1/' || instance.instance_id || '/' ||
                    i.vault_id || '/' || i.object_id || '/' || i.migration_id
                 )
             AND substr(
                    i.target_key,
                    length(i.target_key) - length(
                        'atermius/objects/v1/' || instance.instance_id || '/' ||
                        i.vault_id || '/' || i.object_id || '/' || i.migration_id
                    ),
                    1
                 ) = '/'
             AND substr(
                    i.target_key,
                    length(i.target_key) - length(
                        'atermius/objects/v1/' || instance.instance_id || '/' ||
                        i.vault_id || '/' || i.object_id || '/' || i.migration_id
                    ) + 1
                 ) =
                    'atermius/objects/v1/' || instance.instance_id || '/' ||
                    i.vault_id || '/' || i.object_id || '/' || i.migration_id
            THEN substr(
                    i.target_key,
                    1,
                    length(i.target_key) - length(
                        'atermius/objects/v1/' || instance.instance_id || '/' ||
                        i.vault_id || '/' || i.object_id || '/' || i.migration_id
                    ) - 1
                 )
            ELSE '!legacy-s3-prefix-unknown!'
        END AS prefix
    FROM object_store_migration_items AS i
    JOIN object_store_migration_jobs AS j ON j.migration_id=i.migration_id
    JOIN instance_meta AS instance ON instance.id=1
    WHERE j.target_backend='s3'
), grouped_prefixes AS (
    SELECT
        i.migration_id,
        CASE
            WHEN COUNT(*) = (
                    SELECT j.object_count
                    FROM object_store_migration_jobs AS j
                    WHERE j.migration_id=i.migration_id
                 )
             AND MIN(i.prefix)=MAX(i.prefix)
             AND MIN(i.prefix) <> '!legacy-s3-prefix-unknown!'
            THEN MIN(i.prefix)
            ELSE '!legacy-s3-prefix-unknown!'
        END AS prefix
    FROM item_prefixes AS i
    GROUP BY i.migration_id
)
UPDATE object_store_migration_jobs
SET target_s3_prefix=COALESCE(
        (SELECT prefix FROM grouped_prefixes
         WHERE grouped_prefixes.migration_id=object_store_migration_jobs.migration_id),
        '!legacy-s3-prefix-unknown!'
    )
WHERE target_backend='s3';
