# Solo backup and recovery on the portable AI drive

The AI drive contains sibling directories: AI/solo, AI/local-ai-lab, AI/solo-data, and AI/backups/local-ai-lab. The current Windows drive letter is irrelevant to Compose and operational scripts. Compose resolves Solo's relative build context and host mounts from AI/local-ai-lab. Container paths do not change.

PostgreSQL in solo-postgres is Solo's canonical runtime database. Run a manual checkpoint from AI/local-ai-lab:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\backup-local-ai.ps1 -Backup Solo

The script locates the AI drive from its own directory. LOCAL_AI_BACKUP_ROOT and SOLO_REPO_ROOT are optional escape hatches. It writes a PostgreSQL custom-format dump, restores it to a disposable validator, and verifies the table set, schema, constraints, indexes, schema version and row counts. The JSON manifest records the source snapshot and that verification; a backup is PASS only when the dump and its restore check both pass. Verified dumps are retained for seven days.

Recovery is PostgreSQL dump -> pg_restore -> Solo. The restore script validates the selected dump and makes a safety checkpoint before replacing the live database. Solo is PostgreSQL-only (solo#20); backups no longer write a SQLite snapshot. Snapshots made before 2026-11-25 remain in the solo-sqlite folder and are not read by anything.

The launcher performs backup -> restore validation -> pull/build -> start when an existing Solo PostgreSQL container exists. An existing named database volume without a container blocks startup. FIRST_RUN_NO_DATABASE means neither is present.

The scheduled task is machine setup. It stores an absolute path to this drive's current letter and cannot follow a letter change automatically. After moving the drive to another Windows workstation, install Docker Desktop and other workstation prerequisites, run local-ai-lab setup/bootstrap, then run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-backup-task.ps1

This creates or replaces the four-hour task named Solo PostgreSQL Backup using the current absolute script path. Run it once on each new workstation, then start the stack. Backup data itself stays on the portable AI drive. Task logs go under AI/backups/local-ai-lab/logs; its command line contains no credentials.

## Snapshot-consistent validation

`backup-local-ai.ps1` requires Python and uses `scripts/postgres-backup-snapshot.py` to keep one PostgreSQL `REPEATABLE READ, READ ONLY` transaction open. It exports a snapshot, inventories public tables, column definitions, constraints, indexes, schema migration version and exact row counts within that transaction, then runs `pg_dump --snapshot=<id>`. The holder remains open through dump completion; loss of that holder fails the backup even if the dump command succeeded. Source table schema locks permit ordinary writes while preventing concurrent schema changes.

The dump is restored with `--single-transaction --exit-on-error` into a network-isolated temporary container. Exact table sets, column/schema definitions, constraints, indexes, schema version and all row counts must match the source snapshot. `sourceSnapshot` and `restoreVerification` in new manifests retain this evidence alongside the existing manifest fields. PASS is printed only after all checks and cleanup succeed.

Commands have bounded timeouts (default 300 seconds per command, configurable with `-CommandTimeoutSeconds`); holder queries also have server-side statement, lock and idle transaction timeouts. Cleanup cancels only sessions bearing the run's unique application names and removes its validator. Production containers are never restarted by the backup operation. Validator database storage is temporary memory, capped at 1 GiB; larger databases require increasing that validation capacity.

Normal seven-day retention remains unchanged. Use `-PreserveExistingBackups` to skip pruning for an individual validation run. `-SourceContainer` selects an isolated fixture for tests and defaults to `solo-postgres`; the dump folder remains `solo-postgres`. Do not use the production restore script for validation-only work: it deliberately proceeds to replace the live database.

Run the focused integration suite with:

    python .\scripts\test-postgres-backup-snapshot.py

It creates its own network-isolated temporary PostgreSQL fixture, reproduces the original count race, tests snapshot-consistent dumping and the complete backup pipeline under concurrent writes, and checks holder loss, dump errors and timeout failures. It does not write production data.
