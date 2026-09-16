#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, tempfile, time, unittest

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
  # CC_FLEET_PANEL=0：测试绝不去动真实 Ghostty；init/dispatch 总会登记面板注册表，一律指到临时文件。
  # 面板路径由 test_app_server_dispatch_opens_ghostty_panel 用假脚本单独测。
  self.env=dict(os.environ,FAKE_DB=str(self.root/'db.json'),CLAUDE_FLEET_CONFIG=str(self.root/'missing.json'),CODEX_MULTI_SESSION_CONFIG=str(self.root/'absent-route.json'),CC_FLEET_PANEL='0',
                CC_FLEET_PANEL_REGISTRY=str(self.root/'coords.json'))
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
  # Claude 后端（claude --bg）同样登记 + 分屏；记下 model/effort 供面板详情展示
  (self.root/'missing.json').write_text(json.dumps({'worker':{'model':'claude-opus-5','effort':'high'}}))
  c2,_,_=self.setup_worker(backend='claude',module='ui');out=self.cli('dispatch','--coord',c2,'--module','ui',env=env)
  self.assertEqual(out['panel'],dict(registered=True,panelOpened=True));self.assertEqual(len(log.read_text().splitlines()),2)
  self.assertEqual(out['claudeProfile'],dict(model='claude-opus-5',effort='high'))
  self.assertEqual(json.loads((c2/'v2'/'ui.json').read_text())['claudeProfile'],dict(model='claude-opus-5',effort='high'))
  # 全局开关 0 只是不开分屏：登记照做，别的主 session 已开的全局面板仍看得到这个任务组
  env0,log0=self.panel_env('0');c3,_,_=self.setup_worker(module='svc');out=self.cli('dispatch','--coord',c3,'--module','svc',env=env0)
  self.assertEqual(out['panel'],dict(registered=True,panelOpened=None));self.assertEqual(len(log0.read_text().splitlines()),2)
  c5,_,_=self.setup_worker(backend='claude',module='web');out=self.cli('dispatch','--coord',c5,'--module','web',env=env0)
  self.assertEqual(out['panel'],dict(registered=True,panelOpened=None));self.assertEqual(len(log0.read_text().splitlines()),2)
  reg=[x['coord'] for x in json.loads((self.root/'coords.json').read_text())['coords']]
  self.assertIn(str(c3),reg);self.assertIn(str(c5),reg)
  # 面板脚本失败只在输出里标 False，派发本身仍是 running
  (self.root/'panel-open').write_text('#!/bin/sh\nexit 7\n');c4,_,_=self.setup_worker(module='job');out=self.cli('dispatch','--coord',c4,'--module','job',env=env)
  self.assertEqual(out['state'],'running');self.assertEqual(out['panel'],dict(registered=True,panelOpened=False))
 def test_init_registers_panel_for_every_transport(self):
  # 建组即登记：native（不走 panel_attach）与关掉分屏的 CLI 路径都能进全局注册表；不开任何分屏
  env,log=self.panel_env('0')
  for host,backend in [('codex-app','codex'),('claude-code','claude'),('claude-code','codex')]:
   with self.subTest(host=host,backend=backend):
    f=self.cli('init','--cwd',self.repo,'--host',host,'--owner-id','main-123',env=env)
    reg=[(x['coord'],x['rq']) for x in json.loads((self.root/'coords.json').read_text())['coords']]
    self.assertIn((f['coord'],f['rq']),reg)
  self.assertFalse(log.exists())
 def test_init_owner_from_claude_code_session_env(self):
  # Claude Code 注入的是 CLAUDE_CODE_SESSION_ID；取不到就只能生成假 controller id，面板判不了主 session 是否已退出
  base={k:v for k,v in self.env.items() if k not in ('CLAUDE_CODE_SESSION_ID','CLAUDE_SESSION_ID','CODEX_THREAD_ID')}
  cases=[('claude-code',dict(CLAUDE_CODE_SESSION_ID='sid-code'),'sid-code','session'),
         ('claude-code',dict(CLAUDE_SESSION_ID='sid-old'),'sid-old','session'),
         ('codex-app',dict(CLAUDE_CODE_SESSION_ID='sid-code'),None,'generated-controller')]
  for host,extra,want,src in cases:
   with self.subTest(host=host,extra=extra):
    f=self.cli('init','--cwd',self.repo,'--host',host,env=dict(base,**extra))
    owner=json.loads((pathlib.Path(f['coord'])/'fleet.json').read_text())['owner']
    self.assertEqual(owner['identitySource'],src)
    if want: self.assertEqual(owner['id'],want)
    else: self.assertTrue(owner['id'].startswith('controller-'))
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
 def test_claude_main_explicit_codex_uses_gpt6_low_and_preserves_resume(self):
  # 2026-09-11 用户纠正需求：Claude 主端未指定时默认派 Claude；gpt-6-astra/low 只作用于显式 --backend codex。
  f=self.cli('init','--cwd',self.repo,'--host','claude-code','--owner-id','main')
  c=pathlib.Path(f['coord']);d=self.cli('prepare','--coord',c,'--module','api','--backend','codex','--task',self.task)
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

 def test_default_backend_follows_host(self):
  for host,backend,transport in [('claude-code','claude','claude-bg'),('codex-cli','codex','app-server'),('codex-app','codex','app-server')]:
   with self.subTest(host=host):
    f=self.cli('init','--cwd',self.repo,'--host',host,'--owner-id','main');c=pathlib.Path(f['coord'])
    d=self.cli('prepare','--coord',c,'--module','api','--task',self.task)
    self.assertEqual((d['backend'],d['transport']),(backend,transport))
  # Claude 主端未指定后端：派发走 claude --bg，绝不启动 Codex thread
  f=self.cli('init','--cwd',self.repo,'--host','claude-code','--owner-id','main');c=pathlib.Path(f['coord'])
  self.cli('prepare','--coord',c,'--module','ui','--task',self.task);self.cli('dispatch','--coord',c,'--module','ui')
  calls=self.db()['calls'];self.assertTrue(any('--bg' in x for x in calls));self.assertFalse(any(x[0]=='thread/start' for x in calls))
 def commit_subproject(self):
  sub=self.repo/'factory';sub.mkdir();(sub/'CLAUDE.md').write_text('sub rules');(sub/'AGENTS.md').write_text('sub pointer')
  self.git('add','.');self.git('commit','-m','subproject');return sub
 def test_worker_starts_in_host_subdir_and_normalizes_worktree(self):
  sub=self.commit_subproject()
  f=self.cli('init','--cwd',sub,'--host','claude-code','--owner-id','main');c=pathlib.Path(f['coord'])
  self.assertEqual(f['subdir'],'factory')
  d=self.cli('prepare','--coord',c,'--module','ui','--role','scout','--task',self.task);wt=pathlib.Path(d['worktree'])
  self.assertEqual(d['cwd'],str(wt/'factory'));self.assertTrue((wt/'factory'/'CLAUDE.md').exists())
  self.assertIn('工作目录 '+d['cwd'],(c/'ui.prompt.md').read_text())
  self.cli('dispatch','--coord',c,'--module','ui')
  self.assertEqual(pathlib.Path(self.db()['jobs'][-1]['cwd']).resolve(),pathlib.Path(d['cwd']).resolve())
  self.assertEqual(self.cli('reconcile','--coord',c,'--module','ui')['state'],'running')
  self.assertEqual(self.cli('bind','--coord',c,'--module','ui','--worktree',d['cwd'])['worktree'],d['worktree'])
  self.receipt(c,d,worktree=d['cwd']);self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['state'],'done')
  # Codex 同样从子项目目录起 thread 与 turn（Codex 只加载 git 根到 cwd 路径上的 AGENTS.md）
  d2=self.cli('prepare','--coord',c,'--module','api','--backend','codex','--task',self.task);self.cli('dispatch','--coord',c,'--module','api')
  calls=self.db()['calls'];start=next(x[1] for x in calls if x[0]=='thread/start');turn=next(x[1] for x in calls if x[0]=='turn/start')
  self.assertEqual((start['cwd'],turn['cwd']),(d2['cwd'],d2['cwd']))
 def test_subdir_override_and_validation(self):
  sub=self.commit_subproject()
  f=self.cli('init','--cwd',sub,'--host','claude-code','--owner-id','main');c=pathlib.Path(f['coord'])
  d=self.cli('prepare','--coord',c,'--module','root','--subdir','','--task',self.task);self.assertEqual(d['cwd'],d['worktree'])
  self.cli('prepare','--coord',c,'--module','bad','--subdir','nope','--task',self.task,ok=False)
  self.cli('prepare','--coord',c,'--module','esc','--subdir','../x','--task',self.task,ok=False)
  self.assertFalse((self.repo/'.claude'/'worktrees'/f"fleet-{f['rq']}-bad").exists())
 def test_worktree_outside_git_dir_and_excluded(self):
  c,d,f=self.setup_worker(backend='claude')
  self.assertNotIn('/.git/',d['worktree']);self.assertTrue(d['worktree'].startswith(str(pathlib.Path(f['repo'])/'.claude'/'worktrees')+'/'))
  self.assertEqual(self.git('status','--porcelain'),'')
  self.setup_worker(backend='claude',module='ui')
  ex=(pathlib.Path(f['commonDir'])/'info'/'exclude').read_text();self.assertEqual(ex.count('.claude/worktrees/'),1)
 def test_preamble_is_role_and_transport_specific(self):
  c,d,_=self.setup_worker(backend='claude');p=(c/'api.prompt.md').read_text()
  self.assertIn('cc-fleet-land',p);self.assertIn(d['attempt'],p);self.assertIn('CLAUDE.md / AGENTS.md',p);self.assertNotIn('git switch --detach',p)
  # 绝对路径归一为 P 后比较：旧版前缀约 1740 字；防止退回旧体量。
  # 2026-09-16 上调 1300→1500：新增「e2e 只跑改动相关最小集合、不跑全量」纪律约 150 字（约束本身是需求，
  # 不能为过线删掉）；护栏仍远低于旧体量 1740，developer 前缀实测约 1447。
  import re;self.assertLess(len(re.sub(r"/[^\s；，。（）\"']+",'P',p.split('\n任务卡：\n')[0])),1500)
  self.assertIn('不跑项目全量 e2e 入口',p)
  c2,_,_=self.setup_worker(backend='claude',role='verify',module='ver');p2=(c2/'ver.prompt.md').read_text()
  self.assertNotIn('cc-fleet-land',p2);self.assertIn('真实页面',p2)
  c3,_,_=self.setup_worker(host='codex-app',module='nat');self.assertIn('git switch --detach',(c3/'nat.prompt.md').read_text())

 # --- 主 session 唤醒与"僵尸 running"兜底 ---------------------------------
 def stale_worker(self,backend='codex'):
  """已派发、后端仍自称活跃、但没有任何可观测活动的 worker。"""
  c,d,_=self.setup_worker(backend=backend);self.cli('dispatch','--coord',c,'--module','api')
  time.sleep(2.2);return c,d  # > --stale-after 1，idleFor 取整后才真的超阈值
 def test_status_flags_running_without_activity_as_stalled(self):
  c,_=self.stale_worker()
  fresh=self.cli('status','--coord',c);self.assertEqual(fresh['stalled'],[])  # 默认 600s 内不误报
  out=self.cli('status','--coord',c,'--stale-after','1')
  self.assertEqual(out['jobs'][0]['state'],'running')  # 后端状态字保持不变
  self.assertEqual(out['stalled'],['api']);self.assertEqual(out['jobs'][0]['attention'],'stalled')
  self.assertGreaterEqual(out['jobs'][0]['idleFor'],1)
 def test_activity_clears_stale_flag(self):
  c,_=self.stale_worker()
  (c/'api.alive').write_text('heartbeat')  # worker 心跳即视为在跑
  self.assertEqual(self.cli('status','--coord',c,'--stale-after','1')['stalled'],[])
 def test_reply_refuses_stalled_session_unless_forced(self):
  c,_=self.stale_worker();t=self.root/'fix.md';t.write_text('继续修 UC-A2')
  env=dict(self.env,CC_FLEET_STALE_AFTER='1')
  r=self.cli('reply','--coord',c,'--module','api','--text-file',t,ok=False,env=env)
  self.assertIn('swallow this reply',r.stderr)
  out=self.cli('reply','--coord',c,'--module','api','--text-file',t,'--force',env=env)
  self.assertEqual(out['state'],'running');self.assertGreater(out['activeSince'],0)
 def test_reconcile_reports_backend_state_not_a_hardcoded_running(self):
  c,_=self.stale_worker(backend='claude')
  db=self.db();db['jobs'][0]['state']='done';(self.root/'db.json').write_text(json.dumps(db))
  # 会话已结束：reconcile 过去硬写 running，主 session 因此死等并对着死会话 reply。
  self.assertEqual(self.cli('reconcile','--coord',c,'--module','api')['state'],'needs-review')
 def test_await_wakes_on_state_change(self):
  c,d=self.stale_worker()
  p=subprocess.Popen([str(FLEET),'await','--coord',str(c),'--interval','5','--timeout','60','--label','等 api 回执'],
                     env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  try:
   time.sleep(1);self.receipt(c,d,commit=self.base)  # worker 落回执 = 完成
   out,err=p.communicate(timeout=40)
  except subprocess.TimeoutExpired:
   p.kill();self.fail('await 没有在 worker 落回执后退出')
  self.assertEqual(p.returncode,0,err);j=json.loads(out)
  self.assertEqual(j['reason'],'state-changed');self.assertEqual(j['label'],'等 api 回执')
  self.assertEqual(j['changed'],[dict(module='api',**{'from':'running','to':'done','summary':'finished'})])
  self.assertEqual(j['stillPending'],[])
 def test_await_wakes_on_stall_and_skips_settled_modules(self):
  c,d=self.stale_worker();self.receipt(c,d)
  self.assertEqual(self.cli('await','--coord',c)['reason'],'nothing-to-await')  # 已结束的不等
  c2,_=self.stale_worker()
  j=self.cli('await','--coord',c2,'--stale-after','1','--interval','5','--timeout','60')
  self.assertEqual(j['reason'],'stalled');self.assertEqual(j['stalled'],['api'])
 def test_dispatch_and_reply_point_at_the_wake_hint(self):
  # 派发/追加指令的输出里必须带着"该挂什么"，主端不靠记性遵守 SKILL.md §6。
  c,_,_=self.setup_worker();out=self.cli('dispatch','--coord',c,'--module','api')
  for k in ('await --coord','run_in_background'):self.assertIn(k,out['nextWake'])
  t=self.root/'more.md';t.write_text('补一条指令')
  self.assertIn('await --coord',self.cli('reply','--coord',c,'--module','api','--text-file',t)['nextWake'])
 def test_await_rejects_out_of_range_bounds(self):
  c,_=self.stale_worker()
  self.cli('await','--coord',c,'--timeout','30',ok=False);self.cli('await','--coord',c,'--interval','1',ok=False)

if __name__=='__main__':unittest.main(verbosity=2)
