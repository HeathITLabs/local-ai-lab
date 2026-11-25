"""Exercise the actual scheduled wrapper and backup script with deterministic subprocess fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
SCRIPTS = Path(os.environ.get('BACKUP_TEST_SCRIPTS', str(HERE)))
HELPER = r'''
import json, os, pathlib, sys, subprocess
root=pathlib.Path(os.environ['BACKUP_FIXTURE_ROOT'])
a=sys.argv[1:]
def emit(x): print(json.dumps(x))
if a[0] in ('snapshot','inspect'):
    print('FIXTURE_CHILD_STDERR',file=sys.stderr)
    emit({'postgresVersion':'fixture','schemaVersion':None,'tables':[{'name':n,'sourceRows':1,'schema':{}} for n in ('stories','chapters','scenes')]})
else:
    a=a[a.index('--')+2:]
    with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(a)+'\n')
    if a[0].endswith('.py'): sys.exit(subprocess.call([sys.executable]+a))
    elif a[0]=='info': print('fixture')
    elif a[0]=='inspect': print('true|healthy' if 'State.Running' in a[2] else 'fixture-image')
    elif a[0]=='run': print('fixture-validator')
    elif a[0]=='cp' and not a[1].endswith('.dump'): pass
    elif a[0]=='cp' and ':/' in a[1]: pathlib.Path(a[2]).write_bytes(b'fixture dump')
    elif a[0]=='exec' and 'pg_isready' in a:
        p=root/'attempts'; n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n))
        if n<=int(os.environ.get('BACKUP_FIXTURE_FAILURES','0')):
            print('pg_isready exit 2: no response',file=sys.stderr); sys.exit(2)
'''

@unittest.skipUnless('postgres-backup-snapshot.py' in (SCRIPTS/'backup-local-ai.ps1').read_text(),
                     'Requires the diagnosed snapshot-based backup implementation')
class WrapperTests(unittest.TestCase):
    def run_fixture(self, failures):
        with tempfile.TemporaryDirectory(prefix='backup wrapper test ') as tmp:
            root=Path(tmp); scripts=root/'scripts'; scripts.mkdir()
            for name in ('run-scheduled-backup.ps1','backup-local-ai.ps1'):
                shutil.copyfile(SCRIPTS/name,scripts/name)
            (scripts/'postgres-backup-snapshot.py').write_text(HELPER)
            env=dict(os.environ,BACKUP_FIXTURE_ROOT=tmp,BACKUP_FIXTURE_FAILURES=str(failures))
            backup=root/'backups'
            process=subprocess.Popen(['powershell.exe','-NoProfile','-File',str(scripts/'run-scheduled-backup.ps1'),'-BackupRoot',str(backup),'-PreserveExistingBackups'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
            deadline=time.monotonic()+100
            try:
                while process.poll() is None:
                    if time.monotonic()>deadline: raise TimeoutError('Wrapper fixture exceeded bound')
                    for record in (backup/'manifests').glob('solo-20*.json'):
                        try: content=record.read_text(encoding='utf-8-sig')
                        except (PermissionError,FileNotFoundError): continue # Windows atomic replace in progress; retry next poll.
                        if content: json.loads(content) # Readers must never see partially serialized JSON.
                    time.sleep(.01)
                stdout,stderr=process.communicate(timeout=5)
            finally:
                if process.poll() is None: process.kill(); process.wait()
            result=subprocess.CompletedProcess(process.args,process.returncode,stdout,stderr)
            logs='\n'.join(p.read_text(encoding='utf-8-sig') for p in (backup/'logs').glob('*.log'))
            records=list((backup/'manifests').glob('solo-20*.json'))
            self.assertEqual(len(records),1,logs+result.stderr)
            manifest=json.loads(records[0].read_text(encoding='utf-8-sig'))
            self.assertFalse(list((backup/'manifests').glob('*.pending')))
            self.assertIn('FIXTURE_CHILD_STDERR',logs)
            calls=[json.loads(s) for s in (root/'calls.jsonl').read_text().splitlines()]
            self.assertTrue(any(a[:1]==['rm'] for a in calls),'validator cleanup missing')
            self.assertTrue(any('rm' in a and a[0]=='exec' for a in calls),'source temp cleanup missing')
            expected=min(failures+1,40)
            self.assertEqual(int((root/'attempts').read_text()),expected)
            if failures>=40:
                self.assertNotEqual(result.returncode,0,logs)
                self.assertEqual(manifest['status'],'FAIL')
                self.assertEqual(manifest['validation'],dict(dump='PASS',restore='FAIL'))
                self.assertIn('Validation database not ready',manifest['error'])
            else:
                self.assertEqual(result.returncode,0,logs+result.stderr)
                self.assertEqual(manifest['status'],'PASS',logs)
            if failures: self.assertIn('pg_isready exit 2: no response',logs)
    def test_success_with_stderr(self): self.run_fixture(0)
    def test_transient_exit_2_recovery(self): self.run_fixture(1)
    def test_persistent_failure_bounded(self): self.run_fixture(40)
    def test_child_exit_code_and_large_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); shutil.copyfile(SCRIPTS/'run-scheduled-backup.ps1',root/'run-scheduled-backup.ps1')
            (root/'backup-local-ai.ps1').write_text("param($Backup,$BackupRoot)\ntry { [Console]::Error.WriteLine(('diagnostic'*20000)); Write-Output 'RETRY_REACHED'; exit 7 } finally { Write-Output 'FINALIZATION_REACHED' }")
            result=subprocess.run(['powershell.exe','-NoProfile','-File',str(root/'run-scheduled-backup.ps1'),'-BackupRoot',str(root/'backup')],capture_output=True,text=True,timeout=20)
            self.assertEqual(result.returncode,7)
            log=next((root/'backup/logs').glob('*.log')).read_text(encoding='utf-8-sig')
            self.assertIn('RETRY_REACHED',log); self.assertIn('FINALIZATION_REACHED',log)
            self.assertIn('diagnostic'*20000,log)

if __name__=='__main__': unittest.main(verbosity=2)
