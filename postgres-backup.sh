#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Globals
###############################################################################

SCRIPT_NAME="$(basename "$0")"

ENV_FILE=".env"
ACTION=""
COMMIT=false
RESTORE_TIMESTAMP=""

GLOBALS_FILE=""
DUMP_FILE=""
MANIFEST_FILE=""

###############################################################################
# Logging
###############################################################################

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

ok() {
    printf '[OK] %s\n' "$*"
}

warn() {
    printf '[WARNING] %s\n' "$*" >&2
}

error() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

###############################################################################
# Cleanup
###############################################################################

TEMP_FILES=()

cleanup() {
    local file

    for file in "${TEMP_FILES[@]:-}"; do
        [[ -n "$file" ]] && rm -f "$file"
    done
}

trap cleanup EXIT

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<EOF
Usage:

  $SCRIPT_NAME --backup [options]
  $SCRIPT_NAME --restore [options]

Actions:

  --backup
      Create PostgreSQL backup.

  --restore
      Restore PostgreSQL backup.

      Restore is DRY-RUN by default.
      Use --commit to execute the restore.

Options:

  --commit
      Execute restore.

  --timestamp TIMESTAMP
      Restore specific backup.

      Format:
        YYYYMMDDTHHMM

      Example:
        20260915T2028

  --env-file FILE
      Environment file.

      Default:
        .env

  --help
      Show help.

Examples:

  $SCRIPT_NAME --backup

  $SCRIPT_NAME --restore

  $SCRIPT_NAME \
      --restore \
      --timestamp 20260915T2028

  $SCRIPT_NAME \
      --restore \
      --timestamp 20260915T2028 \
      --commit
EOF
}

###############################################################################
# Helpers
###############################################################################

require_command() {
    command -v "$1" >/dev/null 2>&1 || \
        error "Required command not found: $1"
}

require_var() {
    local var_name="$1"

    if [[ -z "${!var_name:-}" ]]; then
        error "Required variable is missing: $var_name"
    fi
}

sql_escape_literal() {
    local value="$1"

    value="${value//\'/\'\'}"

    printf '%s' "$value"
}

validate_table_name() {
    local table="$1"

    if [[ ! "$table" =~ ^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        error "Invalid validation table name: $table"
    fi
}

###############################################################################
# Arguments
###############################################################################

while [[ $# -gt 0 ]]; do

    case "$1" in

        --backup)
            [[ -z "$ACTION" ]] || \
                error "Only one action can be specified"

            ACTION="backup"
            shift
            ;;

        --restore)
            [[ -z "$ACTION" ]] || \
                error "Only one action can be specified"

            ACTION="restore"
            shift
            ;;

        --commit)
            COMMIT=true
            shift
            ;;

        --timestamp)
            [[ $# -ge 2 ]] || \
                error "--timestamp requires a value"

            RESTORE_TIMESTAMP="$2"
            shift 2
            ;;

        --env-file)
            [[ $# -ge 2 ]] || \
                error "--env-file requires a file"

            ENV_FILE="$2"
            shift 2
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            error "Unknown argument: $1"
            ;;
    esac

done

###############################################################################
# Argument validation
###############################################################################

[[ -n "$ACTION" ]] || {
    usage
    exit 1
}

if [[ "$ACTION" != "restore" && "$COMMIT" == true ]]; then
    error "--commit is only valid with --restore"
fi

if [[ "$ACTION" != "restore" && -n "$RESTORE_TIMESTAMP" ]]; then
    error "--timestamp is only valid with --restore"
fi

if [[ -n "$RESTORE_TIMESTAMP" ]] && \
   [[ ! "$RESTORE_TIMESTAMP" =~ ^[0-9]{8}T[0-9]{4}$ ]]
then
    error "Invalid timestamp format: $RESTORE_TIMESTAMP"
fi

###############################################################################
# Load .env
###############################################################################

[[ -f "$ENV_FILE" ]] || \
    error "Environment file not found: $ENV_FILE"

set -a

# shellcheck disable=SC1090
source "$ENV_FILE"

set +a

###############################################################################
# Defaults
###############################################################################

BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_PREFIX="${BACKUP_PREFIX:-ccs}"

BACKUP_PORT="${BACKUP_PORT:-5432}"

RESTORE_PORT="${RESTORE_PORT:-5432}"

RESTORE_DATABASE="${RESTORE_DATABASE:-ccs_app}"

RESTORE_OWNER="${RESTORE_OWNER:-ccs_app}"

VALIDATION_TABLES="${VALIDATION_TABLES:-public.ccs_authority}"

VALIDATION_REQUIRE_RLS="${VALIDATION_REQUIRE_RLS:-true}"

VALIDATION_REQUIRE_POLICIES="${VALIDATION_REQUIRE_POLICIES:-true}"

BACKUP_ROLE_PASSWORDS="${BACKUP_ROLE_PASSWORDS:-false}"

###############################################################################
# Required commands
###############################################################################

require_command psql
require_command pg_dump
require_command pg_dumpall
require_command pg_restore
require_command createdb
require_command sha256sum
require_command awk
require_command grep
require_command sort
require_command tail
require_command mktemp

###############################################################################
# PostgreSQL helpers
###############################################################################

backup_psql() {
    PGPASSWORD="$BACKUP_ADMIN_PASSWORD" \
        psql \
        -X \
        --host="$BACKUP_HOST" \
        --port="$BACKUP_PORT" \
        --username="$BACKUP_ADMIN_USER" \
        --set=ON_ERROR_STOP=on \
        "$@"
}

restore_psql() {
    PGPASSWORD="$RESTORE_ADMIN_PASSWORD" \
        psql \
        -X \
        --host="$RESTORE_HOST" \
        --port="$RESTORE_PORT" \
        --username="$RESTORE_ADMIN_USER" \
        --set=ON_ERROR_STOP=on \
        "$@"
}

###############################################################################
# Manifest helpers
###############################################################################

manifest_get() {
    local key="$1"

    awk \
        -F= \
        -v key="$key" \
        '
        $1 == key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
        ' \
        "$MANIFEST_FILE"
}

###############################################################################
# Create manifest
###############################################################################

create_manifest() {

    local timestamp="$1"
    local globals_file="$2"
    local dump_file="$3"
    local manifest_file="$4"

    log "Creating backup manifest"

    local database_owner
    local postgres_version

    local table_count
    local rls_enabled_count
    local rls_forced_count
    local policy_count

    local globals_sha256
    local dump_sha256

    local escaped_database

    escaped_database="$(sql_escape_literal "$BACKUP_DATABASE")"

    ###########################################################################
    # Database owner
    ###########################################################################

    database_owner="$(
        backup_psql \
            --dbname="$BACKUP_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT pg_catalog.pg_get_userbyid(datdba)
                FROM pg_catalog.pg_database
                WHERE datname = '$escaped_database';
            "
    )"

    database_owner="$(echo "$database_owner" | xargs)"

    ###########################################################################
    # PostgreSQL version
    ###########################################################################

    postgres_version="$(
        backup_psql \
            --dbname="$BACKUP_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SHOW server_version;
            "
    )"

    postgres_version="$(echo "$postgres_version" | xargs)"

    ###########################################################################
    # Table count
    ###########################################################################

    table_count="$(
        backup_psql \
            --dbname="$BACKUP_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM information_schema.tables
                WHERE table_schema NOT IN (
                    'pg_catalog',
                    'information_schema'
                )
                AND table_type = 'BASE TABLE';
            "
    )"

    table_count="$(echo "$table_count" | tr -d '[:space:]')"

    ###########################################################################
    # RLS enabled
    ###########################################################################

    rls_enabled_count="$(
        backup_psql \
            --dbname="$BACKUP_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n
                  ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p')
                  AND n.nspname NOT IN (
                      'pg_catalog',
                      'information_schema'
                  )
                  AND c.relrowsecurity = true;
            "
    )"

    rls_enabled_count="$(echo "$rls_enabled_count" | tr -d '[:space:]')"

    ###########################################################################
    # RLS forced
    ###########################################################################

    rls_forced_count="$(
        backup_psql \
            --dbname="$BACKUP_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n
                  ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p')
                  AND n.nspname NOT IN (
                      'pg_catalog',
                      'information_schema'
                  )
                  AND c.relforcerowsecurity = true;
            "
    )"

    rls_forced_count="$(echo "$rls_forced_count" | tr -d '[:space:]')"

    ###########################################################################
    # RLS policies
    ###########################################################################

    policy_count="$(
        backup_psql \
            --dbname="$BACKUP_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_policies;
            "
    )"

    policy_count="$(echo "$policy_count" | tr -d '[:space:]')"

    ###########################################################################
    # Checksums
    ###########################################################################

    globals_sha256="$(
        sha256sum "$globals_file" |
        awk '{print $1}'
    )"

    dump_sha256="$(
        sha256sum "$dump_file" |
        awk '{print $1}'
    )"

    ###########################################################################
    # Base manifest
    ###########################################################################

    {
        echo "manifest_version=1"
        echo "timestamp=$timestamp"
        echo "database=$BACKUP_DATABASE"
        echo "database_owner=$database_owner"
        echo "postgres_version=$postgres_version"
        echo "table_count=$table_count"
        echo "rls_enabled_table_count=$rls_enabled_count"
        echo "rls_forced_table_count=$rls_forced_count"
        echo "rls_policy_count=$policy_count"
        echo "globals_sha256=$globals_sha256"
        echo "dump_sha256=$dump_sha256"
    } > "$manifest_file"

    ###########################################################################
    # Validation tables
    ###########################################################################

    local table
    local schema
    local table_name

    local escaped_schema
    local escaped_table

    local table_exists
    local row_count

    for table in $VALIDATION_TABLES; do

        validate_table_name "$table"

        schema="${table%%.*}"
        table_name="${table#*.}"

        escaped_schema="$(sql_escape_literal "$schema")"
        escaped_table="$(sql_escape_literal "$table_name")"

        table_exists="$(
            backup_psql \
                --dbname="$BACKUP_DATABASE" \
                --tuples-only \
                --no-align \
                --command="
                    SELECT count(*)
                    FROM information_schema.tables
                    WHERE table_schema = '$escaped_schema'
                      AND table_name = '$escaped_table'
                      AND table_type = 'BASE TABLE';
                "
        )"

        table_exists="$(echo "$table_exists" | tr -d '[:space:]')"

        if [[ "$table_exists" != "1" ]]; then

            warn "Validation table does not exist and will be skipped: $table"

            echo "table.${table}.status=missing" >> "$manifest_file"

            continue
        fi

        row_count="$(
            backup_psql \
                --dbname="$BACKUP_DATABASE" \
                --tuples-only \
                --no-align \
                --command="
                    SELECT count(*)
                    FROM \"$schema\".\"$table_name\";
                "
        )"

        row_count="$(echo "$row_count" | tr -d '[:space:]')"

        echo "table.${table}.status=present" >> "$manifest_file"
        echo "table.${table}.rows=${row_count}" >> "$manifest_file"

    done

    ok "Manifest created: $manifest_file"
    ok "Tables: $table_count"
    ok "RLS enabled tables: $rls_enabled_count"
    ok "RLS forced tables: $rls_forced_count"
    ok "RLS policies: $policy_count"
}

###############################################################################
# Backup
###############################################################################

do_backup() {

    require_var BACKUP_HOST
    require_var BACKUP_ADMIN_USER
    require_var BACKUP_ADMIN_PASSWORD
    require_var BACKUP_DATABASE

    mkdir -p "$BACKUP_DIR"

    umask 077

    local timestamp
    local globals_file
    local dump_file
    local manifest_file

    timestamp="$(date '+%Y%m%dT%H%M')"

    globals_file="${BACKUP_DIR}/${BACKUP_PREFIX}_globals_${timestamp}.sql"
    dump_file="${BACKUP_DIR}/${BACKUP_PREFIX}_pg_${timestamp}.dump"
    manifest_file="${BACKUP_DIR}/${BACKUP_PREFIX}_manifest_${timestamp}.txt"

    log "Starting PostgreSQL backup"
    log "Timestamp: $timestamp"

    ###########################################################################
    # 1. Globals
    ###########################################################################

    log "Backing up PostgreSQL roles / grants / globals"

    if [[ "$BACKUP_ROLE_PASSWORDS" == "true" ]]; then

        PGPASSWORD="$BACKUP_ADMIN_PASSWORD" \
            pg_dumpall \
            --host="$BACKUP_HOST" \
            --port="$BACKUP_PORT" \
            --username="$BACKUP_ADMIN_USER" \
            --globals-only \
            --file="$globals_file"

    else

        PGPASSWORD="$BACKUP_ADMIN_PASSWORD" \
            pg_dumpall \
            --host="$BACKUP_HOST" \
            --port="$BACKUP_PORT" \
            --username="$BACKUP_ADMIN_USER" \
            --globals-only \
            --no-role-passwords \
            --file="$globals_file"
    fi

    [[ -s "$globals_file" ]] || \
        error "Globals backup is empty: $globals_file"

    ###########################################################################
    # 2. Database
    ###########################################################################

    log "Backing up PostgreSQL database"

    PGPASSWORD="$BACKUP_ADMIN_PASSWORD" \
        pg_dump \
        --host="$BACKUP_HOST" \
        --port="$BACKUP_PORT" \
        --username="$BACKUP_ADMIN_USER" \
        --dbname="$BACKUP_DATABASE" \
        --format=custom \
        --file="$dump_file"

    [[ -s "$dump_file" ]] || \
        error "Database backup is empty: $dump_file"

    ###########################################################################
    # 3. Verify dump
    ###########################################################################

    log "Verifying database dump"

    pg_restore \
        --list \
        "$dump_file" \
        >/dev/null \
        || error "Database dump verification failed"

    ok "Database dump is readable"

    ###########################################################################
    # 4. Manifest
    ###########################################################################

    create_manifest \
        "$timestamp" \
        "$globals_file" \
        "$dump_file" \
        "$manifest_file"

    echo

    log "Backup completed successfully"

    ok "Globals : $globals_file"
    ok "Database: $dump_file"
    ok "Manifest: $manifest_file"
}

###############################################################################
# Find restore files
###############################################################################

find_restore_files() {

    local timestamp="$RESTORE_TIMESTAMP"

    if [[ -n "$timestamp" ]]; then

        GLOBALS_FILE="${BACKUP_DIR}/${BACKUP_PREFIX}_globals_${timestamp}.sql"
        DUMP_FILE="${BACKUP_DIR}/${BACKUP_PREFIX}_pg_${timestamp}.dump"
        MANIFEST_FILE="${BACKUP_DIR}/${BACKUP_PREFIX}_manifest_${timestamp}.txt"

    else

        shopt -s nullglob

        local dump_files=(
            "$BACKUP_DIR"/"${BACKUP_PREFIX}_pg_"*.dump
        )

        shopt -u nullglob

        if [[ ${#dump_files[@]} -eq 0 ]]; then
            error "No database backups found in: $BACKUP_DIR"
        fi

        DUMP_FILE="$(
            printf '%s\n' "${dump_files[@]}" |
            sort |
            tail -n 1
        )"

        local filename

        filename="$(basename "$DUMP_FILE")"

        timestamp="${filename#${BACKUP_PREFIX}_pg_}"
        timestamp="${timestamp%.dump}"

        GLOBALS_FILE="${BACKUP_DIR}/${BACKUP_PREFIX}_globals_${timestamp}.sql"
        MANIFEST_FILE="${BACKUP_DIR}/${BACKUP_PREFIX}_manifest_${timestamp}.txt"
    fi

    [[ -s "$GLOBALS_FILE" ]] || \
        error "Globals backup missing or empty: $GLOBALS_FILE"

    [[ -s "$DUMP_FILE" ]] || \
        error "Database backup missing or empty: $DUMP_FILE"

    [[ -s "$MANIFEST_FILE" ]] || \
        error "Manifest missing or empty: $MANIFEST_FILE"

    RESTORE_TIMESTAMP="$timestamp"
}

###############################################################################
# Verify checksums
###############################################################################

verify_backup_checksums() {

    log "Verifying backup checksums"

    local expected_globals
    local expected_dump

    local actual_globals
    local actual_dump

    expected_globals="$(manifest_get globals_sha256)"
    expected_dump="$(manifest_get dump_sha256)"

    [[ -n "$expected_globals" ]] || \
        error "Manifest does not contain globals_sha256"

    [[ -n "$expected_dump" ]] || \
        error "Manifest does not contain dump_sha256"

    actual_globals="$(
        sha256sum "$GLOBALS_FILE" |
        awk '{print $1}'
    )"

    actual_dump="$(
        sha256sum "$DUMP_FILE" |
        awk '{print $1}'
    )"

    [[ "$expected_globals" == "$actual_globals" ]] || \
        error "Globals checksum mismatch"

    ok "Globals checksum valid"

    [[ "$expected_dump" == "$actual_dump" ]] || \
        error "Database dump checksum mismatch"

    ok "Database dump checksum valid"
}

###############################################################################
# Restore globals
#
# Existing roles:
#   CREATE ROLE is skipped
#   ALTER ROLE is skipped
#
# Missing roles:
#   CREATE ROLE and ALTER ROLE are restored
###############################################################################

restore_globals() {

    log "Restoring cluster roles / globals"

    local existing_roles_file
    local filtered_globals_file

    existing_roles_file="$(mktemp)"
    filtered_globals_file="$(mktemp)"

    TEMP_FILES+=("$existing_roles_file")
    TEMP_FILES+=("$filtered_globals_file")

    ###########################################################################
    # Existing target roles
    ###########################################################################

    restore_psql \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="
            SELECT rolname
            FROM pg_catalog.pg_roles
            ORDER BY rolname;
        " \
        > "$existing_roles_file"

    ###########################################################################
    # Filter role statements
    ###########################################################################

    awk \
        -v roles_file="$existing_roles_file" \
        '
        BEGIN {

            while ((getline role < roles_file) > 0) {

                gsub(/^[[:space:]]+|[[:space:]]+$/, "", role)

                if (role != "") {
                    existing[role] = 1
                }
            }

            close(roles_file)
        }

        /^CREATE ROLE / {

            role=$3

            sub(/;$/, "", role)

            if (existing[role]) {

                print "-- Skipped CREATE ROLE for existing role: " role

                next
            }
        }

        /^ALTER ROLE / {

            role=$3

            sub(/;$/, "", role)

            if (existing[role]) {

                print "-- Skipped ALTER ROLE for existing role: " role

                next
            }
        }

        {
            print
        }
        ' \
        "$GLOBALS_FILE" \
        > "$filtered_globals_file"

    ###########################################################################
    # Restore filtered globals
    ###########################################################################

    restore_psql \
        --dbname=postgres \
        --file="$filtered_globals_file"

    ok "Globals restored"

    ###########################################################################
    # Report skipped roles
    ###########################################################################

    local skipped_count

    skipped_count="$(
        grep -c '^-- Skipped CREATE ROLE' "$filtered_globals_file" || true
    )"

    if [[ "$skipped_count" -gt 0 ]]; then
        warn "$skipped_count existing role(s) were preserved"
    fi
}

###############################################################################
# Restore pre-flight
###############################################################################

restore_preflight() {

    log "Running restore pre-flight checks"

    ###########################################################################
    # Connection
    ###########################################################################

    restore_psql \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command='SELECT 1;' \
        >/dev/null

    ok "Connection to target PostgreSQL successful"

    ###########################################################################
    # Dump
    ###########################################################################

    pg_restore \
        --list \
        "$DUMP_FILE" \
        >/dev/null \
        || error "Invalid PostgreSQL dump"

    ok "PostgreSQL dump is readable"

    ###########################################################################
    # Checksums
    ###########################################################################

    verify_backup_checksums

    ###########################################################################
    # Manifest timestamp
    ###########################################################################

    local manifest_timestamp

    manifest_timestamp="$(manifest_get timestamp)"

    [[ "$manifest_timestamp" == "$RESTORE_TIMESTAMP" ]] || \
        error "Manifest timestamp does not match backup timestamp"

    ok "Manifest timestamp matches backup"

    ###########################################################################
    # Database must not exist
    ###########################################################################

    local escaped_database
    local db_exists

    escaped_database="$(sql_escape_literal "$RESTORE_DATABASE")"

    db_exists="$(
        restore_psql \
            --dbname=postgres \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_database
                WHERE datname = '$escaped_database';
            "
    )"

    db_exists="$(echo "$db_exists" | tr -d '[:space:]')"

    if [[ "$db_exists" != "0" ]]; then

        error "Target database already exists: $RESTORE_DATABASE

The script intentionally refuses to overwrite or drop an existing database."

    fi

    ok "Target database does not yet exist"
}

###############################################################################
# Dry-run
###############################################################################

restore_dry_run() {

    local manifest_database
    local manifest_owner
    local manifest_tables

    local manifest_rls_enabled
    local manifest_rls_forced
    local manifest_policies

    manifest_database="$(manifest_get database)"
    manifest_owner="$(manifest_get database_owner)"
    manifest_tables="$(manifest_get table_count)"

    manifest_rls_enabled="$(manifest_get rls_enabled_table_count)"
    manifest_rls_forced="$(manifest_get rls_forced_table_count)"
    manifest_policies="$(manifest_get rls_policy_count)"

    cat <<EOF

============================================================
 PostgreSQL RESTORE DRY-RUN
============================================================

Backup timestamp:
  $RESTORE_TIMESTAMP


SOURCE FILES

Globals:
  $GLOBALS_FILE

Database:
  $DUMP_FILE

Manifest:
  $MANIFEST_FILE


BACKUP MANIFEST

Database:
  $manifest_database

Owner:
  $manifest_owner

Tables:
  $manifest_tables

RLS enabled tables:
  $manifest_rls_enabled

RLS forced tables:
  $manifest_rls_forced

RLS policies:
  $manifest_policies


TARGET

Host:
  $RESTORE_HOST

Port:
  $RESTORE_PORT

Admin user:
  $RESTORE_ADMIN_USER

Database:
  $RESTORE_DATABASE

Owner:
  $RESTORE_OWNER


THE FOLLOWING WOULD BE EXECUTED

1. Verify dump integrity
2. Verify SHA-256 checksums
3. Read existing roles on target
4. Restore only missing roles
5. Preserve existing roles and their attributes
6. Create target database
7. Restore database
8. Validate against manifest
9. Compare RLS configuration
10. Compare configured table row counts
11. Test database connectivity
12. Test application-user connectivity, if configured


NO CHANGES HAVE BEEN MADE.


To execute:

  $SCRIPT_NAME \\
      --restore \\
      --timestamp "$RESTORE_TIMESTAMP" \\
      --commit

============================================================

EOF
}

###############################################################################
# Validate restore
###############################################################################

validate_against_manifest() {

    log "Validating restored database against backup manifest"

    local validation_failed=false

    local escaped_database

    escaped_database="$(sql_escape_literal "$RESTORE_DATABASE")"

    ###########################################################################
    # DB exists
    ###########################################################################

    local db_exists

    db_exists="$(
        restore_psql \
            --dbname=postgres \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_database
                WHERE datname = '$escaped_database';
            "
    )"

    db_exists="$(echo "$db_exists" | tr -d '[:space:]')"

    if [[ "$db_exists" == "1" ]]; then
        ok "Database exists: $RESTORE_DATABASE"
    else
        warn "Database missing: $RESTORE_DATABASE"
        validation_failed=true
    fi

    ###########################################################################
    # DB owner
    ###########################################################################

    local actual_owner

    actual_owner="$(
        restore_psql \
            --dbname=postgres \
            --tuples-only \
            --no-align \
            --command="
                SELECT pg_catalog.pg_get_userbyid(datdba)
                FROM pg_catalog.pg_database
                WHERE datname = '$escaped_database';
            "
    )"

    actual_owner="$(echo "$actual_owner" | xargs)"

    if [[ "$actual_owner" == "$RESTORE_OWNER" ]]; then
        ok "Database owner: $actual_owner"
    else
        warn "Database owner mismatch"
        warn "Expected: $RESTORE_OWNER"
        warn "Actual  : $actual_owner"

        validation_failed=true
    fi

    ###########################################################################
    # Owner role exists
    ###########################################################################

    local escaped_owner
    local owner_exists

    escaped_owner="$(sql_escape_literal "$RESTORE_OWNER")"

    owner_exists="$(
        restore_psql \
            --dbname=postgres \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_roles
                WHERE rolname = '$escaped_owner';
            "
    )"

    owner_exists="$(echo "$owner_exists" | tr -d '[:space:]')"

    if [[ "$owner_exists" == "1" ]]; then
        ok "Role exists: $RESTORE_OWNER"
    else
        warn "Role missing: $RESTORE_OWNER"
        validation_failed=true
    fi

    ###########################################################################
    # Tables
    ###########################################################################

    local expected_tables
    local actual_tables

    expected_tables="$(manifest_get table_count)"

    actual_tables="$(
        restore_psql \
            --dbname="$RESTORE_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM information_schema.tables
                WHERE table_schema NOT IN (
                    'pg_catalog',
                    'information_schema'
                )
                AND table_type = 'BASE TABLE';
            "
    )"

    actual_tables="$(echo "$actual_tables" | tr -d '[:space:]')"

    if [[ "$actual_tables" == "$expected_tables" ]]; then
        ok "Table count: $actual_tables"
    else
        warn "Table count mismatch"
        warn "Expected: $expected_tables"
        warn "Actual  : $actual_tables"

        validation_failed=true
    fi

    ###########################################################################
    # RLS enabled
    ###########################################################################

    local expected_rls_enabled
    local actual_rls_enabled

    expected_rls_enabled="$(manifest_get rls_enabled_table_count)"

    actual_rls_enabled="$(
        restore_psql \
            --dbname="$RESTORE_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n
                  ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p')
                  AND n.nspname NOT IN (
                      'pg_catalog',
                      'information_schema'
                  )
                  AND c.relrowsecurity = true;
            "
    )"

    actual_rls_enabled="$(echo "$actual_rls_enabled" | tr -d '[:space:]')"

    if [[ "$actual_rls_enabled" == "$expected_rls_enabled" ]]; then
        ok "RLS enabled tables: $actual_rls_enabled"
    else
        warn "RLS enabled table count mismatch"
        warn "Expected: $expected_rls_enabled"
        warn "Actual  : $actual_rls_enabled"

        validation_failed=true
    fi

    ###########################################################################
    # RLS forced
    ###########################################################################

    local expected_rls_forced
    local actual_rls_forced

    expected_rls_forced="$(manifest_get rls_forced_table_count)"

    actual_rls_forced="$(
        restore_psql \
            --dbname="$RESTORE_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n
                  ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p')
                  AND n.nspname NOT IN (
                      'pg_catalog',
                      'information_schema'
                  )
                  AND c.relforcerowsecurity = true;
            "
    )"

    actual_rls_forced="$(echo "$actual_rls_forced" | tr -d '[:space:]')"

    if [[ "$actual_rls_forced" == "$expected_rls_forced" ]]; then
        ok "RLS forced tables: $actual_rls_forced"
    else
        warn "RLS forced table count mismatch"
        warn "Expected: $expected_rls_forced"
        warn "Actual  : $actual_rls_forced"

        validation_failed=true
    fi

    ###########################################################################
    # RLS policies
    ###########################################################################

    local expected_policies
    local actual_policies

    expected_policies="$(manifest_get rls_policy_count)"

    actual_policies="$(
        restore_psql \
            --dbname="$RESTORE_DATABASE" \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_policies;
            "
    )"

    actual_policies="$(echo "$actual_policies" | tr -d '[:space:]')"

    if [[ "$actual_policies" == "$expected_policies" ]]; then
        ok "RLS policies: $actual_policies"
    else
        warn "RLS policy count mismatch"
        warn "Expected: $expected_policies"
        warn "Actual  : $actual_policies"

        validation_failed=true
    fi

    ###########################################################################
    # Required RLS checks
    ###########################################################################

    if [[ "$VALIDATION_REQUIRE_RLS" == "true" ]] && \
       [[ "$actual_rls_enabled" == "0" ]]
    then
        warn "RLS required but no RLS-enabled tables found"
        validation_failed=true
    fi

    if [[ "$VALIDATION_REQUIRE_POLICIES" == "true" ]] && \
       [[ "$actual_policies" == "0" ]]
    then
        warn "RLS policies required but none found"
        validation_failed=true
    fi

    ###########################################################################
    # Validation tables
    ###########################################################################

    local table
    local schema
    local table_name

    local expected_status
    local expected_rows
    local actual_rows

    local table_exists

    for table in $VALIDATION_TABLES; do

        validate_table_name "$table"

        schema="${table%%.*}"
        table_name="${table#*.}"

        expected_status="$(
            manifest_get "table.${table}.status"
        )"

        if [[ "$expected_status" == "missing" ]]; then
            warn "Validation table was already missing in source: $table"
            continue
        fi

        expected_rows="$(
            manifest_get "table.${table}.rows"
        )"

        if [[ -z "$expected_rows" ]]; then
            warn "Manifest row count missing for: $table"
            validation_failed=true
            continue
        fi

        table_exists="$(
            restore_psql \
                --dbname="$RESTORE_DATABASE" \
                --tuples-only \
                --no-align \
                --command="
                    SELECT count(*)
                    FROM information_schema.tables
                    WHERE table_schema = '$schema'
                      AND table_name = '$table_name'
                      AND table_type = 'BASE TABLE';
                "
        )"

        table_exists="$(echo "$table_exists" | tr -d '[:space:]')"

        if [[ "$table_exists" != "1" ]]; then
            warn "Validation table missing after restore: $table"
            validation_failed=true
            continue
        fi

        actual_rows="$(
            restore_psql \
                --dbname="$RESTORE_DATABASE" \
                --tuples-only \
                --no-align \
                --command="
                    SELECT count(*)
                    FROM \"$schema\".\"$table_name\";
                "
        )"

        actual_rows="$(echo "$actual_rows" | tr -d '[:space:]')"

        if [[ "$actual_rows" == "$expected_rows" ]]; then
            ok "$table rows: $actual_rows"
        else
            warn "$table row count mismatch"
            warn "Expected: $expected_rows"
            warn "Actual  : $actual_rows"

            validation_failed=true
        fi

    done

    ###########################################################################
    # Admin connectivity
    ###########################################################################

    if restore_psql \
        --dbname="$RESTORE_DATABASE" \
        --command='SELECT 1;' \
        >/dev/null
    then
        ok "Database accepts administrative connections"
    else
        warn "Database administrative connection failed"
        validation_failed=true
    fi

    ###########################################################################
    # Optional app connectivity
    ###########################################################################

    if [[ -n "${RESTORE_APP_USER:-}" ]] && \
       [[ -n "${RESTORE_APP_PASSWORD:-}" ]]
    then

        log "Testing application database connection"

        if PGPASSWORD="$RESTORE_APP_PASSWORD" \
            psql \
            -X \
            --host="$RESTORE_HOST" \
            --port="$RESTORE_PORT" \
            --username="$RESTORE_APP_USER" \
            --dbname="$RESTORE_DATABASE" \
            --set=ON_ERROR_STOP=on \
            --command='SELECT 1;' \
            >/dev/null 2>&1
        then
            ok "Application user can connect: $RESTORE_APP_USER"
        else
            warn "Application user cannot connect: $RESTORE_APP_USER"
            validation_failed=true
        fi
    fi

    ###########################################################################
    # Result
    ###########################################################################

    echo

    if [[ "$validation_failed" == true ]]; then
        error "RESTORE VALIDATION FAILED"
    fi

    printf '%s\n' \
        "============================================================" \
        " RESTORE VALIDATION SUCCESSFUL" \
        "============================================================"
}

###############################################################################
# Restore
###############################################################################

do_restore() {

    require_var RESTORE_HOST
    require_var RESTORE_ADMIN_USER
    require_var RESTORE_ADMIN_PASSWORD
    require_var RESTORE_DATABASE
    require_var RESTORE_OWNER

    find_restore_files

    ###########################################################################
    # Dry-run
    ###########################################################################

    if [[ "$COMMIT" != true ]]; then
        restore_dry_run
        return 0
    fi

    ###########################################################################
    # Pre-flight
    ###########################################################################

    restore_preflight

    log "Starting PostgreSQL restore"
    log "Backup timestamp: $RESTORE_TIMESTAMP"

    ###########################################################################
    # 1. Globals
    ###########################################################################

    log "Step 1/3: Restoring roles / grants / globals"

    restore_globals

    ###########################################################################
    # Verify owner now exists
    ###########################################################################

    local escaped_owner
    local owner_exists

    escaped_owner="$(sql_escape_literal "$RESTORE_OWNER")"

    owner_exists="$(
        restore_psql \
            --dbname=postgres \
            --tuples-only \
            --no-align \
            --command="
                SELECT count(*)
                FROM pg_catalog.pg_roles
                WHERE rolname = '$escaped_owner';
            "
    )"

    owner_exists="$(echo "$owner_exists" | tr -d '[:space:]')"

    if [[ "$owner_exists" != "1" ]]; then
        error "Restore owner does not exist after globals restore: $RESTORE_OWNER"
    fi

    ok "Restore owner exists: $RESTORE_OWNER"

    ###########################################################################
    # 2. Create database
    ###########################################################################

    log "Step 2/3: Creating database '$RESTORE_DATABASE'"

    PGPASSWORD="$RESTORE_ADMIN_PASSWORD" \
        createdb \
        --host="$RESTORE_HOST" \
        --port="$RESTORE_PORT" \
        --username="$RESTORE_ADMIN_USER" \
        --owner="$RESTORE_OWNER" \
        "$RESTORE_DATABASE"

    ###########################################################################
    # 3. Restore database
    ###########################################################################

    log "Step 3/3: Restoring database"

    PGPASSWORD="$RESTORE_ADMIN_PASSWORD" \
        pg_restore \
        --host="$RESTORE_HOST" \
        --port="$RESTORE_PORT" \
        --username="$RESTORE_ADMIN_USER" \
        --dbname="$RESTORE_DATABASE" \
        --exit-on-error \
        "$DUMP_FILE"

    echo

    log "PostgreSQL restore completed"

    ###########################################################################
    # Validation
    ###########################################################################

    validate_against_manifest
}

###############################################################################
# Main
###############################################################################

case "$ACTION" in

    backup)
        do_backup
        ;;

    restore)
        do_restore
        ;;

    *)
        error "Invalid action"
        ;;

esac
