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
        # Native events below are deterministic local fixtures, NOT host lifecycle tests.
        self.event_count = 0
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
        self.note = self.root/'dispatch-note.md'
        self.note.write_text('Resume from the preserved evidence using the current task card.')
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

    def setup_worker(self, module='api', role='developer', phase=None, *, fork_context=False, context_reason=None):
        d = self.cmd('prepare', module, '--task', self.task, '--role', role, *(['--phase', phase] if phase else []))
        wt = self.root/('worktree-'+module)
        self.git('worktree', 'add', '-b', 'worker-'+module, wt, self.fleet['integrationBranch'])
        d = self.cmd('bind', module, '--worktree', wt)
        if d['transport'] == 'native':
            d = self.register(d, 'agent-'+module, fork_context=fork_context, context_reason=context_reason)
        return d

    def event(self, d, tool, args, result, **wrapper):
        self.event_count += 1
        p = self.root/f'fixture-event-{self.event_count}.json'
        p.write_text(json.dumps(dict(module=d['module'], attempt=d['attempt'], tool=tool,
            args=args, result=result, fixture=True, **wrapper)))
        return p

    def register(self, d, aid=None, expect=0, *, fork_context=False, context_reason=None):
        aid = aid or d.get('agentId')
        current = self.get_record(d['module'])
        if current['state'] == 'replying':
            tool, args, result = 'send_input', dict(target=aid, message='Current complete task prompt'), dict(submission_id=f'submission-{self.event_count}')
        else:
            tool, args, result = 'spawn_agent', dict(fork_context=fork_context, message=Path(self.c/(d['module']+'.prompt.md')).read_text()), dict(agent_id=aid, nickname=None)
        e = self.event(d, tool, args, result)
        return self.cmd('register', d['module'], '--agent-id', aid, '--attempt', d['attempt'], '--evidence-file', e,
                        *(['--context-reason', context_reason] if context_reason is not None else []), expect=expect)

    def task_assets(self):
        # Locks may be opened on rejected calls; no task/prompt/receipt/history
        # or event may be changed or created before validation succeeds.
        return {str(p.relative_to(self.c)):p.read_bytes() for p in self.c.rglob('*')
                if p.is_file() and not p.name.endswith('.lock')}

    def observe(self, d, status='completed', tool='wait_agent', **kw):
        aid = d['agentId']
        raw = {'completed':'fixture completion'} if status == 'completed' else {'errored':'fixture failure'} if status == 'errored' else status
        if status == 'completed' and tool != 'close_agent':
            paths=[self.c/(d['module']+'.receipt.json'),
                   Path(self.fleet['inboxRoot'])/f"{d['module']}-{d['attempt']}.receipt.json",
                   self.c/'history'/d['module']/d['attempt']/'receipt.json']
            receipts=[json.loads(p.read_text()) for p in paths if p.is_file()]
            receipt=next((r for r in receipts if r.get('attempt') == d['attempt']),None)
            self.assertIsNotNone(receipt,'positive completed fixture requires a worker JSON receipt')
            raw={'completed':json.dumps(receipt)}
        if tool == 'wait_agent':
            args, result = dict(targets=[aid], timeout_ms=10000), dict(status={aid:raw}, timed_out=False)
        elif tool == 'resume_agent':
            args, result = dict(id=aid), dict(status=raw)
        else:
            args, result = dict(target=aid), dict(previous_status=raw)
        event = self.event(d, tool, args, result)
        return self.cmd('observe', d['module'], '--agent-id', aid, '--attempt', d['attempt'], '--tool', tool, '--evidence-file', event, **kw)

    def get_record(self, module='api'):
        return json.loads((self.c/'v2'/f'{module}.json').read_text())

    def write_receipt(self, d, *, fallback=False, handoff=True, **kw):
        r = dict(version=2, agent_id=d.get('agentId'), rq=self.rq, module=d['module'], attempt=d['attempt'], worktree=d.get('worktree'),
            result='done', summary='Complete', commit=self.git('rev-parse', 'HEAD', cwd=d['worktree']) if d.get('worktree') and self.fleet.get('assetKind') != 'artifacts' else '',
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
        state = kw.pop('state','completed')
        sid = kw.pop('sid',d['agentId'])
        if expect == 0:
            self.observe(d, state)
        args = ['--text-file', self.note, '--session', 'fresh' if fresh else 'reuse',
                '--observed-state', state, '--observed-agent-id', sid]
        if fresh:
            args += ['--fresh-reason', kw.pop('fresh_reason','Conflicting stale assumptions; preserve evidence and hand over to a cold agent')]
        if not fresh:
            args += ['--reuse-reason', kw.pop('reuse_reason','Continue the same defect using its preserved reproduction state')]
        for k,v in kw.items():
            args += ['--'+k.replace('_','-')]+([] if v is True else [v])
        return self.cmd('reply', d['module'], *args, expect=expect)

    def test_init_prepare_native_only_and_inheritance(self):
        d = self.cmd('prepare', 'api', '--task', self.task)
        self.assertEqual(d['transport'],'native')
        self.assertEqual(d['permissions'],'inherit')
        self.assertEqual(d['nativeSettingsPolicy'],'inherit-parent')
        self.assertEqual(d['nativeSettings'],{})
        self.assertEqual(d['taskRevision'],1)
        self.assertEqual(d['taskSha256'],hashlib.sha256(self.task.read_bytes()).hexdigest())
        self.assertIsNone(d['worktree'])
        self.assertEqual(self.git('rev-parse','HEAD'),self.base)
        self.assertEqual(json.loads((ROOT/'native-codex.json').read_text()),{'inherit':'parent'})
        for role in ('scout','verify','integ','regression'):
            self.assertEqual(self.cmd('prepare',role,'--task',self.task,'--role',role)['nativeSettingsPolicy'],'inherit-parent')

    def test_pending_and_real_identity_cannot_be_replaced(self):
        d=self.cmd('prepare','api','--task',self.task)
        self.cmd('register','api','--attempt',d['attempt'],'--client-thread-id','client-1',expect=2)
        e=self.event(d,'spawn_agent',dict(fork_context=False,message='task'),dict(agent_id='real',nickname=None))
        real=self.cmd('register','api','--attempt',d['attempt'],'--agent-id','real','--evidence-file',e)
        self.assertEqual(real['runtime']['state'],'pending_init')
        self.assertEqual(real['executionKind'],'subagent')
        self.assertEqual(self.cmd('register','api','--attempt',d['attempt'],'--agent-id','real','--evidence-file',e),real)
        self.register(d,'other',expect=2)
        self.cmd('register','api','--attempt',d['attempt'],'--agent-id','real','--host-id','host-1','--evidence-file',e,expect=2)
        self.assertEqual(self.get_record()['agentId'],'real')

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
        initial=self.cli('status','--coord',self.c)['jobs'][0]
        self.assertEqual(initial['runtime']['state'],'pending_init')
        self.assertEqual(initial['runtime']['capacity'],'occupied')
        self.write_receipt(d)
        compact=self.cli('status','--coord',self.c)['jobs'][0]
        self.assertEqual(compact['state'],'done')
        self.assertFalse(compact['deliveryReady'])  # receipt is not native completion
        self.assertNotIn('receipt',compact)
        self.assertEqual(compact['tests']['passed'],1)
        self.observe(d)
        self.assertTrue(self.cli('status','--coord',self.c)['jobs'][0]['deliveryReady'])
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
        self.observe(d)
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
        registered=self.register(out,'agent-readonly')
        out.update(agentId=registered['agentId'])
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
        self.cmd('register','api','--agent-id','new',expect=2)
        self.register(n,d['agentId'],expect=2)
        x=self.register(n,'new')
        self.assertEqual(x['agentId'],'new')
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
        self.register(self.get_record())
        self.write_receipt(d)
        self.assertFalse(self.cmd('validate-receipt',expect=1)['valid'])
        self.write_receipt(n)
        self.assertTrue(self.cmd('validate-receipt')['valid'])

    def test_rework_cap_and_explicit_force(self):
        d=self.setup_worker()
        for _ in range(3):
            self.write_receipt(d)
            d=self.reply(d)
            self.register(self.get_record())
        self.reply(d,expect=2)
        self.write_receipt(d)
        self.observe(d)
        forced=self.cmd('reply','api','--text-file',self.note,'--force','--session','reuse',
                        '--reuse-reason','Same defect after requirements review',
                        '--observed-session-id',d['sessionId'],'--observed-state','completed')
        self.assertEqual(forced['replies'],4)

    def test_reuse_requires_exact_ended_thread_and_reason_without_mutation(self):
        d=self.setup_worker()
        receipt=self.write_receipt(d)
        self.observe(d)
        before={p:p.read_bytes() for p in [self.c/'v2/api.json',self.c/'api.task.md',self.c/'api.prompt.md',receipt]}
        for state in ('running','unknown','waiting'):
            self.reply(d,state=state,expect=2)
        self.reply(d,sid='different-thread',expect=2)
        self.reply(d,reuse_reason='   ',expect=2)
        self.cmd('reply','api','--text-file',self.note,'--session','reuse','--force',
                 '--reuse-reason','Same defect',expect=2)
        for p,content in before.items():
            self.assertEqual(p.read_bytes(),content)
        self.assertFalse((self.c/'history/api'/d['attempt']/'task.md').exists())  # native evidence archive already exists

    def test_auto_never_silently_reuses_a_thread(self):
        d=self.setup_worker()
        for args in ([],['--session','auto','--force']):
            out=self.cmd('reply','api','--text-file',self.note,*args,expect=2)
            self.assertIn('choose --session reuse or fresh explicitly',out['error'])
            self.assertEqual(self.get_record()['attempt'],d['attempt'])

    def test_independent_tasks_can_share_role_without_reusing_busy_identity(self):
        original=self.setup_worker('runtime-install')
        separate=self.setup_worker('runtime-search',role=original['role'])
        self.assertEqual(self.get_record('runtime-install'),original)
        self.assertNotEqual(separate['sessionId'],original['sessionId'])
        self.assertNotEqual(separate['attempt'],original['attempt'])
        self.assertNotEqual(separate['worktree'],original['worktree'])
        self.assertFalse((self.c/'runtime-install.receipt.json').exists())
        jobs=self.cli('status','--coord',self.c)['jobs']
        self.assertEqual({j['module'] for j in jobs},{'runtime-install','runtime-search'})

    def test_full_task_replacement_archives_history_without_stacking_old_notes(self):
        original='Deliver exactly 10 rows; exclude audit appendix.'
        replacement='Deliver exactly 20 rows with an audit appendix and source evidence.'
        self.task.write_text(original)
        d=self.setup_worker()
        self.write_receipt(d)
        update=self.root/'replacement.md'
        update.write_text(replacement)
        self.note.write_text('First dispatch operational marker.')
        n=self.reply(d,task=update)
        self.assertEqual((self.c/'api.task.md').read_text(),replacement)
        self.assertEqual(n['taskRevision'],2)
        self.assertEqual(n['taskSha256'],hashlib.sha256(update.read_bytes()).hexdigest())
        archived=self.c/'history/api'/d['attempt']
        self.assertEqual((archived/'task.md').read_text(),original)
        self.assertIn(original,(archived/'prompt.md').read_text())
        self.assertNotIn(original,(self.c/'api.prompt.md').read_text())
        self.register(self.get_record())
        self.write_receipt(n)
        self.note.write_text('Second dispatch operational marker.')
        current=self.reply(n,task=update)
        self.assertEqual(current['taskRevision'],2)
        self.assertEqual((self.c/'api.task.md').read_text(),replacement)
        prompt=(self.c/'api.prompt.md').read_text()
        self.assertIn('Second dispatch operational marker.',prompt)
        self.assertNotIn('First dispatch operational marker.',prompt)
        self.assertNotIn(original,prompt)
        self.assertEqual((self.c/'history/api'/n['attempt']/'task.md').read_text(),replacement)

    def test_empty_replacement_does_not_destroy_active_task_or_receipt(self):
        d=self.setup_worker()
        receipt=self.write_receipt(d)
        update=self.root/'empty.md'
        update.write_text('  \n')
        self.observe(d)
        before=receipt.read_bytes()
        self.reply(d,task=update,expect=2)
        self.assertEqual(self.get_record()['attempt'],d['attempt'])
        self.assertEqual(receipt.read_bytes(),before)
        self.assertEqual((self.c/'api.task.md').read_text(),self.task.read_text())

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
        n=self.reply(d,fresh=True)  # real worker returns its full failed receipt JSON
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


    def test_spawn_evidence_and_unique_agent_identity_are_enforced(self):
        d=self.cmd('prepare','first','--task',self.task)
        before=(self.c/'v2/first.json').read_bytes()
        for args,result in [(dict(message='task'),dict(agent_id='a')),
                            (dict(fork_context=True),dict(agent_id='a')),
                            (dict(fork_context=False),dict(agent_id='different'))]:
            e=self.event(d,'spawn_agent',args,result)
            self.cmd('register','first','--attempt',d['attempt'],'--agent-id','a','--evidence-file',e,expect=2)
            self.assertEqual((self.c/'v2/first.json').read_bytes(),before)
        first=self.register(d,'unique')
        other=self.cmd('prepare','other','--task',self.task)
        self.register(other,'unique',expect=2)
        self.assertIsNone(self.get_record('other')['agentId'])
        self.assertEqual(self.get_record('first')['agentId'],first['agentId'])

    def test_default_context_dispatch_is_read_only_and_registers_false(self):
        d=self.cmd('prepare','api','--task',self.task)
        before=self.task_assets()
        plan=self.cmd('dispatch')
        self.assertEqual(self.task_assets(),before)
        self.assertIs(plan['spawnPolicy']['defaultForkContext'],False)
        self.assertEqual(plan['spawnPolicy'],d['spawnPolicy'])
        registered=self.register(plan,'default-agent',fork_context=plan['spawnPolicy']['defaultForkContext'])
        self.assertEqual(registered['spawnContext'],dict(forkContext=False,reason=None))
        self.assertEqual(registered['agentId'],'default-agent')
        self.assertEqual(registered['runtime']['state'],'pending_init')
        self.cmd('dispatch',expect=2)

    def test_inherited_spawn_records_reason_actual_event_and_idempotent_replay(self):
        d=self.cmd('prepare','api','--task',self.task)
        reason='主端历史短且仅含本卡约束，继承可避免转述遗漏与明显整理成本'
        e=self.event(d,'spawn_agent',dict(fork_context=True,message=Path(d['promptFile']).read_text()),dict(agent_id='inherited'))
        args=('register','api','--attempt',d['attempt'],'--agent-id','inherited','--evidence-file',e)
        registered=self.cmd(*args,'--context-reason',reason)
        self.assertEqual(registered['spawnContext'],dict(forkContext=True,reason=reason))
        saved=Path(registered['dispatchEvidence']['path'])
        self.assertEqual(saved.read_bytes(),e.read_bytes())
        self.assertEqual(registered['dispatch']['scope']['agentId'],'inherited')
        before=self.task_assets()
        self.assertEqual(self.cmd(*args,'--context-reason',reason),registered)
        for extra in ([],['--context-reason','different reason'],['--context-reason','one\ntwo']):
            self.cmd(*args,*extra,expect=2)
            self.assertEqual(self.task_assets(),before)

    def test_invalid_context_registration_never_mutates_task_assets(self):
        d=self.cmd('prepare','api','--task',self.task)
        cases=[({},None,'agent'),({'fork_context':True},None,'agent'),
               ({'fork_context':True},'  ','agent'),({'fork_context':True},'one\ntwo','agent'),
               ({'fork_context':False},'not applicable','agent'),
               ({'fork_context':True},'short focused parent avoids omissions','wrong-agent')]
        cases += [({'fork_context':value},'reason','agent') for value in (None,0,1,'false','true',[],{})]
        for args,reason,returned_id in cases:
            with self.subTest(args=args,reason=reason,returned_id=returned_id):
                e=self.event(d,'spawn_agent',dict(message='complete task',**args),dict(agent_id=returned_id))
                before=self.task_assets()
                self.cmd('register','api','--attempt',d['attempt'],'--agent-id','agent','--evidence-file',e,
                         *(['--context-reason',reason] if reason is not None else []),expect=2)
                self.assertEqual(self.task_assets(),before)
        # Argument-parser failures must also leave the prepared task intact.
        before=self.task_assets()
        self.cmd('register','api','--attempt',d['attempt'],'--agent-id','agent','--context-reason',expect=2)
        self.assertEqual(self.task_assets(),before)

    def test_inherited_reuse_keeps_worker_history_and_rejects_spawn_options(self):
        d=self.setup_worker(fork_context=True,context_reason='Short focused parent avoids material omissions')
        self.write_receipt(d)
        n=self.reply(d)
        self.assertEqual(n['agentId'],d['agentId'])
        self.assertEqual(n['spawnContext'],d['spawnContext'])
        self.assertNotIn('spawnPolicy',n)
        self.cmd('dispatch',expect=2)
        for fork,reason in ((None,'reuse cannot choose inheritance'),(True,None),(False,None)):
            args=dict(target=n['agentId'],message=Path(n['promptFile']).read_text())
            if fork is not None:
                args['fork_context']=fork
            e=self.event(n,'send_input',args,dict(submission_id='accepted'))
            before=self.task_assets()
            self.cmd('register','api','--attempt',n['attempt'],'--agent-id',n['agentId'],'--evidence-file',e,
                     *(['--context-reason',reason] if reason else []),expect=2)
            self.assertEqual(self.task_assets(),before)
        current=self.register(n)
        self.assertEqual(current['spawnContext'],d['spawnContext'])
        self.assertEqual(current['dispatch']['tool'],'send_input')
        self.write_receipt(current)
        self.observe(current)
        self.assertTrue(self.cmd('collect')['deliveryReady'])

    def test_fresh_inheritance_keeps_assets_handoff_and_separate_identity(self):
        d=self.setup_worker()
        partial=Path(d['worktree'])/'partial.txt'
        partial.write_text('uncommitted evidence must survive inheritance')
        self.write_receipt(d,result='failed',tests=[dict(command='partial check',result='failed',evidence=str(partial))])
        n=self.reply(d,fresh=True,fresh_reason='Replacement capability is needed; current parent has short focused requirements')
        self.assertIsNone(n['agentId'])
        self.assertNotIn('spawnContext',n)
        self.assertEqual(n['previousSessions'][-1]['spawnContext'],d['spawnContext'])
        plan=self.cmd('dispatch')
        self.assertEqual(plan['spawnPolicy'],n['spawnPolicy'])
        self.assertTrue(plan['spawnPolicy']['allowForkContext'])
        before=self.task_assets()
        self.register(n,'replacement',fork_context=True,expect=2)
        self.assertEqual(self.task_assets(),before)
        current=self.register(n,'replacement',fork_context=True,context_reason='Short focused parent avoids requirements being lost in restatement')
        self.assertNotEqual(current['agentId'],d['agentId'])
        self.assertEqual(current['worktree'],d['worktree'])
        self.assertEqual(partial.read_text(),'uncommitted evidence must survive inheritance')
        handoff=Path(current['previousSessions'][-1]['handoffFile'])
        self.assertTrue(handoff.is_file())
        self.assertIn(str(handoff),Path(plan['promptFile']).read_text())
        self.assertEqual(self.git('rev-parse','HEAD',cwd=current['worktree']),self.base)

    def test_independent_acceptance_rejects_true_but_author_preparation_allows_it(self):
        for role,phase in [('verify',None),('integ',None),('regression',None),('verify','author'),('integ','author')]:
            module=role+'-'+str(phase)
            with self.subTest(role=role,phase=phase):
                d=self.cmd('prepare',module,'--task',self.task,'--role',role,*(['--phase',phase] if phase else []))
                plan=self.cmd('dispatch',module)
                allowed=phase == 'author'
                self.assertEqual(plan['spawnPolicy']['allowForkContext'],allowed)
                before=self.task_assets()
                result=self.register(d,'agent-'+module,fork_context=True,context_reason='Short related parent avoids omissions',expect=0 if allowed else 2)
                if allowed:
                    self.assertTrue(result['spawnContext']['forkContext'])
                else:
                    self.assertEqual(self.task_assets(),before)
                    self.assertFalse(self.register(d,'agent-'+module)['spawnContext']['forkContext'])

    def test_inherited_author_cannot_reuse_into_execute_and_fresh_requires_false(self):
        for role in ('verify','integ'):
            with self.subTest(role=role):
                d=self.setup_worker(role,role=role,phase='author',fork_context=True,context_reason='Short focused parent preserves detailed acceptance requirements')
                self.write_receipt(d,tests=[dict(command='author cases',result='not-run',evidence='case checklist')])
                self.assertTrue(self.cmd('validate-receipt',role)['valid'])
                self.observe(d)
                before=self.task_assets()
                self.reply(d,phase='execute',expect=2)
                self.assertEqual(self.task_assets(),before)
                self.reply(d,fresh=True,phase='execute',fresh_reason='',expect=2)
                self.assertEqual(self.task_assets(),before)
                n=self.reply(d,fresh=True,phase='execute',fresh_reason='Independent execute must discard inherited parent history')
                self.assertFalse(n['spawnPolicy']['allowForkContext'])
                self.assertEqual(self.cmd('dispatch',role)['spawnPolicy'],n['spawnPolicy'])
                before=self.task_assets()
                self.register(n,'executor-'+role,fork_context=True,context_reason='Cannot override independent acceptance',expect=2)
                self.assertEqual(self.task_assets(),before)
                current=self.register(n,'executor-'+role)
                self.assertFalse(current['spawnContext']['forkContext'])
                self.assertEqual(current['worktree'],d['worktree'])
                self.write_receipt(current,tests=[dict(command='execute actual cases',result='passed',evidence='execution report')])
                self.observe(current)
                self.assertTrue(self.cmd('collect',role)['deliveryReady'])

    def test_false_author_can_reuse_execute_and_legacy_false_remains_compatible(self):
        for legacy in (False,True):
            with self.subTest(legacy=legacy):
                module='author-'+str(legacy)
                d=self.setup_worker(module,role='verify',phase='author')
                if legacy:
                    d.pop('spawnContext')
                    (self.c/'v2'/f'{module}.json').write_text(json.dumps(d))
                self.write_receipt(d,tests=[dict(command='author cases',result='not-run',evidence='cases')])
                n=self.reply(d,phase='execute')
                current=self.register(n)
                self.assertEqual(current['agentId'],d['agentId'])
                self.assertEqual(current['phase'],'execute')
                self.write_receipt(current)
                self.observe(current)
                self.assertTrue(self.cmd('collect',module)['deliveryReady'])

    def test_receipt_requires_exact_agent_and_attempt(self):
        d=self.setup_worker()
        for changes in [dict(agent_id='someone-else'),dict(agent_id=None),dict(agentId='conflicting-alias'),dict(attempt='old'),dict(module='other')]:
            self.write_receipt(d,**changes)
            self.assertFalse(self.cmd('validate-receipt',expect=1)['valid'])
            self.cmd('collect',expect=2)
        self.write_receipt(d)
        self.assertTrue(self.cmd('validate-receipt')['valid'])

    def test_wait_timeout_not_found_and_unknown_status_are_honest(self):
        d=self.setup_worker()
        running=self.observe(d,'running')
        event=self.event(d,'wait_agent',dict(targets=[d['agentId']],timeout_ms=10000),dict(status={},timed_out=True))
        timed=self.cmd('observe','api','--attempt',d['attempt'],'--agent-id',d['agentId'],'--tool','wait_agent','--evidence-file',event)
        self.assertEqual(timed['runtime'],running['runtime'])
        self.assertTrue(timed['lastWait']['timedOut'])
        for status in ('not_found', {'unexpected':'shape'}):
            if isinstance(status,str):
                lost=self.observe(d,status)
                self.assertEqual(lost['runtime']['capacity'],'unknown')
                self.reply(d,fresh=True,state='not_found',expect=2)
            else:
                self.observe(d,status,expect=2)
                self.assertEqual(self.get_record()['runtime']['state'],'not_found')
        self.assertFalse(self.cli('status','--coord',self.c)['jobs'][0]['deliveryReady'])

    def test_close_request_and_shutdown_never_invent_completion(self):
        d=self.setup_worker()
        self.write_receipt(d)
        closing=self.observe(d,'running',tool='close_agent')
        self.assertEqual(closing['runtime']['state'],'closing')
        self.assertEqual(closing['runtime']['capacity'],'releasing')
        self.assertFalse(self.cmd('collect')['deliveryReady'])
        closed=self.observe(d,'shutdown')
        self.assertEqual(closed['runtime']['capacity'],'unknown')
        self.assertNotIn('executionEnded',closed['runtime'])  # raw status cannot bind a new turn
        self.assertNotIn('closure',closed)
        self.assertFalse(self.cmd('collect')['deliveryReady'])
        self.reply(d,state='shutdown',expect=2)  # reuse requires real resume

    def test_completed_close_resume_initialization_and_reuse(self):
        d=self.setup_worker()
        self.write_receipt(d)
        self.observe(d)
        self.assertTrue(self.cmd('collect')['deliveryReady'])
        self.observe(d,'completed',tool='close_agent')
        closed=self.observe(d,'not_found')
        self.assertEqual(closed['runtime']['state'],'closed')
        self.assertEqual(closed['runtime']['nativeState'],'not_found')
        self.assertEqual(closed['runtime']['capacity'],'released')
        resumed=self.observe(d,'pending_init',tool='resume_agent')
        self.assertTrue(resumed['runtime']['resumeAfterEnded'])
        n=self.cmd('reply','api','--text-file',self.note,'--session','reuse',
                   '--reuse-reason','Same defect after confirmed close/resume',
                   '--observed-agent-id',d['agentId'],'--observed-state','pending_init')
        self.assertEqual(n['agentId'],d['agentId'])
        self.assertNotEqual(n['attempt'],d['attempt'])
        current=self.register(n)
        self.write_receipt(current)
        self.observe(current)
        self.assertTrue(self.cmd('collect')['deliveryReady'])

    def raw_wait(self, d, raw):
        event=self.event(d,'wait_agent',dict(targets=[d['agentId']],timeout_ms=10000),
                         dict(status={d['agentId']:raw},timed_out=False))
        return self.cmd('observe',d['module'],'--attempt',d['attempt'],'--agent-id',d['agentId'],
                        '--tool','wait_agent','--evidence-file',event)

    def test_cached_previous_completion_never_ends_or_closes_new_submission(self):
        for has_receipt in (False,True):
            with self.subTest(currentReceipt=has_receipt):
                old=self.setup_worker('cache-'+str(has_receipt))
                old_json=self.write_receipt(old).read_text()
                new=self.register(self.reply(old))
                self.assertEqual(new['dispatch']['scope']['submissionId'],new['submissionId'])
                self.assertEqual(new['dispatch']['previousCompletion']['attempt'],old['attempt'])
                if has_receipt:
                    self.write_receipt(new)
                else:
                    (self.c/f"{new['module']}-{new['attempt']}.handoff.md").write_text('current partial assets')
                for _ in range(3):
                    observed=self.raw_wait(new,{'completed':old_json})
                    self.assertEqual(observed['runtime']['nativeState'],'completed')
                    self.assertNotIn('executionEnded',observed['runtime'])
                    self.assertNotIn('completedAttempt',observed)
                    job=next(x for x in self.cli('status','--coord',self.c)['jobs'] if x['module']==new['module'])
                    self.assertFalse(job['deliveryReady'])
                    for fresh in (False,True):
                        error=self.reply(new,state='completed',fresh=fresh,expect=2,force=True)
                        self.assertIn('observed native execution end',error['error'])
                closing=self.observe(new,'completed',tool='close_agent')
                self.assertEqual(closing['runtime']['state'],'closing')
                self.assertNotIn('closure',closing)
                for state in ('not_found','shutdown'):
                    unverified=self.observe(new,state)
                    self.assertNotEqual(unverified['runtime']['capacity'],'released')
                    self.assertNotIn('executionEnded',unverified['runtime'])
                    self.assertNotIn('completedAttempt',unverified)
                    self.reply(new,state=state,fresh=True,expect=2,force=True)

    def test_unattributed_terminal_payloads_cannot_end_current_submission(self):
        old=self.setup_worker()
        self.write_receipt(old)
        new=self.register(self.reply(old))
        path=self.write_receipt(new)
        receipt=json.loads(path.read_text())
        payloads=[None,'summary only','{}',json.dumps([])]
        for field in ('rq','module','attempt','agent_id'):
            wrong=dict(receipt,**{field:'wrong-'+field})
            payloads.append(json.dumps(wrong))
            missing=dict(receipt)
            missing.pop(field)
            payloads.append(json.dumps(missing))
        payloads.append(json.dumps(dict(receipt,summary='different from valid current receipt')))
        for payload in payloads:
            with self.subTest(payload=payload):
                unverified=self.raw_wait(new,{'completed':payload})
                self.assertNotIn('executionEnded',unverified['runtime'])
                self.assertNotIn('completedAttempt',unverified)
                self.assertFalse(self.cmd('collect')['deliveryReady'])
                self.reply(new,state='completed',fresh=True,expect=2,force=True)
        for raw in ({'errored':'unattributed host error'},'interrupted','shutdown'):
            unverified=self.raw_wait(new,raw)
            self.assertNotIn('executionEnded',unverified['runtime'])
            self.assertFalse(self.cmd('collect')['deliveryReady'])
            self.reply(new,state=unverified['runtime']['state'],fresh=True,expect=2,force=True)

    def test_current_json_receipt_end_proof_and_close_resume_reuse_chain(self):
        old=self.setup_worker()
        self.write_receipt(old)
        new=self.register(self.reply(old))
        path=self.write_receipt(new)
        payload=path.read_text()
        path.unlink()
        unverified=self.raw_wait(new,{'completed':payload})
        self.assertNotIn('executionEnded',unverified['runtime'])
        self.reply(new,state='completed',fresh=True,expect=2,force=True)
        path.write_text(payload)
        for _ in range(2):
            completed=self.raw_wait(new,{'completed':payload})
            self.assertTrue(completed['runtime']['executionEnded'])
            self.assertEqual(completed['runtime']['endProof']['scope']['submissionId'],new['submissionId'])
            self.assertEqual(completed['completedAttempt'],new['attempt'])
            self.assertTrue(self.cmd('collect')['deliveryReady'])
        path.write_text(json.dumps(dict(json.loads(payload),summary='receipt edited after completion')))
        self.assertFalse(self.cmd('collect')['deliveryReady'])
        path.write_text(payload)
        closed=self.observe(new,'completed',tool='close_agent')
        self.assertEqual(closed['runtime']['capacity'],'released')
        self.assertTrue(self.cmd('collect')['deliveryReady'])
        closed=self.observe(new,'not_found')
        self.assertEqual(closed['runtime']['state'],'closed')
        self.observe(new,'pending_init',tool='resume_agent')
        for _ in range(3):
            recovered=self.observe(new,'pending_init')
            self.assertTrue(recovered['runtime']['resumeAfterEnded'])
            self.assertTrue(self.cmd('collect')['deliveryReady'])
        # No new submission: the verified pre-resume end also supports a real
        # close of the idle recovery, without inventing a new completed turn.
        recovered_close=self.observe(new,'pending_init',tool='close_agent')
        self.assertEqual(recovered_close['runtime']['capacity'],'released')
        self.observe(new,'pending_init',tool='resume_agent')
        next_round=self.reply(new,state='pending_init')
        self.assertEqual(next_round['agentId'],new['agentId'])
        self.assertNotEqual(next_round['attempt'],new['attempt'])
        self.assertNotIn('executionEnded',next_round['runtime'])
        registered=self.register(next_round)
        self.raw_wait(registered,{'completed':payload})
        self.reply(registered,state='completed',expect=2,force=True)

    def resumed_worker(self, module):
        d=self.setup_worker(module)
        self.write_receipt(d)
        self.observe(d)
        self.observe(d,'completed',tool='close_agent')
        return self.observe(d,'pending_init',tool='resume_agent')

    def test_resume_proof_survives_one_and_multiple_pending_waits(self):
        for waits in (1,3):
            with self.subTest(waits=waits):
                d=self.resumed_worker('resume-'+str(waits))
                proof=d['runtime']['resumeProof']
                for _ in range(waits):
                    event=self.event(d,'wait_agent',dict(targets=[d['agentId']],timeout_ms=10000),
                                     dict(status={d['agentId']:'pending_init'},timed_out=True))
                    d=self.cmd('observe',d['module'],'--attempt',d['attempt'],'--agent-id',d['agentId'],
                               '--tool','wait_agent','--evidence-file',event)
                    self.assertTrue(d['runtime']['resumeAfterEnded'])
                    self.assertEqual(d['runtime']['resumeProof'],proof)
                    self.assertEqual(d['completedAttempt'],d['attempt'])
                    self.assertEqual(d['runtime']['state'],'pending_init')
                    self.assertEqual(d['runtime']['nativeState'],'pending_init')
                    self.assertNotIn('executionEnded',d['runtime'])
                n=self.cmd('reply',d['module'],'--text-file',self.note,'--session','reuse',
                           '--reuse-reason','Same defect after idle resume waits',
                           '--observed-agent-id',d['agentId'],'--observed-state','pending_init')
                self.assertEqual(n['agentId'],d['agentId'])
                self.assertNotEqual(n['attempt'],d['attempt'])
                self.assertNotIn('resumeAfterEnded',n['runtime'])
                self.assertNotIn('resumeProof',n['runtime'])
                self.assertNotIn('completedAttempt',n)
                # A new attempt before send and its accepted submission are both
                # new scopes; neither can reuse the old recovery permission.
                self.reply(n,state='unknown',expect=2,force=True)
                current=self.register(n)
                pending=self.observe(current,'pending_init')
                self.assertNotIn('resumeAfterEnded',pending['runtime'])
                self.assertNotIn('resumeProof',pending['runtime'])
                self.assertNotIn('completedAttempt',pending)
                self.reply(current,state='pending_init',expect=2,force=True)

    def test_new_and_active_pending_cannot_gain_resume_permission(self):
        for active in (False,True):
            with self.subTest(active=active):
                d=self.setup_worker('pending-'+str(active))
                if active:
                    self.observe(d,'running')
                pending=self.observe(d,'pending_init')
                self.assertNotIn('resumeAfterEnded',pending['runtime'])
                before=self.get_record(d['module'])
                self.reply(d,state='pending_init',expect=2,force=True)
                self.assertEqual(self.get_record(d['module']),before)

    def test_resume_permission_expires_after_safety_state_changes(self):
        for state in ('running','not_found','errored'):
            with self.subTest(state=state):
                d=self.resumed_worker('changed-'+state)
                changed=self.observe(d,state)
                self.assertEqual(changed['runtime']['state'],state)
                self.assertNotIn('resumeAfterEnded',changed['runtime'])
                self.assertNotIn('completedAttempt',changed)
                pending=self.observe(d,'pending_init')
                self.assertNotIn('resumeProof',pending['runtime'])
                self.assertNotIn('completedAttempt',pending)
                self.reply(d,state='pending_init',expect=2,force=True)

    def test_unknown_observation_never_grants_resume_or_completion(self):
        for resumed in (False,True):
            with self.subTest(resumed=resumed):
                module='unknown-'+str(resumed)
                d=self.resumed_worker(module) if resumed else self.setup_worker(module)
                before=self.get_record(module)
                self.observe(d,{'unknown':'not a recognized host status'},expect=2)
                self.assertEqual(self.get_record(module),before)
                self.reply(d,state='unknown',expect=2,force=True)
                self.assertEqual(self.get_record(module),before)
                self.assertNotIn('executionEnded',before['runtime'])

    def test_resume_proof_does_not_cross_dispatch_identity_or_attempt(self):
        # Change only the local scope to model an independently reconciled
        # dispatch/identity. A stale proof must not survive its next observation.
        for field,value in (('dispatchEvidence',{'sha256':'new-submission'}),
                            ('agentId','replacement-agent'),('attempt','replacement-attempt')):
            with self.subTest(field=field):
                d=self.resumed_worker('scope-'+field)
                d[field]=value
                (self.c/'v2'/f"{d['module']}.json").write_text(json.dumps(d))
                pending=self.observe(d,'pending_init')
                self.assertNotIn('resumeAfterEnded',pending['runtime'])
                self.assertNotIn('resumeProof',pending['runtime'])
                self.assertNotIn('completedAttempt',pending)
                self.reply(d,state='pending_init',expect=2,force=True)

    def test_resume_not_found_keeps_closed_proof_and_allows_only_handoff_fresh(self):
        d=self.setup_worker()
        self.write_receipt(d)
        self.observe(d)
        self.observe(d,'completed',tool='close_agent')
        lost=self.observe(d,'not_found',tool='resume_agent')
        self.assertEqual(lost['runtime']['state'],'closed')
        self.assertTrue(lost['runtime']['resumeFailed'])
        self.cmd('reply','api','--text-file',self.note,'--session','reuse',
                 '--reuse-reason','same issue','--observed-agent-id',d['agentId'],'--observed-state','closed',expect=2)
        n=self.cmd('reply','api','--text-file',self.note,'--session','fresh',
                 '--fresh-reason','Confirmed closed agent unavailable to resume; current handoff is preserved',
                 '--observed-agent-id',d['agentId'],'--observed-state','closed')
        self.assertEqual(n['worktree'],d['worktree'])
        self.assertNotEqual(n['attempt'],d['attempt'])

    def test_retired_agent_capacity_remains_visible_after_fresh(self):
        old=self.setup_worker()
        self.write_receipt(old)
        n=self.reply(old,fresh=True)
        new=self.register(n,'replacement')
        old_closed=self.observe(old,'completed',tool='close_agent')
        self.assertEqual(old_closed['agentId'],old['agentId'])
        self.observe(old,'not_found')
        status=self.cli('status','--coord',self.c)['jobs'][0]
        self.assertEqual(status['agentId'],new['agentId'])
        self.assertEqual(status['runtime']['capacity'],'occupied')
        self.assertEqual(status['retiredAgents'][0]['runtime']['capacity'],'released')
        self.observe(old,'pending_init',tool='resume_agent',expect=2)

    def test_old_evidence_cannot_end_new_attempt(self):
        old=self.setup_worker()
        old_event=self.event(old,'wait_agent',dict(targets=[old['agentId']],timeout_ms=10000),
                             dict(status={old['agentId']:{'completed':'old'}},timed_out=False))
        self.write_receipt(old)
        n=self.reply(old)
        current=self.register(n)
        self.cmd('observe','api','--attempt',current['attempt'],'--agent-id',current['agentId'],
                 '--tool','wait_agent','--evidence-file',old_event,expect=2)
        self.assertEqual(self.get_record()['runtime']['state'],'unknown')

    def test_failed_and_blocked_unbound_assets_survive_collect_and_fresh(self):
        for result in ('failed','blocked'):
            m='unbound-'+result
            d=self.cmd('prepare',m,'--task',self.task)
            d=self.register(d,'agent-'+m)
            wt=self.root/m
            self.git('worktree','add','-b',m,wt,self.fleet['integrationBranch'])
            (wt/'partial.txt').write_text('preserve this uncommitted asset')
            self.write_receipt(dict(d,worktree=str(wt)),result=result,fallback=True,
                               tests=[dict(command='fixture failing check',result='failed',evidence='actual partial.txt')])
            self.assertIsNone(self.get_record(m)['worktree'])
            self.cmd('collect',m)
            self.assertEqual(self.get_record(m)['worktree'],str(wt))
            n=self.reply(self.get_record(m),fresh=True)
            self.assertEqual(n['worktree'],str(wt))
            self.assertEqual((wt/'partial.txt').read_text(),'preserve this uncommitted asset')
            self.assertIn(str(wt),Path(n['promptFile']).read_text())

    def test_fresh_without_reason_does_not_mutate_assets(self):
        d=self.setup_worker()
        path=self.write_receipt(d)
        self.observe(d)
        before=(self.c/'v2/api.json').read_bytes(),path.read_bytes()
        self.reply(d,fresh=True,fresh_reason='',expect=2)
        self.assertEqual(before,((self.c/'v2/api.json').read_bytes(),path.read_bytes()))

    def test_legacy_app_assets_are_collectable_but_never_native_identity(self):
        d=self.setup_worker()
        self.write_receipt(d)
        legacy=self.get_record()
        legacy.pop('executionKind')
        legacy.pop('agentId')
        (self.c/'v2/api.json').write_text(json.dumps(legacy))
        receipt=json.loads((self.c/'api.receipt.json').read_text())
        receipt.pop('agent_id')
        (self.c/'api.receipt.json').write_text(json.dumps(receipt))
        before=(self.c/'v2/api.json').read_bytes()
        out=self.cmd('collect')
        self.assertEqual(out['executionKind'],'legacy-app')
        self.assertIsNone(out['agentId'])
        self.assertFalse(out['deliveryReady'])
        self.cmd('dispatch',expect=2)
        self.cmd('bind','api','--attempt',d['attempt'],'--worktree',d['worktree'],expect=2)
        self.register(d,'new',expect=2)
        self.reply(d,fresh=True,expect=2)
        self.assertEqual((self.c/'v2/api.json').read_bytes(),before)

    def test_capacity_deferral_and_uncertain_dispatch_never_spawn(self):
        d=self.cmd('prepare','api','--task',self.task)
        problem=self.root/'actual-error.txt'
        problem.write_text('FIXTURE: native capacity refusal; no agent was created')
        out=self.cmd('defer','api','--attempt',d['attempt'],'--reason','capacity','--evidence-file',problem)
        self.assertEqual(out['state'],'blocked-capacity')
        self.assertIsNone(out['agentId'])
        self.assertEqual(self.cmd('dispatch')['state'],'blocked-capacity')
        self.cmd('defer','api','--attempt',d['attempt'],'--reason','uncertain','--evidence-file',problem)
        self.cmd('dispatch',expect=2)
        self.cmd('defer','api','--attempt',d['attempt'],'--reason','capacity','--evidence-file',problem,expect=2)
        registered=self.register(d,'found-after-reconcile')
        self.assertEqual(registered['attempt'],d['attempt'])
        self.cmd('defer','api','--attempt',d['attempt'],'--reason','capacity','--evidence-file',problem,expect=2)

    def test_unique_asset_writer_binding_is_enforced(self):
        first=self.setup_worker()
        other=self.cmd('prepare','other','--task',self.task)
        self.cmd('bind','other','--attempt',other['attempt'],'--worktree',first['worktree'],expect=2)
        self.assertIsNone(self.get_record('other')['worktree'])

    def test_non_code_artifacts_reading_map_and_receipt_close_loop(self):
        workspace=self.root/'research-space'
        workspace.mkdir()
        sources=workspace/'sources.json'
        sources.write_text(json.dumps({'version':2,'observations':[4,7],'unknown':['third source missing']}))
        card=self.root/'research-task.md'
        card.write_text('整体目标：评估三条来源。作用：交付可复算汇总。\n'
                        f'阅读地图：先 {sources} #observations v2，再 #unknown；不加载历史。\n'
                        '最小共享背景：facts-v2，仅相关片段，唯一维护者=scout。\n'
                        '成功条件：合计11，第三来源仍未知；证据与未知项都保留。失败：将缺源当0。')
        f=self.cli('init','--workspace','--cwd',workspace)
        c=Path(f['coord'])
        self.c=c
        self.rq=f['rq']
        self.fleet=f
        d=self.cmd('prepare','research','--task',card,'--role','scout')
        d=self.register(d,'research-agent')
        outdir=workspace/'deliverable-research'
        outdir.mkdir()
        d=self.cmd('bind','research','--attempt',d['attempt'],'--worktree',outdir)
        observations=json.loads(sources.read_text())
        output={'sum':sum(observations['observations']),'unknown':observations['unknown'],'sourceVersion':observations['version']}
        (outdir/'result.json').write_text(json.dumps(output))
        self.assertEqual(output['sum'],11)
        self.assertEqual(len(output['unknown']),1)
        self.write_receipt(d,commit='',summary='Two sources total 11; third source remains unknown')
        self.observe(d)
        self.assertTrue(self.cmd('collect','research')['deliveryReady'])
        prompt=(c/'research.prompt.md').read_text()
        self.assertIn(str(sources),prompt)
        self.assertIn('facts-v2',prompt)
        other=self.cmd('prepare','other','--task',card,'--role','scout')
        self.cmd('bind','other','--attempt',other['attempt'],'--worktree',outdir/'nested',expect=2)

    def test_non_git_author_execute_has_artifact_instructions_and_checks(self):
        workspace=self.root/'non-git-acceptance'
        workspace.mkdir()
        f=self.cli('init','--workspace','--cwd',workspace)
        self.c=Path(f['coord']);self.fleet=f;self.rq=f['rq']
        card=self.root/'artifact-acceptance.md'
        card.write_text('整体目标：核研究产物。作用：独立验收。阅读地图：facts-v3#units；先author清单再execute复算。'
                        '成功：总数11且缺源明确。不得修改来源；不用Git。')
        d=self.cmd('prepare','verify','--task',card,'--role','verify','--phase','author')
        d=self.register(d,'artifact-verifier')
        assets=workspace/'verify-assets';assets.mkdir()
        (assets/'checklist.md').write_text('复算总和与缺源；facts-v3')
        d=self.cmd('bind','verify','--attempt',d['attempt'],'--worktree',assets)
        self.write_receipt(d,commit='',tests=[dict(command='author artifact checklist',result='not-run',evidence=str(assets/'checklist.md'))])
        self.assertTrue(self.cmd('validate-receipt','verify')['valid'])
        n=self.reply(d,phase='execute')
        prompt=Path(n['promptFile']).read_text()
        self.assertIn('来源/产物版本与内容哈希',prompt)
        self.assertNotIn('将最新 None 合入',prompt)
        self.assertNotIn('先提交并 land',prompt)
        current=self.register(n)
        report=assets/'report.json';report.write_text(json.dumps(dict(total=11,unknown=['missing source'],factsVersion=3)))
        self.write_receipt(current,commit='',tests=[dict(command='recompute 4+7 and preserve gap',result='passed',evidence=str(report))])
        self.observe(current)
        self.assertTrue(self.cmd('collect','verify')['deliveryReady'])
        self.assertEqual(json.loads(report.read_text())['total'],11)

    def test_concurrent_bind_cannot_assign_one_tree_to_two_results(self):
        first=self.cmd('prepare','writer-a','--task',self.task)
        second=self.cmd('prepare','writer-b','--task',self.task)
        wt=self.root/'contended-tree'
        self.git('worktree','add','-b','contended-tree',wt,self.fleet['integrationBranch'])
        processes=[subprocess.Popen([str(BIN),'bind','--coord',str(self.c),'--module',d['module'],
                    '--attempt',d['attempt'],'--worktree',str(wt)],env=self.env,text=True,
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE) for d in (first,second)]
        for proc in processes:
            proc.communicate(timeout=10)
        self.assertEqual(sorted(p.returncode for p in processes),[0,2])
        owners=[self.get_record(m)['worktree'] for m in ('writer-a','writer-b')]
        self.assertEqual(owners.count(str(wt)),1)

    def test_malformed_native_event_is_rejected_without_record_mutation(self):
        d=self.cmd('prepare','api','--task',self.task)
        before=(self.c/'v2/api.json').read_bytes()
        event=self.event(d,None,dict(fork_context=False),dict(agent_id='agent'))
        self.cmd('register','api','--attempt',d['attempt'],'--agent-id','agent','--evidence-file',event,expect=2)
        self.assertEqual((self.c/'v2/api.json').read_bytes(),before)


class TriggerTests(unittest.TestCase):
    def test_prompt_routing_and_worker_exclusion(self):
        for prompt,expected in [('多 session 模式完成',True),('让子会话处理研究',True),('fix with fleet',True),('普通修改',False),('审计本技能 multi-session-dev 的文档',False),('用多智能体实现搜索',True),('维护本技能，请让子智能体审查实现',True),('用 subagent 查代码',True),('⟦FLEET-WORKER⟧ 多 session',False),('/multi-session-dev 做',False)]:
            r=subprocess.run([str(ROOT/'scripts/cc-fleet-trigger-hook')],input=json.dumps({'prompt':prompt}),text=True,capture_output=True,env={k:v for k,v in os.environ.items() if k!='FLEET_ROLE'})
            self.assertEqual(r.returncode,0)
            self.assertEqual(bool(r.stdout),expected,prompt)
        r=subprocess.run([str(ROOT/'scripts/cc-fleet-trigger-hook')],input='bad JSON',text=True,capture_output=True)
        self.assertEqual((r.returncode,r.stdout),(0,''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
