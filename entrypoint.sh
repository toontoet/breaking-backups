#!/usr/bin/env bash
set -euo pipefail

LOG_TS() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(LOG_TS)] $*" >&2; }
fail() { echo "[$(LOG_TS)] ERROR: $*" >&2; exit 1; }

# Defaults
: "${DB_TYPE:=}"
: "${BACKUP_DIR:=/backup}"
: "${BACKUP_WORK_DIR:=${BACKUP_DIR}/work}"
: "${BACKUP_INTERVAL_SECONDS:=0}"   # 0 = run once and exit
: "${CRON_SCHEDULE:=}"              # e.g. "0 2 * * *"
: "${TZ:=UTC}"                      # timezone for cron and logs
: "${RESTIC_TAGS:=db,encrypted}"
: "${RESTIC_PASSWORD:=}"
: "${RESTIC_PASSWORD_FILE:=}"
: "${RESTIC_REPOSITORY:=}"
: "${KEEP_DAILIES:=7}"
: "${KEEP_WEEKLIES:=4}"
: "${KEEP_MONTHLIES:=12}"
: "${KEEP_YEARLIES:=3}"
: "${PRUNE_ON_SUCCESS:=true}"

# Webhook configuration
: "${WEBHOOK_URL:=}"
: "${WEBHOOK_METHOD:=POST}"
: "${WEBHOOK_AUTH_HEADER:=}"
: "${WEBHOOK_EXTRA_HEADERS:=}"
: "${WEBHOOK_TIMEOUT_SECONDS:=10}"

# Ensure writable HOME and restic cache
# Force HOME to a writable location to satisfy restic cache on all platforms
HOME="${BACKUP_DIR}"
RESTIC_CACHE_DIR="${BACKUP_DIR}/.cache"
XDG_CACHE_HOME="${RESTIC_CACHE_DIR}"
TMPDIR="${BACKUP_DIR}/.tmp"
export HOME RESTIC_CACHE_DIR XDG_CACHE_HOME TMPDIR
mkdir -p "${HOME}" "${RESTIC_CACHE_DIR}" "${TMPDIR}" >/dev/null 2>&1 || true

# Configure timezone inside container if available (Alpine uses /etc/timezone and /etc/localtime)
if [[ -n "${TZ}" ]]; then
  # Always export TZ so crond and child processes inherit it
  export TZ
  # Best-effort system timezone update only if writable
  if [[ -w "/etc/timezone" ]]; then
    echo "${TZ}" > /etc/timezone 2>/dev/null || true
  fi
  if [[ -f "/usr/share/zoneinfo/${TZ}" && -w "/etc/localtime" ]]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
  fi
fi


# Globals used to pass context between functions (avoid subshell issues)
: "${BACKUP_DATA_PATH:=}"
: "${BACKUP_HOST_HINT:=}"
: "${BACKUP_DBTYPE:=}"
: "${DUMP_PATH:=}"

cleanup_workdir() {
  local dir="$1"
  if [[ -n "$dir" && -d "$dir" ]]; then
    rm -rf "$dir" || true
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "Required environment variable is missing: $name"
  fi
}

check_restic_env() {
  require_env RESTIC_REPOSITORY
  if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    fail "RESTIC_PASSWORD or RESTIC_PASSWORD_FILE is required for client-side encryption"
  fi
}

restic_repo_init_if_needed() {
  if ! restic snapshots >/dev/null 2>&1; then
    log "Restic repository not initialized; running: restic init"
    restic init
  else
    log "Restic repository is available"
  fi
}

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

backup_postgres() {
  local workdir="${BACKUP_WORK_DIR}/postgres"
  mkdir -p "$workdir"

  # Connection via standard libpq env vars: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE (optional)
  : "${PGHOST:=postgres}"
  : "${PGPORT:=5432}"
  : "${PGUSER:=postgres}"
  : "${PGDATABASE:=postgres}"

  log "Starting Postgres dump (${PGHOST}:${PGPORT}, database=${PGDATABASE})"
  if [[ "${PG_DUMP_ALL:-false}" == "true" ]]; then
    pg_dumpall -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --no-owner --clean --no-comments >"${workdir}/postgres.sql"
  else
    pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" --no-owner --clean --no-comments >"${workdir}/postgres.sql"
  fi

  BACKUP_DATA_PATH="${workdir}/postgres.sql"
  BACKUP_HOST_HINT="${PGHOST}"
  BACKUP_DBTYPE="postgres"
  DUMP_PATH="$workdir"
}

backup_mysql() {
  local workdir="${BACKUP_WORK_DIR}/mysql"
  mkdir -p "$workdir"

  : "${MYSQL_HOST:=mysql}"
  : "${MYSQL_PORT:=3306}"
  : "${MYSQL_USER:=root}"
  : "${MYSQL_PASSWORD:=}"

  export MYSQL_PWD="$MYSQL_PASSWORD"

  log "Starting MySQL/MariaDB dump (${MYSQL_HOST}:${MYSQL_PORT})"
  if [[ -n "${MYSQL_DATABASE:-}" ]]; then
    mysqldump -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" --single-transaction --routines --events --skip-comments --skip-dump-date "$MYSQL_DATABASE" >"${workdir}/mysql.sql"
  else
    mysqldump -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" --single-transaction --routines --events --skip-comments --skip-dump-date --all-databases >"${workdir}/mysql.sql"
  fi

  BACKUP_DATA_PATH="${workdir}/mysql.sql"
  BACKUP_HOST_HINT="${MYSQL_HOST}"
  BACKUP_DBTYPE="mysql"
  DUMP_PATH="$workdir"
}

redact_uri() {
  # mask credentials in URIs like scheme://user:pass@host
  sed -E 's#(://)[^/@]*@#\1***:***@#g' <<<"$1"
}

backup_mongo() {
  local workdir="${BACKUP_WORK_DIR}/mongo"
  mkdir -p "$workdir"

  # Prefer URI if given, else build from parts
  local uri="${MONGO_URI:-${MONGODB_URI:-}}"
  if [[ -z "$uri" ]]; then
    : "${MONGO_HOST:=mongo}"
    : "${MONGO_PORT:=27017}"
    if [[ -n "${MONGO_USER:-}" && -n "${MONGO_PASSWORD:-}" ]]; then
      if [[ -n "${MONGO_AUTH_DB:-}" ]]; then
        uri="mongodb://${MONGO_USER}:${MONGO_PASSWORD}@${MONGO_HOST}:${MONGO_PORT}/?authSource=${MONGO_AUTH_DB}"
      else
        uri="mongodb://${MONGO_USER}:${MONGO_PASSWORD}@${MONGO_HOST}:${MONGO_PORT}/"
      fi
    else
      uri="mongodb://${MONGO_HOST}:${MONGO_PORT}/"
    fi
  fi

  local safe_uri
  safe_uri="$(redact_uri "$uri")"
  log "Starting MongoDB dump (${safe_uri})"
  # Ensure no stdout from mongodump contaminates the returned workdir path
  mongodump --uri "$uri" --out "${workdir}/dump" 1>&2

  # For MongoDB, create a single compressed archive to improve incremental backups
  # Many small BSON files with metadata cause false "changes" due to internal timestamps
  log "Creating zstd compressed archive of MongoDB dump for better incremental backups"
  cd "$workdir" || exit 1
  
  # Create a deterministic tar archive using BusyBox tar
  # First, create file list in sorted order for consistency
  find dump -type f | sort > file_list.txt
  
  # Create tar with zstd compression (much faster and better compression than gzip)
  tar -c --numeric-owner -T file_list.txt | zstd -3 > mongodump.tar.zst
  
  # Clean up
  rm -f file_list.txt
  rm -rf dump

  # Build host hint without credentials
  local no_proto="${uri#*://}"
  local host_part
  if [[ "$no_proto" == *"@"* ]]; then
    host_part="${no_proto#*@}"
  else
    host_part="$no_proto"
  fi
  BACKUP_DATA_PATH="${workdir}/mongodump.tar.zst"
  BACKUP_HOST_HINT="mongodb://${host_part}"
  BACKUP_DBTYPE="mongodb"
  DUMP_PATH="$workdir"
}

run_restic_backup() {
  local path="$1"
  local host="${BACKUP_HOST_HINT:-unknown}"
  local dbtype="${BACKUP_DBTYPE:-db}"

  IFS=',' read -r -a tag_array <<<"${RESTIC_TAGS}"
  tag_array+=("type=${dbtype}")
  tag_array+=("host=${host}")

  local tag_args=()
  for t in "${tag_array[@]}"; do
    tag_args+=("--tag" "$t")
  done

  log "Starting restic backup for ${path} (tags: ${tag_array[*]})"
  # Capture JSON stream to analyze summary for bytes uploaded and snapshot id
  local backup_log_json="${BACKUP_WORK_DIR}/restic-backup.json"
  : >"$backup_log_json"
  if ! restic --cache-dir "${RESTIC_CACHE_DIR}" backup --json "${tag_args[@]}" "$BACKUP_DATA_PATH" | tee "$backup_log_json" >/dev/null; then
    log "restic backup is mislukt"
    return 1
  fi

  # Parse summary from JSON stream (if present)
  local summary_json
  summary_json=$(jq -c 'select(.message_type=="summary")' "$backup_log_json" | tail -n1 || true)
  if [[ -n "$summary_json" ]]; then
    RESTIC_SNAPSHOT_ID=$(echo "$summary_json" | jq -r '.snapshot_id // empty')
    RESTIC_DATA_ADDED=$(echo "$summary_json" | jq -r '.data_added // 0')
    RESTIC_TOTAL_BYTES_PROCESSED=$(echo "$summary_json" | jq -r '.total_bytes_processed // 0')
    RESTIC_TOTAL_DURATION=$(echo "$summary_json" | jq -r '.total_duration // 0')
    RESTIC_FILES_NEW=$(echo "$summary_json" | jq -r '.files_new // 0')
    RESTIC_FILES_CHANGED=$(echo "$summary_json" | jq -r '.files_changed // 0')
    RESTIC_FILES_UNMODIFIED=$(echo "$summary_json" | jq -r '.files_unmodified // 0')
    log "Restic summary: snapshot=${RESTIC_SNAPSHOT_ID} data_added=${RESTIC_DATA_ADDED}B duration=${RESTIC_TOTAL_DURATION}s"
  else
    RESTIC_SNAPSHOT_ID=""
    RESTIC_DATA_ADDED=""
    RESTIC_TOTAL_BYTES_PROCESSED=""
    RESTIC_TOTAL_DURATION=""
    RESTIC_FILES_NEW=""
    RESTIC_FILES_CHANGED=""
    RESTIC_FILES_UNMODIFIED=""
    log "No restic summary found in JSON output"
  fi

  log "Applying retention: daily=${KEEP_DAILIES} weekly=${KEEP_WEEKLIES} monthly=${KEEP_MONTHLIES} yearly=${KEEP_YEARLIES}"
  restic forget --keep-daily "$KEEP_DAILIES" --keep-weekly "$KEEP_WEEKLIES" --keep-monthly "$KEEP_MONTHLIES" --keep-yearly "$KEEP_YEARLIES" ${PRUNE_ON_SUCCESS:+--prune}
}

build_db_host_hint() {
  case "${DB_TYPE,,}" in
    postgres|postgresql|pg) echo "${PGHOST:-postgres}" ;;
    mysql|mariadb) echo "${MYSQL_HOST:-mysql}" ;;
    mongo|mongodb) echo "${MONGO_HOST:-mongo}" ;;
    *) echo "unknown" ;;
  esac
}

notify_webhook() {
  # Arguments: status message started_at finished_at duration_seconds snapshot_id
  local status="$1"; shift || true
  local message="$1"; shift || true
  local started_at="$1"; shift || true
  local finished_at="$1"; shift || true
  local duration_seconds="$1"; shift || true
  local snapshot_id="$1"; shift || true

  if [[ -z "${WEBHOOK_URL}" ]]; then
    return
  fi

  local dbtype="${DB_TYPE}"
  local host_hint
  host_hint="$(build_db_host_hint)"

  # Build JSON payload
  local payload
  payload=$(jq -n \
    --arg status "$status" \
    --arg message "$message" \
    --arg startedAt "$started_at" \
    --arg finishedAt "$finished_at" \
    --arg durationSeconds "$duration_seconds" \
    --arg snapshotId "$snapshot_id" \
    --arg repository "${RESTIC_REPOSITORY}" \
    --arg dbType "$dbtype" \
    --arg host "$host_hint" \
    --arg tags "${RESTIC_TAGS}" \
    --arg dataAddedBytes "${RESTIC_DATA_ADDED:-0}" \
    --arg totalBytesProcessed "${RESTIC_TOTAL_BYTES_PROCESSED:-0}" \
    --arg totalDurationSeconds "${RESTIC_TOTAL_DURATION:-0}" \
    --arg filesNew "${RESTIC_FILES_NEW:-0}" \
    --arg filesChanged "${RESTIC_FILES_CHANGED:-0}" \
    --arg filesUnmodified "${RESTIC_FILES_UNMODIFIED:-0}" \
    '{
      status: $status,
      message: $message,
      startedAt: $startedAt,
      finishedAt: $finishedAt,
      durationSeconds: ($durationSeconds|tonumber),
      repository: $repository,
      dbType: $dbType,
      host: $host,
      tags: ($tags | split(",")),
      snapshotId: ($snapshotId // null),
      dataAddedBytes: ($dataAddedBytes|tonumber),
      totalBytesProcessed: ($totalBytesProcessed|tonumber),
      totalDurationSeconds: ($totalDurationSeconds|tonumber),
      filesNew: ($filesNew|tonumber),
      filesChanged: ($filesChanged|tonumber),
      filesUnmodified: ($filesUnmodified|tonumber)
    }')

  local -a curl_args=( -sS -m "${WEBHOOK_TIMEOUT_SECONDS}" -H "Content-Type: application/json" -X "${WEBHOOK_METHOD}" -d "$payload" )
  if [[ -n "${WEBHOOK_AUTH_HEADER}" ]]; then
    curl_args+=( -H "${WEBHOOK_AUTH_HEADER}" )
  fi
  if [[ -n "${WEBHOOK_EXTRA_HEADERS}" ]]; then
    # Comma-separated KEY=VALUE pairs -> "KEY: VALUE" headers
    IFS=',' read -r -a hdrs <<<"${WEBHOOK_EXTRA_HEADERS}"
    for kv in "${hdrs[@]}"; do
      if [[ "$kv" == *"="* ]]; then
        curl_args+=( -H "${kv%%=*}: ${kv#*=}" )
      fi
    done
  fi

  curl "${curl_args[@]}" "${WEBHOOK_URL}" || log "Webhook send failed"
}

perform_backup_and_notify_once() {
  local started_at finished_at started_epoch finished_epoch duration status msg snapshot_id rc
  started_at="$(LOG_TS)"; started_epoch=$(date -u +%s)

  # Reset metrics from any previous run
  RESTIC_SNAPSHOT_ID=""; RESTIC_DATA_ADDED=""; RESTIC_TOTAL_BYTES_PROCESSED=""; RESTIC_TOTAL_DURATION=""; RESTIC_FILES_NEW=""; RESTIC_FILES_CHANGED=""; RESTIC_FILES_UNMODIFIED=""

  # Keep -e enabled; use if to capture failure without exiting the script
  if run_backup_once; then
    rc=0
  else
    rc=$?
  fi

  finished_at="$(LOG_TS)"; finished_epoch=$(date -u +%s)
  duration=$(( finished_epoch - started_epoch ))
  if [[ $rc -eq 0 ]]; then
    status="success"
    msg="Backup succeeded"
    # Prefer snapshot id from backup summary, fallback to last snapshot query
    if [[ -n "${RESTIC_SNAPSHOT_ID:-}" ]]; then
      snapshot_id="${RESTIC_SNAPSHOT_ID}"
    else
      snapshot_id=$(restic snapshots --last --json 2>/dev/null | jq -r '.[0].short_id // .[0].id // empty')
    fi
  else
    status="failed"
    msg="Backup failed (exitcode=${rc})"
    snapshot_id=""
  fi

  notify_webhook "$status" "$msg" "$started_at" "$finished_at" "$duration" "$snapshot_id"

  return $rc
}

run_backup_once() {
  check_restic_env
  restic_repo_init_if_needed

  mkdir -p "$BACKUP_WORK_DIR"

  # Reset globals
  BACKUP_DATA_PATH=""; BACKUP_HOST_HINT=""; BACKUP_DBTYPE=""; DUMP_PATH=""
  local dump_path=""
  case "${DB_TYPE,,}" in
    postgres|postgresql|pg)
      backup_postgres; dump_path="$DUMP_PATH" ;;
    mysql|mariadb)
      backup_mysql; dump_path="$DUMP_PATH" ;;
    mongo|mongodb)
      backup_mongo; dump_path="$DUMP_PATH" ;;
    *)
      fail "Unknown or missing DB_TYPE. Supported: postgres, mysql/mariadb, mongo"
      ;;
  esac

  if [[ -z "$dump_path" || -z "$BACKUP_DATA_PATH" || ! -e "$BACKUP_DATA_PATH" ]]; then
    log "Dump or BACKUP_DATA_PATH missing or unreadable: '$BACKUP_DATA_PATH'"
    cleanup_workdir "$dump_path"
    return 1
  fi

  local rc=0
  if run_restic_backup "$dump_path"; then
    rc=0
  else
    rc=$?
  fi
  cleanup_workdir "$dump_path"
  return $rc
}

start_loop() {
  # If cron schedule is provided, configure and start crond in foreground
  if [[ -n "${CRON_SCHEDULE}" ]]; then
    log "Using CRON_SCHEDULE='${CRON_SCHEDULE}'"
    local spool_dir="/etc/crontabs"
    local backups_uid backups_gid
    backups_uid=1000; backups_gid=1000
    
    # Ensure proper cron directories exist
    mkdir -p "${spool_dir}" "${BACKUP_WORK_DIR}" "${RESTIC_CACHE_DIR}" || true
    chown root:root "${spool_dir}" || true
    chmod 755 "${spool_dir}" || true
    
    # Create root crontab that drops privileges to backups user
    {
      printf "%s %s\n" "${CRON_SCHEDULE}" "/usr/local/bin/entrypoint.sh run-once-as-backups 2>&1 | tee -a /backup/cron.log /proc/1/fd/1"
    } > "${spool_dir}/root"
    chown root:root "${spool_dir}/root" || true
    chmod 644 "${spool_dir}/root" || true
    
    # Ensure backups can write logs/workspace/cache
    chown -R ${backups_uid}:${backups_gid} "${BACKUP_WORK_DIR}" "${RESTIC_CACHE_DIR}" || true
    touch "${BACKUP_DIR}/cron.log" && chown ${backups_uid}:${backups_gid} "${BACKUP_DIR}/cron.log" || true
    
    log "Installed crontab for root with schedule: ${CRON_SCHEDULE}"
    log "Starting crond"
    
    # Start cron with minimal logging
    crond -f -l 8 &
    local crond_pid=$!
    
    # Wait a moment for crond to start
    sleep 2
    
    # Keep container running and periodically check if crond is still alive
    while kill -0 $crond_pid 2>/dev/null; do
      sleep 60
    done
    
    log "crond died, exiting"
    exit 1
  fi

  if [[ "${BACKUP_INTERVAL_SECONDS}" -le 0 ]]; then
    log "BACKUP_INTERVAL_SECONDS=0 -> one-time backup"
    perform_backup_and_notify_once
    return
  fi

  while true; do
    perform_backup_and_notify_once || log "Backup failed (see webhook/logs). Next attempt in ${BACKUP_INTERVAL_SECONDS}s"
    log "Waiting ${BACKUP_INTERVAL_SECONDS}s until next run"
    sleep "$BACKUP_INTERVAL_SECONDS"
  done
}

cmd="${1:-start}"
case "$cmd" in
  start)
    start_loop ;;
  run-once)
    perform_backup_and_notify_once ;;
  run-once-as-backups)
    # Drop privileges to backups user and run backup
    if [[ "$(id -u)" -eq 0 ]]; then
      # Ensure proper ownership before dropping privileges
      chown -R 1000:1000 "${BACKUP_WORK_DIR}" "${RESTIC_CACHE_DIR}" "${BACKUP_DIR}/cron.log" 2>/dev/null || true
      # Use su to switch user (more compatible than su-exec in cron context)
      exec su -s /bin/sh backups -c '/usr/local/bin/entrypoint.sh run-once'
    else
      # Already running as non-root user
      perform_backup_and_notify_once
    fi ;;
  forget-prune)
    check_restic_env
    log "Manual retention: forget --prune"
    restic forget --keep-daily "$KEEP_DAILIES" --keep-weekly "$KEEP_WEEKLIES" --keep-monthly "$KEEP_MONTHLIES" --keep-yearly "$KEEP_YEARLIES" --prune ;;
  init)
    check_restic_env
    restic init ;;
  *)
    exec "$@" ;;
esac


