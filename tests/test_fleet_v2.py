#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, tempfile, unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
FLEET=ROOT/'scripts/cc-fleet'
FAKE=r'''#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path(os.environ['FAKE_DB']); db=json.loads(p.read_text()) if p.exists() else {'jobs':[],'threads':{},'calls':[]}
a=sys.argv[1:]
def save(): p.write_text(json.dumps(db))
if pathlib.Path(sys.argv[0]).name=='claude':
 db['calls'].append(a); save()
 if a[:3]==['agents','--json','--all']: print(json.dumps(db['jobs']));sys.exit()
 if '--bg' in a:
  n=a[a.index('--name')+1];i=f'{len(db["jobs"])+1:08x}'
  db['jobs'].append(dict(id=i,sessionId='sid-'+i,name=n,cwd=os.getcwd(),state='working'))
  save();print('arbitrary localized launch output');sys.exit()
 if a[0]=='stop':
  next(j for j in db['jobs'] if j['id']==a[1])['state']='stopped';save();sys.exit()
 if a[0]=='logs': print('worker transcript');sys.exit()
 sys.exit(3)
method=a[-2];params=json.load(sys.stdin);db['calls'].append([method,params])
if method=='threadSection/list':
 result={'data':[{'id':'server-section-id','name':'子 session'}], 'nextCursor':None}
elif method=='thread/section/move':
 if os.environ.get('FAKE_FAIL_SECTION'): save();sys.exit(8)
 result={}
elif method=='thread/start':
 i='thread-'+str(len(db['threads'])+1);t=dict(id=i,cwd=params['cwd'],status={'type':'idle'},turns=[]);db['threads'][i]=t;result={'thread':t}
elif method=='thread/read': result={'thread':db['threads'][params['threadId']]}
elif method=='turn/start':
 if os.environ.get('FAKE_FAIL_TURN'): save();sys.exit(9)
 t=db['threads'][params['threadId']];u=dict(id='turn-'+str(len(t['turns'])+1),status='inProgress');t['turns'].append(u);t['status']={'type':'active'};result={'turn':u}
elif method=='turn/interrupt':
 t=db['threads'][params['threadId']];t['turns'][-1]['status']='interrupted';t['status']={'type':'idle'};result={}
else: result={}
save();print(json.dumps(result))
'''

class FleetTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='fleet-v2-'); self.root=pathlib.Path(self.tmp.name)
  self.repo=self.root/'repo with spaces';self.repo.mkdir()
  # CC_FLEET_PANEL=0：测试绝不去动真实 Ghostty / 真实面板注册表；面板路径由 test_app_server_dispatch_opens_ghostty_panel 用假脚本单独测。
  self.env=dict(os.environ,FAKE_DB=str(self.root/'db.json'),CLAUDE_FLEET_CONFIG=str(self.root/'missing.json'),CODEX_MULTI_SESSION_CONFIG=str(self.root/'absent-route.json'),CC_FLEET_PANEL='0')
  for n in ('claude','app-call'):
   p=self.root/n;p.write_text(FAKE);p.chmod(0o755)
  self.env.update(CLAUDE_CLI_PATH=str(self.root/'claude'),CODEX_APP_CALL_BIN=str(self.root/'app-call'))
  self.git('init','-b','main'); self.git('config','user.name','Fleet Test'); self.git('config','user.email','fleet@example.invalid')
  (self.repo/'base.txt').write_text('baseline');self.git('add','.');self.git('commit','-m','baseline')
  self.base=self.git('rev-parse','HEAD');self.task=self.root/'task.md';self.task.write_text('Implement a bounded module and verify it.')
 def tearDown(self):
  for f in self.repo.glob('.git/fleet/*/fleet.json'):
   rq=json.loads(f.read_text())['rq'];shutil.rmtree(pathlib.Path(tempfile.gettempdir())/'fleet-v2-inbox'/rq,ignore_errors=True)
  self.tmp.cleanup()
 def git(self,*a,cwd=None):
  return subprocess.check_output(['git','-C',str(cwd or self.repo),*a],stderr=subprocess.DEVNULL,text=True).strip()
 def cli(self,*a,ok=True,env=None):
  r=subprocess.run([str(FLEET),*map(str,a)],env=env or self.env,text=True,capture_output=True)
  if ok:self.assertEqual(r.returncode,0,r.stderr)
  else:self.assertNotEqual(r.returncode,0);return r
  return json.loads(r.stdout)
 def setup_worker(self,host='claude-code',backend='codex',role='developer',module='api'):
  f=self.cli('init','--cwd',self.repo,'--host',host,'--owner-id','main-123');c=pathlib.Path(f['coord'])
  d=self.cli('prepare','--coord',c,'--module',module,'--backend',backend,'--task',self.task,'--role',role,*(['--permissions','inherit'] if host=='codex-app' and backend=='codex' else []))
  return c,d,f
 def db(self):return json.loads((self.root/'db.json').read_text())
 def receipt(self,c,d,**kw):
  r=dict(version=2,rq=json.loads((c/'fleet.json').read_text())['rq'],module=d['module'],attempt=d['attempt'],result='done',summary='finished',tests=[dict(command='check',result='passed',evidence='passed')],commit='')
  if d['role'] in ('verify','integ'):r['commit']=self.git('rev-parse','HEAD',cwd=d['worktree'])
  r.update(kw);(c/(d['module']+'.receipt.json')).write_text(json.dumps(r))
 def test_four_routes_and_native_pending(self):
  for host,backend,transport in [('codex-app','codex','native'),('codex-app','claude','claude-bg'),('claude-code','codex','app-server'),('claude-code','claude','claude-bg'),('codex-cli','codex','app-server')]:
   with self.subTest(host=host,backend=backend):
    c,d,_=self.setup_worker(host,backend);self.assertEqual(d['transport'],transport)
    out=self.cli('dispatch','--coord',c,'--module','api')
    if transport=='native':
     self.assertIsNone(d['worktree']);self.assertIn('nextAction',out)
     pending=self.cli('register','--coord',c,'--module','api','--client-thread-id','client-1')
     self.assertEqual(pending['state'],'setting-up');self.assertIsNone(pending['sessionId'])
     ready=self.cli('register','--coord',c,'--module','api','--session-id','native-1')
     self.assertEqual(ready['sessionId'],'native-1')
    else:
     self.assertEqual(out['state'],'running');self.assertTrue(out['sessionId']);self.assertNotEqual(d['worktree'],str(self.repo))
     self.assertEqual(self.git('rev-parse','HEAD',cwd=d['worktree']),self.base)
     self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'running')
    self.assertEqual(self.git('rev-parse','HEAD'),self.base)
 def panel_env(self,flag='1'):
  # 假的 panel-open：记录 argv 与 CC_FLEET_PANEL_CWD；注册表指到临时文件（真 cc-fleet-panel-register 认这个变量）。
  fake=self.root/'panel-open';log=self.root/'panel-open.log'
  fake.write_text('#!/bin/sh\nprintf \'%s|%s\\n\' "$*" "$CC_FLEET_PANEL_CWD" >> "$PANEL_LOG"\n');fake.chmod(0o755)
  return dict(self.env,CC_FLEET_PANEL=flag,CC_FLEET_PANEL_OPEN_BIN=str(fake),PANEL_LOG=str(log),CC_FLEET_PANEL_REGISTRY=str(self.root/'coords.json')),log
 def test_app_server_dispatch_opens_ghostty_panel(self):
  env,log=self.panel_env()
  c,d,f=self.setup_worker();out=self.cli('dispatch','--coord',c,'--module','api',env=env)
  self.assertEqual(out['panel'],dict(registered=True,panelOpened=True))
  self.assertEqual(log.read_text().splitlines(),[f'--quiet|{f["repo"]}'])
  reg=json.loads((self.root/'coords.json').read_text())['coords']
  self.assertEqual([(x['coord'],x['rq']) for x in reg],[(str(c),f['rq'])])
  self.assertTrue((c/'owner.meta').exists())
  # Claude 后端的 worker 不上 Codex 面板；全局开关 0 时也不碰面板
  c2,_,_=self.setup_worker(backend='claude',module='ui');out=self.cli('dispatch','--coord',c2,'--module','ui',env=env)
  self.assertIsNone(out['panel']);self.assertEqual(len(log.read_text().splitlines()),1)
  env0,log0=self.panel_env('0');c3,_,_=self.setup_worker(module='svc');out=self.cli('dispatch','--coord',c3,'--module','svc',env=env0)
  self.assertIsNone(out['panel']);self.assertEqual(len(log0.read_text().splitlines()),1)
  # 面板脚本失败只在输出里标 False，派发本身仍是 running
  (self.root/'panel-open').write_text('#!/bin/sh\nexit 7\n');c4,_,_=self.setup_worker(module='job');out=self.cli('dispatch','--coord',c4,'--module','job',env=env)
  self.assertEqual(out['state'],'running');self.assertEqual(out['panel'],dict(registered=True,panelOpened=False))
 def test_duplicate_dispatch_and_module_rejected(self):
  c,d,_=self.setup_worker();self.cli('dispatch','--coord',c,'--module','api')
  self.cli('dispatch','--coord',c,'--module','api',ok=False)
  self.cli('prepare','--coord',c,'--module','api','--backend','codex','--task',self.task,ok=False)
  self.assertEqual(sum(x[0]=='thread/start' for x in self.db()['calls']),1)
 def test_uncertain_turn_keeps_thread_and_reconcile(self):
  c,d,_=self.setup_worker();e=dict(self.env,FAKE_FAIL_TURN='1')
  self.cli('dispatch','--coord',c,'--module','api',env=e,ok=False)
  saved=json.loads((c/'v2/api.json').read_text());self.assertEqual(saved['state'],'launch-uncertain');self.assertTrue(saved['sessionId'])
  self.assertTrue(pathlib.Path(d['worktree']).exists())
  self.cli('dispatch','--coord',c,'--module','api',ok=False)
  rec=self.cli('reconcile','--coord',c,'--module','api');self.assertEqual(rec['sessionId'],saved['sessionId'])
 def test_receipt_must_land_and_match_attempt(self):
  c,d,f=self.setup_worker();self.cli('dispatch','--coord',c,'--module','api')
  wt=pathlib.Path(d['worktree']);(wt/'module.txt').write_text('implemented');self.git('add','.',cwd=wt);self.git('commit','-m','module',cwd=wt)
  sha=self.git('rev-parse','HEAD',cwd=wt);self.receipt(c,d,commit=sha)
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'needs-review')
  subprocess.run([str(ROOT/'scripts/cc-fleet-land'),f['rq']],cwd=wt,check=True,capture_output=True)
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'done')
  self.assertEqual(self.git('rev-parse','HEAD'),self.base)
  self.receipt(c,d,commit=sha,attempt='old');self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'needs-review')
  self.receipt(c,d,commit=sha,tests=[dict(result='failed',evidence='assertion failure')]);self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'needs-review')
 def test_acceptance_without_execution_cannot_be_done(self):
  for role in ('verify','integ'):
   with self.subTest(role=role):
    c,d,_=self.setup_worker(role=role)
    self.receipt(c,d,tests=[dict(command='browser',result='not-run',evidence='environment unavailable')])
    self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'needs-review')
    self.receipt(c,d,tests=[dict(command='smoke',result='passed',evidence='trace'),dict(command='branch',result='not-run',evidence='environment unavailable')])
    self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'needs-review')
    self.receipt(c,d,result='blocked',tests=[dict(command='browser',result='not-run',evidence='environment unavailable')])
    self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'blocked')
    self.receipt(c,d,result='failed',tests=[dict(command='browser',result='failed',evidence='wrong final state')])
    self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'failed')
    self.receipt(c,d,tests=[dict(command='browser',result='passed',evidence='page trace')])
    self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'done')
 def test_acceptance_must_match_current_integration(self):
  c,d,f=self.setup_worker(role='verify')
  self.receipt(c,d,commit='')
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'needs-review')
  self.receipt(c,d)
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'done')
  self.git('commit','--allow-empty','-m','integration changed')
  self.git('update-ref','refs/heads/'+f['integrationBranch'],self.git('rev-parse','HEAD'))
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'needs-review')
  self.git('merge','--ff-only',f['integrationBranch'],cwd=d['worktree'])
  self.receipt(c,d)
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'done')
 def test_idle_without_receipt_needs_review(self):
  c,d,_=self.setup_worker();self.cli('dispatch','--coord',c,'--module','api');db=self.db()
  t=next(iter(db['threads'].values()));t['status']={'type':'idle'};t['turns'][-1]['status']='completed'
  (self.root/'db.json').write_text(json.dumps(db));self.assertEqual(self.cli('wait','--coord',c,'--timeout','0')['jobs'][0]['state'],'needs-review')
 def test_steer_then_idle_start_and_stop(self):
  c,d,_=self.setup_worker(role='scout');self.cli('dispatch','--coord',c,'--module','api');self.receipt(c,d)
  text=self.root/'reply.txt';text.write_text('Please check the second case.')
  out=self.cli('reply','--coord',c,'--module','api','--text-file',text)
  self.assertNotEqual(out['attempt'],d['attempt']);self.assertFalse((c/'api.receipt.json').exists())
  self.assertEqual(self.db()['calls'][-1][0],'turn/steer')
  self.cli('stop','--coord',c,'--module','api');self.assertTrue(pathlib.Path(d['worktree']).exists())
  self.cli('reply','--coord',c,'--module','api','--text-file',text);self.assertEqual(self.db()['calls'][-1][0],'turn/start')
 def test_claude_public_lifecycle(self):
  c,d,_=self.setup_worker(backend='claude');out=self.cli('dispatch','--coord',c,'--module','api')
  self.assertEqual(out['shortId'],'00000001');self.cli('reconcile','--coord',c,'--module','api')
  self.cli('stop','--coord',c,'--module','api');self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'stopped')
  self.assertTrue(pathlib.Path(d['worktree']).exists())
 def test_native_reply_outputs_instruction_without_backend_send(self):
  c,d,_=self.setup_worker(host='codex-app');self.cli('register','--coord',c,'--module','api','--session-id','native')
  p=self.root/'text';p.write_text('Continue.');out=self.cli('reply','--coord',c,'--module','api','--text-file',p)
  self.assertIn('send_message_to_thread',out['nextAction']);self.assertIn(out['attempt'],out['prompt']);self.assertFalse(any(x[0] in ('thread/start','turn/start','turn/steer') for x in self.db()['calls']))
 def test_bind_checks_repo_and_baseline(self):
  c,d,_=self.setup_worker();self.cli('bind','--coord',c,'--module','api','--worktree',self.repo,ok=False)
  self.cli('bind','--coord',c,'--module','api','--worktree',d['worktree'])
 def test_temp_receipt_is_collected_durably(self):
  c,d,f=self.setup_worker(role='scout');self.cli('dispatch','--coord',c,'--module','api');self.receipt(c,d,worktree=d['worktree'])
  inbox=pathlib.Path(tempfile.gettempdir())/'fleet-v2-inbox'/f['rq']/(d['module']+'-'+d['attempt']+'.receipt.json')
  inbox.parent.mkdir(parents=True,exist_ok=True);(c/'api.receipt.json').rename(inbox)
  self.assertEqual(self.cli('status','--coord',c,env=dict(self.env,TMPDIR=str(self.root)))['jobs'][0]['state'],'done')
  self.cli('collect','--coord',c,'--module','api');inbox.unlink()
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'done')
 def test_native_receipt_binds_verified_worktree(self):
  c,d,f=self.setup_worker(host='codex-app',role='scout');wt=self.root/'app worktree'
  self.git('worktree','add','--detach',str(wt),f['integrationBranch'])
  self.cli('register','--coord',c,'--module','api','--session-id','native')
  self.receipt(c,d,worktree=str(wt));self.cli('collect','--coord',c,'--module','api')
  self.assertEqual(json.loads((c/'v2/api.json').read_text())['worktree'],str(wt.resolve()))
 def test_claude_main_defaults_gpt6_low_and_preserves_resume(self):
  f=self.cli('init','--cwd',self.repo,'--host','claude-code','--owner-id','main')
  c=pathlib.Path(f['coord']);d=self.cli('prepare','--coord',c,'--module','api','--task',self.task)
  self.assertEqual(d['backend'],'codex');self.assertEqual(d['transport'],'app-server')
  self.cli('dispatch','--coord',c,'--module','api')
  calls=self.db()['calls'];start=next(p for m,p in calls if m=='thread/start');turn=next(p for m,p in calls if m=='turn/start')
  self.assertEqual(start['model'],'gpt-6-astra');self.assertEqual(start['modelProvider'],'openai');self.assertEqual(turn['effort'],'low')
  self.cli('stop','--coord',c,'--module','api');t=self.root/'reply';t.write_text('Continue.')
  self.cli('reply','--coord',c,'--module','api','--text-file',t)
  self.assertEqual(self.db()['calls'][-1][1]['effort'],'low')
 def test_full_permissions_dispatch_and_resume(self):
  c,d,_=self.setup_worker();self.cli('dispatch','--coord',c,'--module','api')
  self.cli('stop','--coord',c,'--module','api');p=self.root/'continue';p.write_text('Continue.')
  self.cli('reply','--coord',c,'--module','api','--text-file',p)
  calls=self.db()['calls']
  self.assertTrue(any(m=='thread/resume' for m,p in calls))
  for m,p in calls:
   if m in ('thread/start','thread/resume','turn/start'):
    self.assertEqual(p['approvalPolicy'],'never')
    if m=='turn/start': self.assertEqual(p['sandboxPolicy'],{'type':'dangerFullAccess'})
    else: self.assertEqual(p['sandbox'],'danger-full-access')
 def test_claude_full_permissions(self):
  c,d,_=self.setup_worker(backend='claude');self.cli('dispatch','--coord',c,'--module','api')
  self.assertIn('--dangerously-skip-permissions',self.db()['calls'][0])
 def test_app_full_defaults_to_app_server(self):
  f=self.cli('init','--cwd',self.repo,'--host','codex-app');c=f['coord']
  d=self.cli('prepare','--coord',c,'--module','api','--task',self.task)
  self.assertEqual(d['transport'],'app-server')
 def test_inherit_does_not_force_permissions(self):
  c,d,_=self.setup_worker(host='codex-cli');d['permissions']='inherit';(c/'v2/api.json').write_text(json.dumps(d));self.cli('dispatch','--coord',c,'--module','api')
  for meth,p in self.db()['calls']:
   if meth in ('thread/start','turn/start'):
    for k in ('approvalPolicy','sandbox','sandboxPolicy','approvalsReviewer','model'):
     self.assertNotIn(k,p)

 def test_sidebar_automatic_and_retry_without_duplicate_thread(self):
  c,d,_=self.setup_worker()
  out=self.cli('dispatch','--coord',c,'--module','api',env=dict(self.env,FAKE_FAIL_SECTION='1'))
  self.assertEqual(out['state'],'running');self.assertEqual(out['sidebar']['state'],'pending')
  out=self.cli('reconcile','--coord',c,'--module','api')
  self.assertEqual(out['sidebar'],dict(state='placed',sectionId='server-section-id'))
  self.assertEqual(sum(x[0]=='thread/start' for x in self.db()['calls']),1)
  count=sum(x[0]=='thread/section/move' for x in self.db()['calls'])
  self.cli('reconcile','--coord',c,'--module','api')
  self.assertEqual(sum(x[0]=='thread/section/move' for x in self.db()['calls']),count)
 def test_sidebar_native_registration(self):
  c,d,_=self.setup_worker(host='codex-app')
  self.cli('register','--coord',c,'--module','api','--client-thread-id','pending')
  self.assertFalse((self.root/'db.json').exists())
  out=self.cli('register','--coord',c,'--module','api','--session-id','native')
  self.assertEqual(out['sidebar']['state'],'placed')

if __name__=='__main__':unittest.main(verbosity=2)
