# PostgreSQL Backup & Restore Script

A conservative Bash-based PostgreSQL backup and restore utility designed for repeatable database backups, controlled restores, integrity verification, and post-restore validation.

The script backs up both:

- PostgreSQL cluster-level globals, such as roles and grants
- A selected PostgreSQL database in custom dump format

It also creates a manifest containing metadata, SHA-256 checksums, RLS configuration, policy counts, and selected table row counts.

Restore operations are safe by default. Running `--restore` performs a dry-run only. The target PostgreSQL instance is modified only when `--commit` is explicitly supplied.

---

# Features

The script provides:

- configuration via `.env`
- `--backup`
- `--restore`
- restore dry-run by default
- explicit `--commit` requirement
- timestamp-based backup selection
- PostgreSQL globals backup using `pg_dumpall`
- custom-format database backup using `pg_dump`
- SHA-256 integrity verification
- backup manifest
- PostgreSQL version recording
- database owner recording
- table-count validation
- Row Level Security validation
- separate validation of:
  - `ENABLE ROW LEVEL SECURITY`
  - `FORCE ROW LEVEL SECURITY`
- RLS policy validation
- selected table row-count validation
- validation of PostgreSQL connectivity
- optional validation using the application database account
- protection against overwriting an existing target database
- handling of PostgreSQL roles that already exist on the restore target
- protection against modifying attributes of existing target roles
- optional exclusion of PostgreSQL role password hashes from backups
- non-zero exit status on backup, restore, or validation failure

---

# Design principles

The script follows several conservative operational principles.

## Restore is dry-run by default

The command:

```bash
./postgres-backup.sh --restore
```

does not modify PostgreSQL.

A real restore requires:

```bash
./postgres-backup.sh --restore --commit
```

This reduces the risk of accidentally restoring a backup into the wrong environment.

---

## Existing databases are never overwritten

The script refuses to restore if the configured target database already exists.

For example:

```text
ERROR: Target database already exists: app_app

The script intentionally refuses to overwrite or drop an existing database.
```

Dropping an existing target database is deliberately outside the scope of this script.

If a restore must be repeated, remove or rename the target database manually after verifying that this is safe.

---

## Existing roles are preserved

`pg_dumpall --globals-only` normally contains statements such as:

```sql
CREATE ROLE postgres;
ALTER ROLE postgres WITH SUPERUSER CREATEDB CREATEROLE LOGIN;
```

On a restore target, standard roles such as `postgres` usually already exist.

The script therefore determines which roles already exist on the target and filters the globals restore.

For existing roles:

```text
CREATE ROLE
```

is skipped.

The corresponding:

```text
ALTER ROLE
```

is also skipped.

This prevents a restore from accidentally changing the permissions, password, login attributes, or privilege level of an existing target role.

Missing roles are restored normally.

---

# Requirements

## Operating system

The script is intended for Unix-like environments such as:

- Linux
- WSL
- Debian
- Ubuntu
- Kali Linux
- RHEL-compatible systems
- container-based administrative environments

The script requires Bash.

Check:

```bash
bash --version
```

---

## PostgreSQL client utilities

The following commands must be available:

```text
psql
pg_dump
pg_dumpall
pg_restore
createdb
```

Check:

```bash
psql --version
pg_dump --version
pg_dumpall --version
pg_restore --version
createdb --version
```

Ideally, the PostgreSQL client version should be the same version as, or newer than, the PostgreSQL server being backed up.

---

## Additional utilities

The script also uses:

```text
sha256sum
awk
grep
sort
tail
mktemp
```

These are normally available on standard Linux installations.

---

# Installation

Place the script in a suitable directory:

```text
postgres-backup/
├── postgres-backup.sh
├── .env
└── backups/
```

Make it executable:

```bash
chmod 700 postgres-backup.sh
```

The `.env` file contains database credentials and should also have restrictive permissions:

```bash
chmod 600 .env
```

---

# Configuration

The script reads its configuration from `.env`.

Example:

```dotenv
###############################################################################
# Backup source
###############################################################################

BACKUP_HOST=postgres-prod
BACKUP_PORT=5432

BACKUP_ADMIN_USER=postgres
BACKUP_ADMIN_PASSWORD=CHANGE_ME

BACKUP_DATABASE=app_app


###############################################################################
# PostgreSQL role password handling
###############################################################################

BACKUP_ROLE_PASSWORDS=false


###############################################################################
# Restore target
###############################################################################

RESTORE_HOST=postgres-dev
RESTORE_PORT=5432

RESTORE_ADMIN_USER=postgres
RESTORE_ADMIN_PASSWORD=CHANGE_ME

RESTORE_DATABASE=app_app
RESTORE_OWNER=app_app


###############################################################################
# Optional application connectivity test
###############################################################################

RESTORE_APP_USER=app_app
RESTORE_APP_PASSWORD=CHANGE_ME


###############################################################################
# Backup storage
###############################################################################

BACKUP_DIR=./backups
BACKUP_PREFIX=app


###############################################################################
# Validation
###############################################################################

VALIDATION_TABLES="public.app_authority public.app_workspace"

VALIDATION_REQUIRE_RLS=true

VALIDATION_REQUIRE_POLICIES=true
```

---

# Configuration reference

## Backup source

### `BACKUP_HOST`

Hostname or IP address of the PostgreSQL server that will be backed up.

Example:

```dotenv
BACKUP_HOST=postgres-prod
```

---

### `BACKUP_PORT`

PostgreSQL port.

Default:

```text
5432
```

Example:

```dotenv
BACKUP_PORT=5432
```

---

### `BACKUP_ADMIN_USER`

Administrative account used for the backup.

The account must have sufficient permissions to:

- run `pg_dumpall --globals-only`
- read the target database
- bypass RLS where necessary
- access all objects required for a complete backup

Example:

```dotenv
BACKUP_ADMIN_USER=postgres
```

A dedicated backup account may be preferable in production environments.

---

### `BACKUP_ADMIN_PASSWORD`

Password for `BACKUP_ADMIN_USER`.

Example:

```dotenv
BACKUP_ADMIN_PASSWORD=CHANGE_ME
```

Protect `.env` appropriately:

```bash
chmod 600 .env
```

---

### `BACKUP_DATABASE`

Database to back up.

Example:

```dotenv
BACKUP_DATABASE=app_app
```

---

# Role password handling

## `BACKUP_ROLE_PASSWORDS`

Recommended:

```dotenv
BACKUP_ROLE_PASSWORDS=false
```

When `false`, the globals backup uses:

```bash
pg_dumpall --globals-only --no-role-passwords
```

This prevents PostgreSQL password hashes from being written to the globals backup.

This is recommended when credentials are managed independently through:

- environment variables
- secret stores
- deployment tooling
- Kubernetes Secrets
- Vault
- Docker secrets
- CI/CD secrets

Set:

```dotenv
BACKUP_ROLE_PASSWORDS=true
```

only when restoring PostgreSQL role password hashes is explicitly required.

Be aware that the globals backup then contains sensitive authentication information.

---

# Restore configuration

## `RESTORE_HOST`

Target PostgreSQL server.

Example:

```dotenv
RESTORE_HOST=postgres-dev
```

---

## `RESTORE_PORT`

Target PostgreSQL port.

Example:

```dotenv
RESTORE_PORT=5432
```

---

## `RESTORE_ADMIN_USER`

Administrative role used for restore operations.

Example:

```dotenv
RESTORE_ADMIN_USER=postgres
```

The account must have sufficient permissions to:

- create roles
- create databases
- create schemas
- restore database objects
- create owners
- grant privileges

---

## `RESTORE_ADMIN_PASSWORD`

Password of the restore administrator.

Example:

```dotenv
RESTORE_ADMIN_PASSWORD=CHANGE_ME
```

---

## `RESTORE_DATABASE`

Name of the database created during restore.

Example:

```dotenv
RESTORE_DATABASE=app_app
```

The script refuses to continue if this database already exists.

---

## `RESTORE_OWNER`

Role that should own the newly created database.

Example:

```dotenv
RESTORE_OWNER=app_app
```

After restoring globals, the script verifies that this role exists before creating the database.

---

# Optional application validation

The following variables are optional:

```dotenv
RESTORE_APP_USER=app_app
RESTORE_APP_PASSWORD=CHANGE_ME
```

If configured, the script attempts a connection after the restore using the actual application account.

This helps identify issues where:

- the database exists
- the administrative restore succeeded
- but the application account cannot authenticate or connect

Example success:

```text
[OK] Application user can connect: app_app
```

---

# Backup storage

## `BACKUP_DIR`

Backup directory.

Default:

```text
./backups
```

Example:

```dotenv
BACKUP_DIR=./backups
```

---

## `BACKUP_PREFIX`

Filename prefix.

Default:

```text
app
```

Example:

```dotenv
BACKUP_PREFIX=app
```

---

# Validation configuration

## `VALIDATION_TABLES`

Defines important tables whose exact row counts should be recorded during backup and compared after restore.

Example:

```dotenv
VALIDATION_TABLES="public.app_authority public.app_workspace"
```

Use tables that are:

- expected to exist
- operationally relevant
- stable enough to provide useful restore verification

The table names must have the format:

```text
schema.table
```

For example:

```text
public.app_authority
```

Quoted or unusual PostgreSQL identifiers are intentionally not supported.

---

## Missing validation tables

If a configured validation table does not exist on the source system, the backup is not aborted.

Instead:

```text
[WARNING] Validation table does not exist and will be skipped: public.app_user
```

The manifest records:

```text
table.public.app_user.status=missing
```

During restore validation, this table is not treated as a restore failure because it was already absent from the source.

This distinguishes:

```text
Source table missing
```

from:

```text
Source table existed, but restore table is missing
```

The latter is considered a restore failure.

---

## `VALIDATION_REQUIRE_RLS`

Example:

```dotenv
VALIDATION_REQUIRE_RLS=true
```

If enabled, validation fails when the source expected RLS but the restored database contains no RLS-enabled tables.

---

## `VALIDATION_REQUIRE_POLICIES`

Example:

```dotenv
VALIDATION_REQUIRE_POLICIES=true
```

If enabled, validation fails if expected RLS policies are absent.

---

# Backup

Run:

```bash
./postgres-backup.sh --backup
```

Example output:

```text
[2026-09-15 20:18:25] Starting PostgreSQL backup
[2026-09-15 20:18:25] Timestamp: 20260915T2018
[2026-09-15 20:18:25] Backing up PostgreSQL roles / grants / globals
[2026-09-15 20:18:25] Backing up PostgreSQL database
[2026-09-15 20:18:26] Verifying database dump
[OK] Database dump is readable
[2026-09-15 20:18:26] Creating backup manifest
[OK] Manifest created: ./backups/app_manifest_20260915T2018.txt
[OK] Tables: 43
[OK] RLS enabled tables: 31
[OK] RLS forced tables: 31
[OK] RLS policies: 84

[2026-09-15 20:18:27] Backup completed successfully
```

---

# Backup files

Each backup produces three related files with the same timestamp.

Example:

```text
backups/
├── app_globals_20260915T2018.sql
├── app_pg_20260915T2018.dump
└── app_manifest_20260915T2018.txt
```

These three files form one backup set.

Do not mix files from different timestamps.

---

# Globals backup

Example:

```text
app_globals_20260915T2018.sql
```

Created with:

```bash
pg_dumpall --globals-only
```

or, by default:

```bash
pg_dumpall --globals-only --no-role-passwords
```

The globals dump may contain:

- roles
- role attributes
- grants
- tablespace definitions
- cluster-level metadata

It does not contain normal database table data.

---

# Database dump

Example:

```text
app_pg_20260915T2018.dump
```

Created using:

```bash
pg_dump --format=custom
```

The custom format allows restore through:

```bash
pg_restore
```

The script immediately verifies that the generated dump can be parsed:

```bash
pg_restore --list backup.dump
```

A failure causes the backup command to terminate.

---

# Backup manifest

Example:

```text
app_manifest_20260915T2018.txt
```

A manifest may contain:

```text
manifest_version=1
timestamp=20260915T2018
database=app_app
database_owner=app_app
postgres_version=17.6
table_count=43
rls_enabled_table_count=31
rls_forced_table_count=31
rls_policy_count=84
globals_sha256=60bc7...
dump_sha256=a231f...
table.public.app_authority.status=present
table.public.app_authority.rows=17
table.public.app_workspace.status=present
table.public.app_workspace.rows=6
```

The manifest serves both as documentation and as a restore validation baseline.

---

# SHA-256 integrity validation

The script calculates a SHA-256 checksum for:

```text
globals SQL
database dump
```

The hashes are stored in the manifest.

Before a committed restore, the script recalculates both hashes and compares them.

Example:

```text
[OK] Globals checksum valid
[OK] Database dump checksum valid
```

If either file has changed or become corrupted, restore stops before modifying the target database.

Example:

```text
ERROR: Database dump checksum mismatch
```

---

# Row Level Security validation

The script distinguishes between:

```sql
ALTER TABLE example ENABLE ROW LEVEL SECURITY;
```

and:

```sql
ALTER TABLE example FORCE ROW LEVEL SECURITY;
```

PostgreSQL stores these states in:

```text
pg_class.relrowsecurity
pg_class.relforcerowsecurity
```

The manifest records them separately:

```text
rls_enabled_table_count=31
rls_forced_table_count=31
```

This is important because `FORCE ROW LEVEL SECURITY` changes how RLS behaves for table owners.

---

# RLS policy validation

The script also records:

```text
rls_policy_count
```

using:

```sql
SELECT count(*)
FROM pg_catalog.pg_policies;
```

Example:

```text
rls_policy_count=84
```

After restore, the same value is calculated and compared.

---

# Restore dry-run

Running:

```bash
./postgres-backup.sh --restore
```

selects the newest available backup and displays what would happen.

No PostgreSQL changes are made.

Example:

```text
============================================================
 PostgreSQL RESTORE DRY-RUN
============================================================

Backup timestamp:
  20260915T2018

SOURCE FILES

Globals:
  ./backups/app_globals_20260915T2018.sql

Database:
  ./backups/app_pg_20260915T2018.dump

Manifest:
  ./backups/app_manifest_20260915T2018.txt

TARGET

Host:
  postgres-dev

Database:
  app_app

Owner:
  app_app

NO CHANGES HAVE BEEN MADE.
```

---

# Restore a specific backup

Dry-run:

```bash
./postgres-backup.sh \
    --restore \
    --timestamp 20260915T2018
```

Committed restore:

```bash
./postgres-backup.sh \
    --restore \
    --timestamp 20260915T2018 \
    --commit
```

---

# Restore workflow

A committed restore performs the following sequence.

## 1. Connect to target PostgreSQL

The script verifies that the restore administrator can connect.

---

## 2. Validate database dump

The dump is checked using:

```bash
pg_restore --list
```

---

## 3. Validate SHA-256 hashes

The dump and globals file are compared against the manifest.

---

## 4. Validate manifest timestamp

The timestamp recorded inside the manifest must match the selected backup timestamp.

---

## 5. Check target database

The target database must not already exist.

If it exists:

```text
ERROR: Target database already exists: app_app
```

---

## 6. Inspect existing roles

The target cluster is queried using:

```sql
SELECT rolname
FROM pg_catalog.pg_roles;
```

---

## 7. Restore globals

Existing roles are preserved.

New roles are restored.

This avoids errors such as:

```text
ERROR: role "postgres" already exists
```

and prevents existing target roles from being unexpectedly altered.

---

## 8. Validate database owner role

The role configured as:

```dotenv
RESTORE_OWNER=app_app
```

must exist after the globals restore.

---

## 9. Create target database

The script executes the equivalent of:

```bash
createdb \
    -O app_app \
    app_app
```

---

## 10. Restore database

The dump is restored using:

```bash
pg_restore \
    --exit-on-error \
    --dbname=app_app \
    backup.dump
```

`--exit-on-error` ensures that a PostgreSQL restore failure stops processing.

---

## 11. Validate restored database

The result is compared with the backup manifest.

---

# Post-restore validation

A successful restore may produce output similar to:

```text
[OK] Database exists: app_app
[OK] Database owner: app_app
[OK] Role exists: app_app
[OK] Table count: 43
[OK] RLS enabled tables: 31
[OK] RLS forced tables: 31
[OK] RLS policies: 84
[OK] public.app_authority rows: 17
[OK] public.app_workspace rows: 6
[OK] Database accepts administrative connections
[OK] Application user can connect: app_app

============================================================
 RESTORE VALIDATION SUCCESSFUL
============================================================
```

---

# Exit codes

Successful execution returns:

```text
0
```

Example:

```bash
./postgres-backup.sh --backup
echo $?
```

Expected:

```text
0
```

A backup, restore, or validation failure returns a non-zero exit status.

This makes the script suitable for:

- cron
- CI/CD
- systemd
- monitoring
- scheduled backup jobs

---

# Security considerations

## Protect `.env`

The environment file contains credentials.

Recommended:

```bash
chmod 600 .env
```

Do not commit `.env` to Git.

Add it to `.gitignore`:

```gitignore
.env
```

---

## Protect backups

The globals dump may contain sensitive role and privilege information.

The script uses:

```bash
umask 077
```

so newly created files are accessible only by the owner by default.

Still verify permissions:

```bash
ls -la backups/
```

---

## Do not store backups only locally

A backup stored on the same host as PostgreSQL does not provide sufficient disaster recovery protection.

Consider copying completed backup sets to:

- another host
- object storage
- an encrypted backup server
- immutable storage
- offline storage

---

## Encrypt backups at rest

The script does not itself encrypt backups.

For sensitive databases, consider storage-level encryption or encrypting the resulting backup files.

---

## Avoid production password reuse

For non-production restores, use separate credentials.

Recommended:

```dotenv
BACKUP_ROLE_PASSWORDS=false
```

This avoids transferring production PostgreSQL password hashes into development or test environments.

---

# Important PostgreSQL considerations

## Row Level Security and `pg_dump`

A backup may fail with:

```text
pg_dump: error: query failed:
ERROR: query would be affected by row-level security policy
```

For example:

```text
table "app_authority"
```

This usually means that the account used by `pg_dump` cannot bypass RLS.

Do not solve this by adding:

```bash
pg_dump --enable-row-security
```

for a normal disaster-recovery backup.

That may result in only rows visible through the RLS policy being backed up.

Instead, use a backup account with sufficient privileges, typically:

- a superuser
- or a dedicated role with `BYPASSRLS` and appropriate read access

Example:

```sql
CREATE ROLE app_backup
LOGIN
BYPASSRLS;
```

Grant required access separately.

---

# Troubleshooting

## `query would be affected by row-level security policy`

Example:

```text
pg_dump: error: query failed:
ERROR: query would be affected by row-level security policy for table "app_authority"
```

Cause:

The backup account is subject to RLS.

Resolution:

Use an account with:

```text
BYPASSRLS
```

or sufficient superuser privileges.

Avoid temporarily disabling RLS as part of the backup procedure.

---

## `syntax error at or near ":"`

Earlier versions of the script may have used:

```sql
WHERE datname = :'dbname'
```

with `psql --command`.

This can result in:

```text
ERROR: syntax error at or near ":"
```

The current script does not use this pattern.

Database names are escaped before constructing these specific administrative queries.

---

## `column "forcerowsecurity" does not exist`

Example:

```text
ERROR: column "forcerowsecurity" does not exist
```

Cause:

`pg_tables` contains `rowsecurity`, but not `forcerowsecurity`.

The current implementation uses:

```text
pg_class.relrowsecurity
pg_class.relforcerowsecurity
```

This is the correct PostgreSQL catalogue source.

---

## `Validation table does not exist`

Example:

```text
ERROR: Validation table does not exist: public.app_user
```

Earlier script versions treated this as fatal.

The current script records missing source validation tables as:

```text
table.public.app_user.status=missing
```

and continues the backup.

However, the best configuration is still to remove obsolete tables from:

```dotenv
VALIDATION_TABLES
```

You can list available tables with:

```bash
PGPASSWORD="$BACKUP_ADMIN_PASSWORD" \
psql \
    -h "$BACKUP_HOST" \
    -p "$BACKUP_PORT" \
    -U "$BACKUP_ADMIN_USER" \
    -d "$BACKUP_DATABASE" \
    -c "
SELECT
    table_schema,
    table_name
FROM information_schema.tables
WHERE table_schema NOT IN (
    'pg_catalog',
    'information_schema'
)
AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name;
"
```

---

## `role "postgres" already exists`

Example:

```text
psql:app_globals.sql:30:
ERROR: role "postgres" already exists
```

This is expected when restoring `pg_dumpall --globals-only` onto an existing PostgreSQL cluster.

The current script handles this automatically.

Existing roles are detected and their `CREATE ROLE` and `ALTER ROLE` statements are skipped.

For example:

```text
[WARNING] 1 existing role(s) were preserved
```

---

## Target database already exists

Example:

```text
ERROR: Target database already exists: app_app
```

This is intentional.

The script will not:

```sql
DROP DATABASE
```

automatically.

To repeat a restore, manually remove the test database only after verifying that doing so is safe.

Example:

```bash
dropdb \
    -h "$RESTORE_HOST" \
    -p "$RESTORE_PORT" \
    -U "$RESTORE_ADMIN_USER" \
    "$RESTORE_DATABASE"
```

Then repeat the restore.

---

## SHA-256 mismatch

Example:

```text
ERROR: Database dump checksum mismatch
```

Possible causes:

- file corruption
- incomplete file transfer
- backup was modified
- incorrect manifest paired with the dump
- files from different backup timestamps were mixed

Do not restore until the cause has been identified.

---

## Application user cannot connect

Example:

```text
[WARNING] Application user cannot connect: app_app
ERROR: RESTORE VALIDATION FAILED
```

Check:

- PostgreSQL password
- `LOGIN` attribute
- `pg_hba.conf`
- TLS requirements
- database `CONNECT` privilege
- role membership
- target-specific credentials

If application credentials are intentionally different between environments, ensure:

```dotenv
RESTORE_APP_PASSWORD
```

contains the target environment password.

---

# Listing existing backups

Example:

```bash
ls -lh backups/
```

Output:

```text
app_globals_20260915T2018.sql
app_manifest_20260915T2018.txt
app_pg_20260915T2018.dump

app_globals_20260916T0200.sql
app_manifest_20260916T0200.txt
app_pg_20260916T0200.dump
```

---

# Inspecting a manifest

```bash
cat backups/app_manifest_20260915T2018.txt
```

---

# Inspecting a PostgreSQL dump

List objects without restoring:

```bash
pg_restore \
    --list \
    backups/app_pg_20260915T2018.dump
```

This is useful for debugging and inspection.

---

# Manual integrity verification

Verify globals:

```bash
sha256sum backups/app_globals_20260915T2018.sql
```

Verify database dump:

```bash
sha256sum backups/app_pg_20260915T2018.dump
```

Compare the hashes with:

```text
globals_sha256=
dump_sha256=
```

inside the manifest.

---

# Recommended restore testing procedure

Backups should be restored regularly. A backup that has never been restored should not be assumed to be recoverable.

A recommended test procedure is:

1. select an isolated PostgreSQL target
2. ensure the target database does not exist
3. run restore without `--commit`
4. review source files and target settings
5. perform restore with `--commit`
6. verify automatic validation succeeds
7. connect using the application account
8. start the application against the restored database
9. perform basic functional tests
10. document restore time and findings
11. remove the temporary restore environment when testing is complete

---

# Example recovery test

Dry-run:

```bash
./postgres-backup.sh \
    --restore \
    --timestamp 20260915T2018
```

Review the output carefully.

Then:

```bash
./postgres-backup.sh \
    --restore \
    --timestamp 20260915T2018 \
    --commit
```

Verify:

```text
RESTORE VALIDATION SUCCESSFUL
```

Then check:

```bash
echo $?
```

Expected:

```text
0
```

---

# Recommended backup schedule

The script itself does not schedule backups.

For example, using cron:

```cron
0 2 * * * /opt/postgres-backup/postgres-backup.sh --backup >> /var/log/postgres-backup.log 2>&1
```

This runs every day at 02:00.

When using scheduled jobs, ensure that:

- `.env` is accessible to the executing account
- the working directory is correct
- `BACKUP_DIR` uses an absolute path where appropriate
- PostgreSQL client utilities are in `PATH`
- logs are monitored
- backup retention is implemented separately

---

# Backup retention

The script currently does not automatically delete old backups.

This is intentional because retention policies vary significantly.

Example external cleanup for backups older than 30 days:

```bash
find /backup/postgres \
    -type f \
    -mtime +30 \
    -delete
```

Use this only when all backup files in that location are subject to the same retention policy.

A more conservative approach is to delete complete timestamped backup sets together.

---

# Backup consistency considerations

`pg_dump` creates a transactionally consistent database backup.

However, `pg_dumpall --globals-only` and `pg_dump` are separate operations.

The globals file and database dump therefore do not represent one atomic cluster-wide transaction.

For normal database disaster recovery this is usually acceptable, but it is important to understand the distinction.

---

# What is not backed up

Depending on PostgreSQL architecture and configuration, additional components may require separate backup procedures.

Examples include:

- `postgresql.conf`
- `pg_hba.conf`
- TLS certificates
- operating-system configuration
- extensions installed at operating-system level
- external files referenced by the application
- WAL archives
- replication configuration
- container definitions
- application secrets
- object storage
- filesystem data outside PostgreSQL

This script is a logical PostgreSQL backup utility. It is not a complete host or infrastructure backup.

---

# Logical backup vs physical backup

This script uses logical backups:

```text
pg_dump
pg_dumpall
```

Advantages:

- portable
- inspectable
- useful for migration
- useful between environments
- selective restore possible
- suitable for many application databases

For large databases or strict recovery objectives, consider complementing this with physical backup and WAL archiving.

Examples include:

- `pg_basebackup`
- continuous WAL archiving
- PostgreSQL-native PITR
- pgBackRest
- Barman

---

# Recovery Point Objective

The achievable RPO depends on backup frequency.

For example:

```text
Daily backup
Potential data loss: up to approximately 24 hours
```

A requirement for significantly smaller RPO typically requires WAL archiving or another continuous backup mechanism.

---

# Recovery Time Objective

Restore time depends on:

- database size
- CPU
- storage performance
- target hardware
- indexes
- constraints
- amount of data
- network latency

Restore tests should record actual recovery duration.

---

# Recommended operational practices

For production use:

1. use a dedicated backup host or execution account
2. protect `.env`
3. use a dedicated PostgreSQL backup role where possible
4. grant `BYPASSRLS` when required for complete backups
5. set `BACKUP_ROLE_PASSWORDS=false`
6. copy backups off-host
7. encrypt backups at rest
8. maintain retention rules
9. monitor backup exit codes
10. test restores regularly
11. test application connectivity after restore
12. periodically verify backup integrity
13. document RPO and RTO
14. maintain an immutable copy where appropriate

---

# Recommended directory layout

Example:

```text
/opt/postgres-backup/
├── postgres-backup.sh
├── .env
├── README.md
└── backups/
    ├── app_globals_20260915T2018.sql
    ├── app_manifest_20260915T2018.txt
    ├── app_pg_20260915T2018.dump
    ├── app_globals_20260916T0200.sql
    ├── app_manifest_20260916T0200.txt
    └── app_pg_20260916T0200.dump
```

---

# `.gitignore`

Recommended:

```gitignore
.env
backups/
*.dump
*.sql
*_manifest_*.txt
```

Never commit real database backups or secrets into a source repository.

---

# Quick reference

## Backup

```bash
./postgres-backup.sh --backup
```

## Restore dry-run, latest backup

```bash
./postgres-backup.sh --restore
```

## Restore dry-run, selected backup

```bash
./postgres-backup.sh \
    --restore \
    --timestamp 20260915T2018
```

## Commit selected restore

```bash
./postgres-backup.sh \
    --restore \
    --timestamp 20260915T2018 \
    --commit
```

## Check result

```bash
echo $?
```

Expected after success:

```text
0
```

---

# Restore success criteria

A restore should only be considered successful when all relevant checks pass.

At minimum:

```text
Database created
Database owner correct
Required role exists
Dump restored without pg_restore errors
Expected table count restored
RLS configuration restored
RLS policies restored
Validation table row counts match
Administrative connection works
Application connection works, if configured
```

The final expected message is:

```text
============================================================
 RESTORE VALIDATION SUCCESSFUL
============================================================
```

A successful shell exit code should additionally be:

```text
0
```

---

# Limitations

The current implementation intentionally does not:

- automatically drop existing databases
- automatically overwrite existing roles
- automatically alter existing target roles
- restore production role passwords by default
- encrypt backup files
- transfer backups to remote storage
- implement retention
- perform PITR
- archive WAL
- validate every row in every table
- validate application-level business logic
- validate external application dependencies

These should be implemented separately where required.

---

# Summary

The script is intended to provide a safer alternative to manually executing:

```bash
pg_dumpall
pg_dump
createdb
pg_restore
```

It adds explicit operational controls around those commands:

```text
Backup
  ↓
Globals + DB dump
  ↓
Dump verification
  ↓
Manifest generation
  ↓
SHA-256 hashes
  ↓
RLS / policy metadata
  ↓
Selected row counts
  ↓
Restore dry-run
  ↓
Pre-flight validation
  ↓
Controlled globals restore
  ↓
Database restore
  ↓
Manifest comparison
  ↓
Application connectivity check
  ↓
RESTORE VALIDATION SUCCESSFUL
```

The objective is not merely to create database dump files. The objective is to provide a repeatable and verifiable PostgreSQL recovery procedure.
