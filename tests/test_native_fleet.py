import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT/'scripts/cc-fleet'


class NativeFleetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='native-fleet-')
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root/'repo with spaces'
        self.repo.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fleet Test')
        self.git('config', 'user.email', 'fleet@example.invalid')
        (self.repo/'base.txt').write_text('baseline')
        self.git('add', '.')
        self.git('commit', '-m', 'baseline')
        self.base = self.git('rev-parse', 'HEAD')
        # If an old backend or terminal launcher is accidentally invoked, record
        # a side effect and fail. All actual isolation below uses temporary Git.
        self.trap = self.root/'unexpected-backend'
        self.trap.write_text('#!/bin/sh\necho called >> "'+str(self.root/'backend-calls')+'"\nexit 99\n')
        self.trap.chmod(0o755)
        self.env = dict(os.environ, CODEX_APP_CALL_BIN=str(self.trap), CLAUDE_CLI_PATH=str(self.trap),
            CC_FLEET_PANEL_REGISTER_BIN=str(self.trap), CC_FLEET_PANEL_OPEN_BIN=str(self.trap))
        self.task = self.root/'task.md'
        self.task.write_text('Deliver actual workflow, including branch case and final artifact.')
        f = self.cli('init', '--cwd', self.repo, '--owner-id', 'main-123')
        self.c = Path(f['coord'])
        self.fleet = f
        self.rq = f['rq']
        self.cjson = lambda value: self.c/value

    def tearDown(self):
        self.assertFalse((self.root/'backend-calls').exists(), 'native operation called legacy backend/panel')
        shutil.rmtree(Path(self.fleet['inboxRoot']), ignore_errors=True)
        self.tmp.cleanup()

    def git(self, *args, cwd=None):
        return subprocess.check_output(['git', '-C', str(cwd or self.repo), *map(str,args)], text=True, stderr=subprocess.DEVNULL).strip()

    def cli(self, *args, expect=0):
        r = subprocess.run([str(BIN), *map(str,args)], env=self.env, text=True, capture_output=True)
        self.assertEqual(r.returncode, expect, r.stderr+r.stdout)
        if r.stdout:
            return json.loads(r.stdout)
        if r.stderr:
            try:
                return json.loads(r.stderr)
            except json.JSONDecodeError:
                return {'error': r.stderr}
        return None

    def cmd(self, command, module='api', *args, expect=0):
        return self.cli(command, '--coord', self.c, '--module', module, *args, expect=expect)

    def setup_worker(self, module='api', role='developer', phase=None):
        d = self.cmd('prepare', module, '--task', self.task, '--role', role, *(['--phase', phase] if phase else []))
        wt = self.root/('worktree-'+module)
        self.git('worktree', 'add', '-b', 'worker-'+module, wt, self.fleet['integrationBranch'])
        d = self.cmd('bind', module, '--worktree', wt)
        if d['transport'] == 'native':
            d = self.cmd('register', module, '--session-id', 'thread-'+module, '--host-id', 'host-1', '--sidebar-section-id', 'section-1')
        return d

    def get_record(self, module='api'):
        return json.loads((self.c/'v2'/f'{module}.json').read_text())

    def write_receipt(self, d, *, fallback=False, handoff=True, **kw):
        r = dict(version=2, rq=self.rq, module=d['module'], attempt=d['attempt'], worktree=d.get('worktree'),
            result='done', summary='Complete', commit=self.git('rev-parse', 'HEAD', cwd=d['worktree']) if d.get('worktree') else '',
            tests=[dict(command='actual-check', result='passed', evidence='/tmp/report.txt')], risks=[], needsInput=[])
        r.update(kw)
        parent = Path(self.fleet['inboxRoot']) if fallback else self.c
        parent.mkdir(parents=True, exist_ok=True)
        path = parent/(f"{d['module']}-{d['attempt']}.receipt.json" if fallback else f"{d['module']}.receipt.json")
        path.write_text(json.dumps(r))
        if handoff:
            (parent/f"{d['module']}-{d['attempt']}.handoff.md").write_text('Requirements: /path/source\nKnown issue: branch case\nNext: complete actual workflow\n')
        return path

    def change(self, d, filename='feature.txt', land=True):
        wt = Path(d['worktree'])
        (wt/filename).write_text(filename)
        self.git('add', '.', cwd=wt)
        self.git('commit', '-m', filename, cwd=wt)
        if land:
            r = subprocess.run([str(ROOT/'scripts/cc-fleet-land'), self.rq], cwd=wt, text=True, capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
        return self.git('rev-parse','HEAD',cwd=wt)

    def reply(self, d, *, fresh=False, expect=0, **kw):
        args = ['--text-file', self.task, '--session', 'fresh' if fresh else 'reuse']
        if fresh:
            args += ['--observed-state', kw.pop('state','completed'), '--observed-session-id', kw.pop('sid',d['sessionId'])]
        for k,v in kw.items():
            args += ['--'+k.replace('_','-'),v]
        return self.cmd('reply', d['module'], *args, expect=expect)

    def test_init_prepare_native_only_and_inheritance(self):
        d = self.cmd('prepare', 'api', '--task', self.task)
        self.assertEqual(d['transport'],'native')
        self.assertEqual(d['permissions'],'inherit')
        self.assertEqual(d['nativeSettingsPolicy'],'inherit-parent')
        self.assertEqual(d['nativeSettings'],{})
        self.assertIsNone(d['worktree'])
        self.assertEqual(self.git('rev-parse','HEAD'),self.base)
        self.assertEqual(json.loads((ROOT/'native-codex.json').read_text()),{'inherit':'parent'})
        for role in ('scout','verify','integ','regression'):
            self.assertEqual(self.cmd('prepare',role,'--task',self.task,'--role',role)['nativeSettingsPolicy'],'inherit-parent')

    def test_pending_and_real_identity_cannot_be_replaced(self):
        self.cmd('prepare','api','--task',self.task)
        p = self.cmd('register','api','--client-thread-id','client-1')
        self.assertEqual(p['state'],'setting-up')
        self.assertIsNone(p['sessionId'])
        self.cmd('register','api','--client-thread-id','client-2',expect=2)
        self.cmd('register','api','--session-id','real','--host-id','host-1')
        self.cmd('register','api','--session-id','other','--host-id','host-1',expect=2)
        self.cmd('register','api','--session-id','real','--host-id','other',expect=2)
        self.cmd('register','api','--client-thread-id','client-1',expect=2)
        self.assertEqual(self.get_record()['sessionId'],'real')

    def test_subdirectory_is_preserved_and_absolute_is_rejected(self):
        (self.repo/'sub').mkdir()
        (self.repo/'sub/AGENTS.md').write_text('subproject rules')
        self.git('add','.')
        self.git('commit','-m','subproject')
        f = self.cli('init','--cwd',self.repo/'sub')
        d = self.cli('prepare','--coord',f['coord'],'--module','sub','--task',self.task)
        self.assertEqual(d['subdir'],'sub')
        self.cmd('prepare','bad','--task',self.task,'--subdir','/tmp',expect=2)

    def test_bind_rejects_primary_wrong_repo_and_missing_baseline(self):
        self.cmd('prepare','api','--task',self.task)
        self.cmd('bind','api','--worktree',self.repo,expect=2)
        other = self.root/'other'
        other.mkdir()
        self.git('init','-b','main',cwd=other)
        self.cmd('bind','api','--worktree',other,expect=2)
        d = self.setup_worker('actual')
        self.cmd('bind','actual','--worktree',d['worktree'],'--attempt','stale',expect=2)
        self.git('update-ref','refs/heads/'+self.fleet['integrationBranch'],self.base)
        record = self.get_record('actual')
        record['baselineCommit']='0'*40
        (self.c/'v2/actual.json').write_text(json.dumps(record))
        self.cmd('bind','actual','--worktree',d['worktree'],expect=2)

    def test_status_unknown_runtime_and_compact_default(self):
        d=self.setup_worker()
        self.assertEqual(self.cli('status','--coord',self.c)['jobs'][0]['state'],'unknown')
        self.write_receipt(d)
        compact = self.cli('status','--coord',self.c)['jobs'][0]
        self.assertEqual(compact['state'],'done')
        self.assertNotIn('receipt',compact)
        self.assertEqual(compact['tests']['passed'],1)
        full=self.cli('status','--coord',self.c,'--details')['jobs'][0]
        self.assertIn('receipt',full)

    def test_current_inbox_receipt_wins_over_stale_persistent(self):
        d=self.setup_worker()
        self.write_receipt(d)
        r=json.loads((self.c/'api.receipt.json').read_text())
        r['attempt']='old'
        (self.c/'api.receipt.json').write_text(json.dumps(r))
        self.write_receipt(d,fallback=True)
        self.assertTrue(self.cmd('validate-receipt')['valid'])
        self.assertEqual(self.cmd('collect')['result'],'done')

    def test_collect_persists_receipt_and_handoff_by_attempt(self):
        d=self.setup_worker()
        self.write_receipt(d,fallback=True)
        out=self.cmd('collect')
        shutil.rmtree(Path(self.fleet['inboxRoot']))
        self.assertTrue(Path(out['handoffFile']).is_file())
        archive=self.c/'history/api'/d['attempt']
        self.assertEqual(json.loads((archive/'receipt.json').read_text())['attempt'],d['attempt'])
        info=json.loads((archive/'handoff-source.json').read_text())
        self.assertEqual(info['sha256'],hashlib.sha256((archive/'handoff.md').read_bytes()).hexdigest())
        self.assertNotIn('receipt',out)

    def test_collect_blocked_keeps_needs_input_and_handoff(self):
        d=self.setup_worker()
        self.write_receipt(d,fallback=True,result='blocked',tests=[],needsInput=[{'question':'Need business rule','impact':'branch'}])
        out=self.cmd('collect')
        self.assertEqual(out['result'],'blocked')
        self.assertEqual(out['needsInput'][0]['question'],'Need business rule')
        self.assertTrue(Path(out['handoffFile']).exists())

    def test_legacy_receipt_without_handoff_still_collects_but_cannot_fresh(self):
        d=self.setup_worker()
        self.write_receipt(d,handoff=False)
        self.assertIn('handoffWarning',self.cmd('collect'))
        self.reply(d,fresh=True,expect=2)
        self.assertEqual(self.get_record()['attempt'],d['attempt'])

    def test_current_legacy_handoff_is_archived_but_old_alias_is_not_reused(self):
        d=self.setup_worker()
        self.write_receipt(d,handoff=False)
        hp=self.c/'api.handoff.md'
        hp.write_text('Legacy useful handoff')
        self.assertTrue(self.cmd('collect')['handoffFile'])
        new=self.reply(d)
        self.write_receipt(new,handoff=False)
        self.assertIn('handoffWarning',self.cmd('collect'))

    def test_validation_reports_multiple_errors_and_does_not_mutate(self):
        d=self.setup_worker()
        path=self.write_receipt(d,commit='short',tests=[dict(result='failed')],summary='')
        before=path.read_bytes()
        out=self.cmd('validate-receipt',expect=1)
        self.assertFalse(out['valid'])
        self.assertGreaterEqual(len(out['errors']),5)
        self.assertEqual(path.read_bytes(),before)

    def test_malformed_receipt_does_not_crash_status(self):
        self.setup_worker()
        for value in ('bad json', json.dumps({'attempt':'wrong','tests':42}),json.dumps([])):
            (self.c/'api.receipt.json').write_text(value)
            self.assertEqual(self.cli('status','--coord',self.c)['jobs'][0]['state'],'needs-review')

    def test_developer_commit_must_be_landed_and_worktree_clean(self):
        d=self.setup_worker()
        self.change(d,land=False)
        self.write_receipt(d)
        out=self.cmd('validate-receipt',expect=1)
        self.assertIn('commit not landed on integration branch',out['errors'])
        subprocess.run([str(ROOT/'scripts/cc-fleet-land'),self.rq],cwd=d['worktree'],check=True,capture_output=True)
        self.write_receipt(d)
        self.assertTrue(self.cmd('validate-receipt')['valid'])
        (Path(d['worktree'])/'uncommitted.txt').write_text('new')
        self.assertFalse(self.cmd('validate-receipt',expect=1)['valid'])

    def test_old_landed_sha_cannot_hide_unlanded_current_fix(self):
        d=self.setup_worker()
        old=self.change(d,'landed.txt')
        self.change(d,'unlanded-fix.txt',land=False)
        self.write_receipt(d,commit=old)
        errors=self.cmd('validate-receipt',expect=1)['errors']
        self.assertIn('worktree HEAD not landed on integration branch',errors)

    def test_readonly_coordination_bind_uses_verified_pending_record(self):
        if os.geteuid()==0:
            self.skipTest('permission semantics require non-root user')
        d=self.cmd('prepare','api','--task',self.task)
        wt=self.root/'readonly-worker'
        self.git('worktree','add','-b','readonly-worker',wt,self.fleet['integrationBranch'])
        lock=self.c/'v2/.api.lock'
        rec=self.c/'v2/api.json'
        try:
            lock.chmod(0o444)
            rec.chmod(0o444)
            (self.c/'v2').chmod(0o555)
            out=self.cmd('bind','api','--attempt',d['attempt'],'--worktree',wt)
            self.assertTrue(out['bindingPending'])
            self.assertEqual(out['worktree'],str(wt))
            self.assertTrue(Path(out['bindingFile']).is_file())
            self.assertIsNone(self.get_record()['worktree'])
            self.cmd('bind','api','--attempt','stale','--worktree',wt,expect=2)
            self.cmd('bind','api','--attempt',d['attempt'],'--worktree',self.repo,expect=2)
        finally:
            (self.c/'v2').chmod(0o755)
            lock.chmod(0o644)
            rec.chmod(0o644)
        self.write_receipt(out,fallback=True)
        self.cmd('collect')
        self.assertEqual(self.get_record()['worktree'],str(wt))

    def test_regression_plan_reads_integration_ref_from_primary_checkout(self):
        (self.repo/'tests/e2e').mkdir(parents=True)
        (self.repo/'src').mkdir()
        (self.repo/'package.json').write_text('{}')
        (self.repo/'tests/e2e/research.spec.ts').write_text('research case')
        self.git('add','.')
        self.git('commit','-m','test fixture')
        self.git('update-ref','refs/heads/'+self.fleet['integrationBranch'],self.git('rev-parse','HEAD'))
        d=self.setup_worker()
        wt=Path(d['worktree'])
        (wt/'src').mkdir()
        (wt/'src/research.ts').write_text('research implementation')
        (wt/'tests/e2e/new-research.spec.ts').write_text('new regression check')
        (wt/'prisma').mkdir()
        (wt/'prisma/schema.prisma').write_text('model A {}')
        self.git('add','.',cwd=wt)
        self.git('commit','-m','actual changes',cwd=wt)
        subprocess.run([str(ROOT/'scripts/cc-fleet-land'),self.rq],cwd=wt,check=True,capture_output=True)
        r=subprocess.run([str(ROOT/'scripts/cc-fleet-e2e-scope'),'plan',str(self.c)],cwd=self.repo,capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('tests/e2e/research.spec.ts',r.stdout)
        self.assertIn('tests/e2e/new-research.spec.ts',r.stdout)
        self.assertIn('建议升级为全量',r.stdout)
        self.assertIn('schema.prisma',r.stdout)
        self.assertFalse((self.repo/'src/research.ts').exists())

    def test_acceptance_evidence_invalidated_by_new_integration(self):
        d=self.setup_worker(role='verify')
        self.write_receipt(d)
        self.assertTrue(self.cmd('validate-receipt')['valid'])
        dev=self.setup_worker('dev')
        self.change(dev)
        self.assertIn('acceptance baseline changed; reverify current integration', self.cmd('validate-receipt',expect=1)['errors'])

    def test_author_can_finish_specs_without_execution_then_fresh_execute(self):
        d=self.setup_worker(role='verify',phase='author')
        self.change(d,'spec.txt',land=False)
        self.write_receipt(d,tests=[dict(command='author specs',result='not-run',evidence='spec.txt with cases')])
        self.assertTrue(self.cmd('validate-receipt')['valid'])
        n=self.reply(d,fresh=True,phase='execute')
        self.assertEqual(n['phase'],'execute')
        self.write_receipt(n,tests=[dict(command='not executed',result='not-run',evidence='spec')])
        self.assertFalse(self.cmd('validate-receipt',expect=1)['valid'])

    def test_fresh_requires_exact_ended_thread_and_no_force_bypass(self):
        d=self.setup_worker()
        self.write_receipt(d)
        for state in ('running','unknown','waiting'):
            self.reply(d,fresh=True,state=state,expect=2)
        self.reply(d,fresh=True,sid='wrong',expect=2)
        self.cmd('reply','api','--text-file',self.task,'--session','fresh','--force',expect=2)
        self.assertEqual(self.get_record()['attempt'],d['attempt'])

    def test_fresh_preserves_worktree_and_assets_and_rejects_retired_identity(self):
        d=self.setup_worker()
        self.change(d)
        self.write_receipt(d)
        n=self.reply(d,fresh=True)
        self.assertNotEqual(n['attempt'],d['attempt'])
        self.assertEqual(n['worktree'],d['worktree'])
        self.assertIsNone(n['sessionId'])
        self.assertEqual(n['previousSessions'][0]['sessionId'],d['sessionId'])
        self.assertTrue((Path(d['worktree'])/'feature.txt').exists())
        self.cmd('register','api','--session-id','new','--host-id','host-1',expect=2)
        self.cmd('register','api','--session-id',d['sessionId'],'--host-id','host-1','--attempt',n['attempt'],expect=2)
        x=self.cmd('register','api','--session-id','new','--host-id','host-1','--attempt',n['attempt'],'--sidebar-section-id','section-1')
        self.assertEqual(x['sidebar']['state'],'placed')
        self.cmd('bind','api','--worktree',d['worktree'],'--attempt',d['attempt'],expect=2)

    def test_reuse_new_attempt_rejects_old_done_and_uncertain_send(self):
        d=self.setup_worker()
        self.write_receipt(d)
        n=self.reply(d)
        self.assertEqual(n['sessionId'],d['sessionId'])
        current_prompt=(self.c/'api.prompt.md').read_text()
        self.assertIn('attempt：'+n['attempt'],current_prompt)
        self.assertNotIn('attempt：'+d['attempt'],current_prompt)
        self.assertEqual(n['nativeSettingsPolicy'],'inherit-parent')
        self.assertEqual(self.cli('status','--coord',self.c)['jobs'][0]['state'],'replying')
        self.reply(n,expect=2)
        self.cmd('register','api','--session-id',d['sessionId'],'--host-id','host-1')
        self.write_receipt(d)
        self.assertFalse(self.cmd('validate-receipt',expect=1)['valid'])
        self.write_receipt(n)
        self.assertTrue(self.cmd('validate-receipt')['valid'])

    def test_rework_cap_and_explicit_force(self):
        d=self.setup_worker()
        for _ in range(3):
            self.write_receipt(d)
            d=self.reply(d)
            self.cmd('register','api','--session-id',d['sessionId'],'--host-id','host-1')
        self.reply(d,expect=2)
        forced=self.cmd('reply','api','--text-file',self.task,'--force')
        self.assertEqual(forced['replies'],4)

    def test_legacy_native_card_is_extracted_without_old_attempt(self):
        d=self.setup_worker()
        self.write_receipt(d)
        (self.c/'api.task.md').unlink()
        (self.c/'api.prompt.md').write_text('Legacy identity '+d['attempt']+'\n任务卡：\nOriginal requirement with exact numeric boundary 56')
        n=self.reply(d,fresh=True)
        prompt=(self.c/'api.prompt.md').read_text()
        self.assertIn('boundary 56',prompt)
        self.assertNotIn('Legacy identity',prompt)
        self.assertEqual((self.c/'api.task.md').read_text(),'Original requirement with exact numeric boundary 56')
        self.assertIn(n['attempt'],prompt)

    def test_fresh_failed_handoff_preserves_uncommitted_work(self):
        d=self.setup_worker()
        path=Path(d['worktree'])/'partial-work.txt'
        path.write_text('Preserve unfinished implementation')
        self.write_receipt(d,result='failed',tests=[dict(command='check',result='failed',evidence='branch failure')])
        n=self.reply(d,fresh=True,state='failed')
        self.assertEqual(path.read_text(),'Preserve unfinished implementation')
        self.assertEqual(n['worktree'],d['worktree'])
        old=json.loads((self.c/'history/api'/d['attempt']/'receipt.json').read_text())
        self.assertEqual(old['result'],'failed')
        self.assertEqual(old['tests'][0]['result'],'failed')

    def test_snapshot_single_current_and_idempotent_history(self):
        path=self.root/'current.md'
        path.write_text('Current phase A\nInput still open')
        self.cli('snapshot','--coord',self.c,'--file',path)
        path.write_text('Current phase B\nInput answered, verify next')
        self.cli('snapshot','--coord',self.c,'--file',path)
        old=list((self.c/'history/current').glob('*.md'))
        self.assertEqual(len(old),1)
        self.assertIn('phase A',old[0].read_text())
        self.assertNotIn('phase A',(self.c/'CURRENT.md').read_text())
        self.assertFalse(self.cli('snapshot','--coord',self.c,'--file',path)['changed'])
        self.assertEqual(len(list((self.c/'history/current').glob('*.md'))),1)

    def test_legacy_backends_rejected_and_retired_global_hooks_silent(self):
        for cmd,args in [('prepare',['--backend','claude']),('prepare',['--transport','app-server']),('prepare',['--permissions','full'])]:
            self.cmd(cmd,'no','--task',self.task,*args,expect=2)
        self.cmd('prepare','no','--task',self.task,'--after','api',expect=2)
        self.assertIsNone(self.cli('stop-guard'))
        self.assertIsNone(self.cli('rescue-owners'))


class TriggerTests(unittest.TestCase):
    def test_prompt_routing_and_worker_exclusion(self):
        for prompt,expected in [('多 session 模式完成',True),('让子会话处理研究',True),('fix with fleet',True),('普通修改',False),('用 subagent 查代码',False),('⟦FLEET-WORKER⟧ 多 session',False),('/multi-session-dev 做',False)]:
            r=subprocess.run([str(ROOT/'scripts/cc-fleet-trigger-hook')],input=json.dumps({'prompt':prompt}),text=True,capture_output=True,env={k:v for k,v in os.environ.items() if k!='FLEET_ROLE'})
            self.assertEqual(r.returncode,0)
            self.assertEqual(bool(r.stdout),expected,prompt)
        r=subprocess.run([str(ROOT/'scripts/cc-fleet-trigger-hook')],input='bad JSON',text=True,capture_output=True)
        self.assertEqual((r.returncode,r.stdout),(0,''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
