"""Real PostgreSQL regression tests; only a new, isolated tmpfs fixture is modified."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("snapshot", HERE / "postgres-backup-snapshot.py")
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class SnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = "solo-snapshot-test-" + uuid.uuid4().hex[:10]
        cls.workspace = tempfile.TemporaryDirectory(prefix="solo-snapshot-test-")
        image = snapshot.command(["docker", "inspect", "solo-postgres", "--format", "{{.Image}}"])
        snapshot.command(["docker", "run", "-d", "--pull=never", "--name", cls.container, "--network", "none",
                          "--tmpfs", "/var/lib/postgresql/data:rw,size=1073741824",
                          "--health-cmd", "pg_isready -U solo -d solo", "--health-interval", "1s", "--health-retries", "30",
                          "-e", "POSTGRES_DB=solo", "-e", "POSTGRES_USER=solo", "-e", "POSTGRES_HOST_AUTH_METHOD=trust", image])
        try:
            for _ in range(60):
                if snapshot.command(["docker", "inspect", cls.container, "--format", "{{.State.Health.Status}}"], 10) == "healthy": break
                time.sleep(.5)
            else: raise RuntimeError("Fixture did not become healthy")
            cls.sql("""CREATE TABLE schema_migrations(id text PRIMARY KEY,applied_at timestamptz NOT NULL);
                INSERT INTO schema_migrations VALUES ('snapshot-test',now());
                CREATE TABLE stories(id integer PRIMARY KEY);
                CREATE TABLE chapters(id integer PRIMARY KEY,story_id integer REFERENCES stories(id));
                CREATE TABLE scenes(id integer PRIMARY KEY,chapter_id integer REFERENCES chapters(id),body text NOT NULL CHECK(length(body)>0));
                CREATE INDEX scenes_chapter_idx ON scenes(chapter_id);
                INSERT INTO stories VALUES(1); INSERT INTO chapters VALUES(1,1); INSERT INTO scenes VALUES(1,1,'fixture');
                CREATE TABLE llm_generations(id integer PRIMARY KEY);
                INSERT INTO llm_generations SELECT generate_series(1,680)""")
        except BaseException:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        snapshot.command(["docker", "rm", "-f", cls.container], 30)
        cls.workspace.cleanup()

    @classmethod
    def sql(cls, query, database="solo"):
        return snapshot.command(["docker", "exec", cls.container, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "solo", "-d", database, "-c", query], 30)

    def setUp(self):
        self.sql("TRUNCATE llm_generations; INSERT INTO llm_generations SELECT generate_series(1,680)")

    def assertNoHolder(self):
        self.assertEqual(self.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'solo-backup-snapshot-%'"), "0")

    def test_01_original_race_and_shared_snapshot(self):
        before = int(self.sql("SELECT count(*) FROM llm_generations"))
        self.sql("INSERT INTO llm_generations VALUES(681)")
        snapshot.command(["docker", "exec", self.container, "pg_dump", "-U", "solo", "-d", "solo", "-Fc", "-f", "/tmp/old.dump"])
        self.sql("CREATE DATABASE old_restore")
        snapshot.command(["docker", "exec", self.container, "pg_restore", "-U", "solo", "-d", "old_restore", "--single-transaction", "--no-owner", "--no-privileges", "/tmp/old.dump"])
        actual = int(self.sql("SELECT count(*) FROM llm_generations", "old_restore"))
        self.assertEqual((before, actual), (680, 681))
        print("ORIGINAL_RACE: reproduced Count mismatch: llm_generations (680 != 681)", flush=True)
        original_inventory = snapshot.inventory
        def interleaved(holder):
            result = original_inventory(holder)
            self.sql("INSERT INTO llm_generations VALUES(682)")
            return result
        with patch.object(snapshot, "inventory", side_effect=interleaved):
            expected = snapshot.capture(self.container, "/tmp/shared.dump", 30)
        self.sql("CREATE DATABASE shared_restore")
        snapshot.command(["docker", "exec", self.container, "pg_restore", "-U", "solo", "-d", "shared_restore", "--single-transaction", "--no-owner", "--no-privileges", "/tmp/shared.dump"])
        self.assertEqual(self.sql("SELECT count(*),max(id) FROM llm_generations", "shared_restore"), "681|681")
        self.assertEqual(next(t["sourceRows"] for t in expected["tables"] if t["name"] == "llm_generations"), 681)
        self.assertEqual(self.sql("SELECT count(*) FROM llm_generations"), "682")
        self.assertEqual(self.sql("SELECT count(*) FROM pg_constraint WHERE connamespace='public'::regnamespace AND NOT convalidated", "shared_restore"), "0")
        self.assertNoHolder()

    def test_02_complete_script_with_concurrent_writes(self):
        stop = threading.Event(); errors = []
        def writer():
            try:
                while not stop.is_set():
                    self.sql("INSERT INTO llm_generations SELECT coalesce(max(id),0)+1 FROM llm_generations")
                    stop.wait(.05)
            except BaseException as exc: errors.append(exc)
        thread = threading.Thread(target=writer); thread.start()
        root = Path(self.workspace.name) / "success"
        try:
            result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(HERE / "backup-local-ai.ps1"),
                                     "-SourceContainer", self.container, "-BackupRoot", str(root), "-SoloRepo", str(HERE.parent), "-PreserveExistingBackups"], capture_output=True, text=True, timeout=240)
        finally:
            stop.set(); thread.join(timeout=30)
        self.assertFalse(errors)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FINAL_VERDICT=PASS", result.stdout)
        manifest = json.loads(next((root / "manifests").glob("solo-20*.json")).read_text(encoding="utf-8-sig"))
        self.assertEqual(manifest["status"], "PASS")
        self.assertEqual(manifest["validation"], {"dump":"PASS", "restore":"PASS"})
        self.assertEqual(manifest["restoreVerification"]["tableCount"], 5)
        self.assertNotIn("sqliteSnapshot", manifest)
        self.assertFalse((root / "solo-sqlite").exists())
        self.assertGreater(int(self.sql("SELECT count(*) FROM llm_generations")), next(t["sourceRows"] for t in manifest["sourceSnapshot"]["tables"] if t["name"] == "llm_generations"))
        self.assertNoHolder()
        print("COMPLETE_SCRIPT: PASS; exact schema/constraints/indexes/counts; under concurrent writes", flush=True)

    def test_03_holder_dies_after_successful_dump(self):
        real_command = snapshot.command
        def interrupted(args, timeout=300):
            result = real_command(args, timeout)
            if "pg_dump" in args:
                self.sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name LIKE 'solo-backup-snapshot-%' AND application_name NOT LIKE '%-dump'")
            return result
        with patch.object(snapshot, "command", side_effect=interrupted):
            with self.assertRaisesRegex(RuntimeError, "Snapshot holder"):
                snapshot.capture(self.container, "/tmp/interrupted.dump", 30)
        self.assertNoHolder()

    def test_04_dump_failure(self):
        with self.assertRaises(RuntimeError):
            snapshot.capture(self.container, "/nonexistent-directory/fail.dump", 30)
        self.assertNoHolder()

    def test_05_holder_timeout(self):
        with snapshot.SnapshotHolder(self.container, 1) as holder:
            with self.assertRaisesRegex(RuntimeError, "timed out|failed"):
                holder.query("SELECT pg_sleep(5)")
        self.assertNoHolder()

    def test_06_command_timeout(self):
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            snapshot.command([sys.executable, "-c", "import time; time.sleep(10)"], 1)

    def test_07_holder_failure_manifest(self):
        root = Path(self.workspace.name) / "holder-failure"
        process = subprocess.Popen(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(HERE / "backup-local-ai.ps1"),
                                    "-SourceContainer", self.container, "-BackupRoot", str(root), "-SoloRepo", str(HERE.parent), "-PreserveExistingBackups"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        killed = False
        try:
            for _ in range(100):
                ids = self.sql("SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'solo-backup-snapshot-%' AND application_name NOT LIKE '%-dump'")
                if ids:
                    for pid in ids.splitlines(): self.sql("SELECT pg_terminate_backend(" + str(int(pid)) + ")")
                    killed = True; break
                if process.poll() is not None: break
                time.sleep(.02)
            stdout, stderr = process.communicate(timeout=120)
        finally:
            if process.poll() is None: process.kill(); process.wait()
        self.assertTrue(killed, stdout + stderr)
        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn("FINAL_VERDICT=PASS", stdout)
        manifest = json.loads(next((root / "manifests").glob("solo-20*.json")).read_text(encoding="utf-8-sig"))
        self.assertEqual(manifest["status"], "FAIL")
        self.assertEqual(manifest["validation"]["dump"], "FAIL")
        self.assertNoHolder()
        print("HOLDER_FAILURE_MANIFEST: FAIL as required; no false PASS", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
