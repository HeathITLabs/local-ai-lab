"""Snapshot-consistent PostgreSQL backup inventory. No application data is written."""
import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
import uuid


def command(args, timeout=300):
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                               creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
    try:
        stdout, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        else:
            process.kill()
        process.communicate(timeout=10)
        raise RuntimeError("Command timed out: " + os.path.basename(args[0])) from None
    if process.returncode:
        # Do not echo command arguments or database output (which can contain private data).
        raise RuntimeError("Command failed: " + os.path.basename(args[0]) + " (exit " + str(process.returncode) + ")")
    return stdout.strip()



class SnapshotHolder:
    def __init__(self, container, timeout=300):
        self.container, self.timeout = container, timeout
        self.app = "solo-backup-snapshot-" + uuid.uuid4().hex
        self.dump_app = self.app + "-dump"
        self.process = None
        self.lines = queue.Queue()

    def __enter__(self):
        options = "-c statement_timeout=" + str(self.timeout * 1000) + " -c lock_timeout=10000 -c idle_in_transaction_session_timeout=" + str((self.timeout * 2 + 60) * 1000)
        self.process = subprocess.Popen(
            ["docker", "exec", "-i", "-e", "PGAPPNAME=" + self.app, "-e", "PGCONNECT_TIMEOUT=10",
             "-e", "PGOPTIONS=" + options, self.container, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "solo", "-d", "solo"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8", bufsize=1)
        def read_lines():
            try:
                for line in self.process.stdout:
                    self.lines.put(line.rstrip("\r\n"))
            finally:
                self.lines.put(None)
        self.reader = threading.Thread(target=read_lines, daemon=True)
        self.reader.start()
        try:
            self.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SELECT 'ready'")
            return self
        except BaseException:
            self.close()
            raise

    def query(self, sql):
        if self.process.poll() is not None:
            raise RuntimeError("Snapshot holder exited")
        marker = "end-" + uuid.uuid4().hex
        try:
            self.process.stdin.write(sql + ";\nSELECT '" + marker + "';\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            raise RuntimeError("Snapshot holder disconnected") from None
        rows = []
        while True:
            try:
                line = self.lines.get(timeout=self.timeout)
            except queue.Empty:
                raise RuntimeError("Snapshot holder query timed out") from None
            if line is None:
                raise RuntimeError("Snapshot holder failed before query completed")
            if line == marker:
                return rows
            rows.append(line)

    def terminate_owned_sessions(self):
        sql = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name IN ('" + self.app + "','" + self.dump_app + "') AND pid <> pg_backend_pid()"
        command(["docker", "exec", self.container, "timeout", "15", "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "solo", "-d", "solo", "-c", sql], 20)

    def close(self):
        if self.process is None:
            return
        cleanup_error = None
        try:
            if self.process.poll() is None:
                try:
                    self.process.stdin.write("ROLLBACK;\n\\q\n")
                    self.process.stdin.flush()
                    self.process.stdin.close()
                    self.process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    self.terminate_owned_sessions()
                    self.process.kill()
                    self.process.wait(timeout=5)
            # Also cancel a dump left behind if the Docker client disconnected.
            self.terminate_owned_sessions()
        except Exception as exc:
            cleanup_error = exc
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=5)
            try:
                self.process.stdin.close()
            except OSError:
                pass
            self.process.stdout.close()
            self.reader.join(timeout=2)
        if cleanup_error:
            raise RuntimeError("Snapshot session cleanup failed; server-side timeouts remain active") from cleanup_error

    def __exit__(self, *_):
        self.close()


def scalar(holder, sql):
    rows = holder.query(sql)
    if len(rows) != 1:
        raise RuntimeError("Expected one metadata result")
    return rows[0]


def inventory(holder):
    names = holder.query("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
    if not names:
        raise RuntimeError("No public tables")
    if any(not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", n) for n in names):
        raise RuntimeError("Unexpected table identifier")
    # Retain schema locks through the dump; normal inserts/updates/deletes remain allowed.
    holder.query("LOCK TABLE " + ",".join('public."' + n + '"' for n in names) + " IN ACCESS SHARE MODE; SELECT 'locked'")
    metadata = {"postgresVersion": scalar(holder, "SHOW server_version"), "schemaVersion": None, "tables": []}
    if "schema_migrations" in names:
        rows = holder.query("SELECT id FROM schema_migrations ORDER BY applied_at DESC LIMIT 1")
        metadata["schemaVersion"] = rows[0] if rows else None
    for name in names:
        schema = json.loads(scalar(holder, """SELECT json_build_object(
          'columns', (SELECT coalesce(json_agg(json_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),
            'notNull',a.attnotnull,'default',pg_get_expr(d.adbin,d.adrelid),'identity',a.attidentity,'generated',a.attgenerated)
            ORDER BY a.attnum),'[]'::json) FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
            WHERE a.attrelid='public.\"%s\"'::regclass AND a.attnum>0 AND NOT a.attisdropped),
          'constraints', (SELECT coalesce(json_agg(json_build_object('name',conname,'definition',pg_get_constraintdef(oid),
            'validated',convalidated,'deferrable',condeferrable,'deferred',condeferred) ORDER BY conname),'[]'::json)
            FROM pg_constraint WHERE conrelid='public.\"%s\"'::regclass),
          'indexes', (SELECT coalesce(json_agg(json_build_object('name',indexname,'definition',indexdef) ORDER BY indexname),'[]'::json)
            FROM pg_indexes WHERE schemaname='public' AND tablename='%s'))::text""" % (name, name, name)))
        metadata["tables"].append({"name": name, "sourceRows": int(scalar(holder, 'SELECT count(*) FROM public."' + name + '"')), "schema": schema})
    return metadata


def capture(container, dump_path, timeout=300):
    with SnapshotHolder(container, timeout) as holder:
        snapshot = scalar(holder, "SELECT pg_export_snapshot()")
        fingerprint = scalar(holder, "SELECT pg_current_snapshot()::text")
        metadata = inventory(holder)
        command(["docker", "exec", "-e", "PGAPPNAME=" + holder.dump_app, "-e", "PGCONNECT_TIMEOUT=10",
                 "-e", "PGOPTIONS=-c statement_timeout=" + str(timeout * 1000), container, "timeout", "-s", "TERM", str(timeout),
                 "pg_dump", "-U", "solo", "-d", "solo", "-Fc", "--lock-wait-timeout=10000", "--snapshot=" + snapshot, "-f", dump_path], timeout + 15)
        # Fail closed if the holder died, even if pg_dump already imported its snapshot.
        if scalar(holder, "SELECT pg_current_snapshot()::text") != fingerprint:
            raise RuntimeError("Snapshot holder transaction changed")
        holder.query("COMMIT; SELECT 'committed'")
        metadata["snapshotId"] = snapshot
        metadata["snapshotFingerprint"] = fingerprint
        return metadata


def inspect(container, timeout=300):
    with SnapshotHolder(container, timeout) as holder:
        metadata = inventory(holder)
        holder.query("COMMIT; SELECT 'committed'")
        return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["snapshot", "inspect", "command"])
    parser.add_argument("--container", default="solo-postgres")
    parser.add_argument("--dump")
    parser.add_argument("--timeout", type=int, default=300)
    args, remaining = parser.parse_known_args()
    if args.timeout < 1:
        raise ValueError("Timeout must be positive")
    if args.mode == "command":
        if remaining and remaining[0] == "--": remaining = remaining[1:]
        if not remaining: raise ValueError("Missing command")
        output = command(remaining, args.timeout)
        if output: print(output)
    elif args.mode == "snapshot":
        if remaining or not args.dump: raise ValueError("Missing dump path or unexpected arguments")
        print(json.dumps(capture(args.container, args.dump, args.timeout)))
    else:
        if remaining: raise ValueError("Unexpected arguments")
        print(json.dumps(inspect(args.container, args.timeout)))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("SNAPSHOT_BACKUP_ERROR=" + str(exc), file=sys.stderr)
        sys.exit(1)
