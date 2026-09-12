"""Portable, read-only PostgreSQL to SQLite archival snapshot."""
import argparse
import datetime as dt
import decimal
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

def pg(sql, container, database):
    result = subprocess.run(
        ["docker", "exec", container, "psql", "-X", "-q", "-t", "-A",
         "-v", "ON_ERROR_STOP=1", "-U", "solo", "-d", database, "-c", sql],
        capture_output=True, text=True, encoding="utf-8", check=True)
    return result.stdout.splitlines()

def pg_rows(sql, container, database):
    process = subprocess.Popen(
        ["docker", "exec", container, "psql", "-X", "-q", "-t", "-A",
         "-v", "ON_ERROR_STOP=1", "-U", "solo", "-d", database, "-c", sql],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8")
    try:
        for line in process.stdout:
            yield line.rstrip("\r\n")
        error = process.stderr.read()
        if process.wait() != 0:
            raise RuntimeError("PostgreSQL row export failed: " + error.strip())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
def jload(value):
    return json.loads(value, parse_float=decimal.Decimal)

def quote(name):
    return '"' + name.replace('"', '""') + '"'

def sql_lit(value):
    return "'" + value.replace("'", "''") + "'"

def affinity(column):
    typ = column["type_name"]
    source = column["source_type"].lower()
    if typ in ("int2", "int4", "int8", "bool"):
        return "INTEGER", ""
    if typ in ("float4", "float8"):
        return "REAL", ""
    if typ == "bytea":
        return "BLOB", "PostgreSQL hex bytea decoded to bytes"
    if typ == "numeric":
        return "TEXT", "Exact decimal representation"
    if typ in ("json", "jsonb"):
        return "TEXT", "Canonical JSON"
    if source.endswith("[]"):
        return "TEXT", "Canonical JSON array"
    if typ in ("text", "varchar", "bpchar", "uuid", "date", "timestamp", "timestamptz", "time", "timetz"):
        return "TEXT", ""
    if column["type_kind"] == "e":
        return "TEXT", "PostgreSQL enum label"
    return "TEXT", "Unsupported source type: canonical PostgreSQL JSON text"

def canonical_json(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, decimal.Decimal):
        return str(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return json.dumps(value, allow_nan=False)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ",".join(canonical_json(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(key, ensure_ascii=False) + ":" +
                              canonical_json(value[key]) for key in sorted(value)) + "}"
    raise TypeError("Unsupported JSON value: " + type(value).__name__)
def convert(value, column):
    if value is None:
        return None
    typ = column["type_name"]
    if typ == "bytea":
        if not isinstance(value, str) or not value.startswith("\\x"):
            raise ValueError("Unexpected bytea encoding")
        return bytes.fromhex(value[2:])
    if typ == "bool":
        return int(value)
    if typ in ("int2", "int4", "int8"):
        v = int(value)
        if not -(2**63) <= v < 2**63:
            raise ValueError("Integer outside SQLite range")
        return v
    if typ == "numeric":
        return str(value)
    if typ in ("float4", "float8"):
        return float(value)
    if typ in ("json", "jsonb") or column["source_type"].endswith("[]"):
        return canonical_json(value)
    if isinstance(value, (dict, list)):
        return canonical_json(value)
    return str(value)

def run(args):
    target = Path(args.output)
    if target.exists():
        raise ValueError("Refusing to overwrite existing archive")
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + ".partial")
    if partial.exists():
        raise ValueError("Existing partial archive needs inspection")
    created = dt.datetime.now(dt.timezone.utc).isoformat()
    version = pg("SHOW server_version", args.container, args.database)[0]
    names = pg("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename",
               args.container, args.database)
    manifest = {"formatVersion": 1, "createdAt": created, "sourceProvider": "postgres",
                "postgresVersion": version, "soloGitSha": args.git_sha, "tables": [],
                "status": "INCOMPLETE", "integrityCheck": None}
    db = sqlite3.connect(partial)
    try:
        db.execute("CREATE TABLE _archive_manifest (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execute("CREATE TABLE _archive_tables (table_name TEXT PRIMARY KEY, source_rows INTEGER, archive_rows INTEGER, status TEXT, foreign_keys TEXT, indexes TEXT, error TEXT)")
        db.execute("CREATE TABLE _archive_columns (table_name TEXT, ordinal INTEGER, column_name TEXT, source_type TEXT, archive_type TEXT, nullable INTEGER, primary_key_ordinal INTEGER, conversion_note TEXT, PRIMARY KEY(table_name, ordinal))")
        for name in names:
            record = {"name": name, "status": "FAILED", "sourceRows": None,
                      "archiveRows": None, "columns": [], "foreignKeys": [], "indexes": []}
            manifest["tables"].append(record)
            try:
                name_q = sql_lit(name)
                columns_sql = """SELECT json_agg(json_build_object(
                    'ordinal', a.attnum, 'name', a.attname,
                    'source_type', format_type(a.atttypid,a.atttypmod),
                    'type_name', t.typname, 'type_kind', t.typtype,
                    'nullable', NOT a.attnotnull,
                    'pk_ordinal', COALESCE(array_position(pk.conkey,a.attnum),0))
                    ORDER BY a.attnum)::text
                    FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
                    JOIN pg_namespace n ON n.oid=c.relnamespace
                    JOIN pg_type t ON t.oid=a.atttypid
                    LEFT JOIN pg_constraint pk ON pk.conrelid=c.oid AND pk.contype='p'
                    WHERE n.nspname='public' AND c.relname=%s
                      AND a.attnum>0 AND NOT a.attisdropped""" % name_q
                columns = jload(pg(columns_sql, args.container, args.database)[0])
                constraints_sql = """SELECT COALESCE(json_agg(pg_get_constraintdef(oid))::text,'[]')
                    FROM pg_constraint WHERE conrelid=%s::regclass AND contype='f'""" % sql_lit("public." + quote(name))
                indexes_sql = """SELECT COALESCE(json_agg(indexdef)::text,'[]')
                    FROM pg_indexes WHERE schemaname='public' AND tablename=%s""" % name_q
                record["foreignKeys"] = jload(pg(constraints_sql, args.container, args.database)[0])
                record["indexes"] = jload(pg(indexes_sql, args.container, args.database)[0])
                source_count = int(pg("SELECT count(*) FROM public." + quote(name),
                                      args.container, args.database)[0])
                record["sourceRows"] = source_count
                specs = []
                for col in columns:
                    kind, note = affinity(col)
                    col["archive_type"], col["conversion_note"] = kind, note
                    record["columns"].append(col)
                    specs.append(quote(col["name"]) + " " + kind)
                    db.execute("INSERT INTO _archive_columns VALUES (?,?,?,?,?,?,?,?)",
                               (name, col["ordinal"], col["name"], col["source_type"],
                                kind, int(col["nullable"]), col["pk_ordinal"], note))
                db.execute("CREATE TABLE " + quote(name) + " (" + ",".join(specs) + ")")
                insert = ("INSERT INTO " + quote(name) + " VALUES (" +
                          ",".join("?" for _ in columns) + ")")
                for line in pg_rows("SELECT row_to_json(t)::text FROM public." + quote(name) + " t",
                               args.container, args.database):
                    row = jload(line)
                    db.execute(insert, [convert(row[col["name"]], col) for col in columns])
                archive_count = db.execute("SELECT count(*) FROM " + quote(name)).fetchone()[0]
                source_after = int(pg("SELECT count(*) FROM public." + quote(name),
                                      args.container, args.database)[0])
                record["archiveRows"] = archive_count
                if source_count != archive_count or source_after != archive_count:
                    raise ValueError("Source/archive row count changed or mismatched")
                record["status"] = "COPIED"
            except Exception as exc:
                record["error"] = str(exc)
            db.execute("INSERT INTO _archive_tables VALUES (?,?,?,?,?,?,?)",
                       (name, record["sourceRows"], record["archiveRows"], record["status"],
                        json.dumps(record["foreignKeys"]), json.dumps(record["indexes"]),
                        record.get("error")))
        manifest["integrityCheck"] = db.execute("PRAGMA integrity_check").fetchone()[0]
        manifest["status"] = ("PASS" if manifest["integrityCheck"] == "ok" and
                              all(t["status"] == "COPIED" for t in manifest["tables"]) else "INCOMPLETE")
        for key, value in (("formatVersion", 1), ("createdAt", created), ("sourceProvider", "postgres"),
                           ("postgresVersion", version), ("soloGitSha", args.git_sha),
                           ("status", manifest["status"]), ("integrityCheck", manifest["integrityCheck"])):
            db.execute("INSERT INTO _archive_manifest VALUES (?,?)", (key, str(value)))
        db.commit()
    finally:
        db.close()
    with open(args.manifest, "w", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2, ensure_ascii=False, default=str)
    if manifest["status"] == "PASS":
        partial.rename(target)
    return 0 if manifest["status"] == "PASS" else 1

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--container", default="solo-postgres")
    parser.add_argument("--database", default="solo")
    parser.add_argument("--git-sha", default="")
    options = parser.parse_args()
    try:
        sys.exit(run(options))
    except Exception as error:
        print("ARCHIVE_FAILED=" + str(error), file=sys.stderr)
        sys.exit(1)
