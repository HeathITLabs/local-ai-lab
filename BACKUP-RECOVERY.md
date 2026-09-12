# Solo backup and recovery on the portable AI drive

The AI drive contains sibling directories: AI/solo, AI/local-ai-lab, AI/solo-data, and AI/backups/local-ai-lab. The current Windows drive letter is irrelevant to Compose and operational scripts. Compose resolves Solo's relative build context and host mounts from AI/local-ai-lab. Container paths do not change.

PostgreSQL in solo-postgres is Solo's canonical runtime database. Run a manual checkpoint from AI/local-ai-lab:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\backup-local-ai.ps1 -Backup Solo

The script locates the AI drive from its own directory. LOCAL_AI_BACKUP_ROOT and SOLO_REPO_ROOT are optional escape hatches. It writes a PostgreSQL custom-format dump, restores it to a disposable validator, verifies table counts, then exports every public table from that validator into a separate archival SQLite snapshot. The JSON manifest and SQLite metadata record source types, counts, keys, foreign keys, indexes, conversion notes, and verification. An archive is published as PASS only when all public tables copy and PRAGMA integrity_check returns ok. Verified dumps are retained for seven days.

Normal recovery is PostgreSQL dump -> pg_restore -> Solo. The restore script validates the selected dump and makes a safety checkpoint before replacing the live database. A Solo SQLite runtime database is distinct from the portable Solo archival SQLite snapshot. The archive is for inspection and future PostgreSQL reconstruction and must never be used directly as Solo's runtime database. Automated reconstruction is not implemented.

The launcher performs backup -> restore validation -> pull/build -> start when an existing Solo PostgreSQL container exists. An existing named database volume without a container blocks startup. FIRST_RUN_NO_DATABASE means neither is present.

The scheduled task is machine setup. It stores an absolute path to this drive's current letter and cannot follow a letter change automatically. After moving the drive to another Windows workstation, install Docker Desktop and other workstation prerequisites, run local-ai-lab setup/bootstrap, then run:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-backup-task.ps1

This creates or replaces the four-hour task named Solo PostgreSQL Backup using the current absolute script path. Run it once on each new workstation, then start the stack. Backup data itself stays on the portable AI drive. Task logs go under AI/backups/local-ai-lab/logs; its command line contains no credentials.
