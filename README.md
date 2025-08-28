# breaking-backups

Sidecar image for encrypted, incremental database backups with restic to S3. Supports Postgres, MySQL/MariaDB, and MongoDB. Retention policy with daily, weekly, monthly, and yearly archives.

### Key features
- Incremental, client-side encryption with restic
- Supports Postgres, MySQL/MariaDB, MongoDB
- S3-compatible storage (AWS S3, MinIO, Wasabi, etc.)
- Retention: daily / weekly / monthly / yearly
- zstd compression for faster and more efficient MongoDB backups
- Simple sidecar design

## How it works
1. The sidecar produces a database dump into a temporary workspace under `/backup/work`.
2. For MongoDB: Creates a deterministic zstd-compressed archive for optimal incremental backups.
3. `restic backup` uploads incrementally to the configured S3 repository.
4. `restic forget` enforces the retention policy; with `--prune` it reclaims space.
5. On the first run, the script checks if the restic repository is initialized. If not, it automatically runs `restic init` before the first backup.

### Compression
- **MongoDB**: Uses zstd compression (level 3) for superior speed and compression ratio compared to gzip
- **PostgreSQL/MySQL**: Raw SQL dumps are handled directly by restic's built-in compression

## Environment variables (general)
- `DB_TYPE` (required): `postgres` | `mysql` | `mariadb` | `mongo`
- `RESTIC_REPOSITORY` (required): e.g. `s3:s3.amazonaws.com/<bucket>/<path>` or `s3:http://minio:9000/bucket/path`
- `RESTIC_PASSWORD` or `RESTIC_PASSWORD_FILE` (required): restic repository password
- `RESTIC_TAGS` (optional): comma-separated tags, e.g. `app,env=prod`
- `BACKUP_INTERVAL_SECONDS` (optional): `0` = run once and exit; otherwise an interval in seconds (e.g. `86400` = 1 day)
- `KEEP_DAILIES`, `KEEP_WEEKLIES`, `KEEP_MONTHLIES`, `KEEP_YEARLIES` (optional): retention policy values
- AWS credentials for S3: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`

### Webhook (optional)
- `WEBHOOK_URL`: if set, send a JSON POST after each run (success or failure)
- `WEBHOOK_METHOD`: HTTP method, default `POST`
- `WEBHOOK_AUTH_HEADER`: optional header value for auth, e.g. `Authorization: Bearer <token>`
- `WEBHOOK_EXTRA_HEADERS`: comma-separated `Key=Value` pairs to include as headers
- `WEBHOOK_TIMEOUT_SECONDS`: request timeout in seconds (default `10`)

## Postgres variables
- `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`
- `PG_DUMP_ALL` (optional, `true|false`): dump all databases using `pg_dumpall`

## MySQL/MariaDB variables
- `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE` (optional; empty = all databases)

## MongoDB variables
- Prefer `MONGO_URI`/`MONGODB_URI`, or provide separately: `MONGO_HOST`, `MONGO_PORT`, `MONGO_USER`, `MONGO_PASSWORD`, `MONGO_AUTH_DB`

## Commands inside the container
- Default command: `start` (loops according to `BACKUP_INTERVAL_SECONDS`)
- `run-once`: perform a single backup immediately and exit
- `forget-prune`: apply retention and prune
- `init`: manually initialize a new restic repository (not required; the script auto-inits on first run if needed)

### Scheduling
You can schedule backups via either an interval or cron:
- `CRON_SCHEDULE` (preferred): a standard cron expression (e.g., `0 2 * * *` for daily at 02:00). When set, the container runs `crond` in the foreground and executes `entrypoint.sh run-once` at the specified times. Logs are written to `/backup/cron.log`.
- `BACKUP_INTERVAL_SECONDS`: fallback interval-based scheduler. If `CRON_SCHEDULE` is set, the interval is ignored.
- `TZ` (optional, default `UTC`): timezone for cron evaluation and logs. Example `Europe/Amsterdam`.

### Webhook payload example
The container sends a JSON payload like this after each run:
```
{
  "status": "success|failed",
  "message": "Backup geslaagd / Backup mislukt (exitcode=..)",
  "startedAt": "2025-08-21T12:00:00Z",
  "finishedAt": "2025-08-21T12:03:12Z",
  "durationSeconds": 192,
  "repository": "s3:s3.amazonaws.com/bucket/path",
  "dbType": "postgres|mysql|mariadb|mongo",
  "host": "db-host-hint",
  "tags": ["app", "env=dev"],
  "snapshotId": "abcd1234", // present on success if available
  "dataAddedBytes": 123456,  // bytes uploaded for this backup
  "totalBytesProcessed": 789012, // bytes scanned
  "totalDurationSeconds": 190, // restic-reported duration
  "filesNew": 10,
  "filesChanged": 0,
  "filesUnmodified": 0
}
```

## Example docker-compose.yml
See the included `docker-compose.yml` for examples with Postgres, MySQL/MariaDB, and MongoDB using this sidecar. Adjust buckets, credentials, and tags for your environment. To enable cron-based scheduling, set `CRON_SCHEDULE`, for example `0 2 * * *` to run nightly at 02:00.

## Build
  docker build -t breaking-backups:latest .

## Notes & recommendations
- Use `RESTIC_PASSWORD_FILE` mounted from a secret for better security.
- Consider scoping IAM access to a single bucket/prefix.
- Ensure the DB credentials allow consistent dumps (e.g., use `--single-transaction` for MySQL/MariaDB as configured).

## License
MIT
