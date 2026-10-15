#!/usr/bin/env python3
"""回复时「热且小才复用原会话，否则换新会话靠交接文件续上」——不分会话类型。
复用 test_fleet_v2 的夹具（假 claude / 假 app-server / 假 daemon），只跑本文件 test_fresh_* 用例。"""
import json, pathlib, sys, time, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import test_fleet_v2 as base

SCRIPTS = base.ROOT/'scripts'/'lib'
sys.path.insert(0, str(SCRIPTS))
import session_ctx


class FreshSessionTests(base.FleetTests):
 def setUp(self):
  super().setUp()
  # 与真实 ~/.claude / ~/.codex 隔离：transcript / rollout 全落临时目录
  self.env.update(CLAUDE_CONFIG_DIR=str(self.root/'cc'),CODEX_HOME=str(self.root/'cx'))
 def iso(self,ago):return time.strftime('%Y-%m-%dT%H:%M:%S.000Z',time.gmtime(time.time()-ago))
 def transcript(self,short,tokens,ago,compact=False,**job):
  """给 Claude worker 落一份 transcript 并让 state.json 指向它。"""
  f=self.root/'cc'/'projects'/'w'/f'{short}.jsonl';f.parent.mkdir(parents=True,exist_ok=True)
  rows=[dict(type='user',timestamp=self.iso(ago+60),message=dict(role='user',content='task'))]
  if compact:rows+=[dict(type='system',subtype='compact_boundary',timestamp=self.iso(ago+31)),  # 真实形态：一次压缩成对两条
                    dict(type='user',isCompactSummary=True,timestamp=self.iso(ago+30),message=dict(role='user',content='summary'))]
  rows.append(dict(type='assistant',timestamp=self.iso(ago),message=dict(role='assistant',content=[],
              usage=dict(input_tokens=10,cache_read_input_tokens=tokens-10,cache_creation_input_tokens=0,output_tokens=5))))
  f.write_text(''.join(json.dumps(r)+'\n' for r in rows))
  self.job(short,linkScanPath=str(f),**job);return f
 def done_worker(self,module='api'):
  c,d,s=self.claude_worker(module);self.dev_done(c,d);self.job(s,state='done',tempo='idle',updatedAt=self.iso(30))
  return c,d,s
 def reply(self,c,*extra,module='api',env=None):
  t=self.root/'fix.md';t.write_text('UC-A2 失败：修复');return self.cli('reply','--coord',c,'--module',module,'--text-file',t,*extra,env=env)

 def test_fresh_cold_large_session_rotates_to_new_session_with_handoff(self):
  env,st=self.fake_daemon(dict(state='working',tempo='active'));self.env.update(env)
  c,d,s=self.done_worker();self.transcript(s,340000,6*3600,state='done',tempo='idle')
  (c/'api.handoff.md').write_text('本地后端用 scripts/up.sh；c2v5 冲突换栈名')
  row=self.cli('status','--coord',c)['jobs'][0]
  self.assertEqual((row['context']['tokens'],row['context']['reuse']),(340000,False))
  out=self.reply(c)
  self.assertIn('rotated',out);self.assertNotEqual(out['shortId'],s);self.assertEqual(out['state'],'running')
  self.assertFalse([q for q in st['calls'] if q['op']=='reply'],'换新会话不再往旧会话投递')
  calls=self.db()['calls'];self.assertIn(['stop',s],calls,'旧会话被停掉')
  prompt=[a for a in calls if '--bg' in a][-1][-1]
  for frag in ('【接续】','api.handoff.md','UC-A2 失败：修复',out['attempt'],'Implement a bounded module'):self.assertIn(frag,prompt)
  r=self.rec(c,'api');self.assertEqual(r['previousSessions'][-1]['shortId'],s);self.assertEqual(r['worktree'],d['worktree'])
  self.assertTrue(list((c/'v2').glob('api.receipt-*.json.bak')),'旧回执已归档，不会冒充新一轮完成')

 def test_fresh_hot_small_session_is_reused(self):
  env,st=self.fake_daemon(dict(state='working',tempo='active'));self.env.update(env)
  c,_,s=self.done_worker();self.transcript(s,40000,120,state='done',tempo='idle')
  out=self.reply(c)
  self.assertNotIn('rotated',out);self.assertEqual(out['shortId'],s)
  self.assertEqual(len([q for q in st['calls'] if q['op']=='reply']),1)

 def test_fresh_each_condition_alone_triggers_rotation(self):
  for tokens,ago,compact in ((200000,60,False),(20000,2*3600,False),(20000,60,True)):
   with self.subTest(tokens=tokens,ago=ago,compact=compact):
    reuse,why=session_ctx.decide(dict(tokens=tokens,lastAt=time.time()-ago,compactions=int(compact)))
    self.assertFalse(reuse);self.assertEqual(len(why),1)
  self.assertEqual(session_ctx.decide(dict(tokens=20000,lastAt=time.time()-60,compactions=0)),(True,[]))
  self.assertEqual(session_ctx.decide(None),(True,[]),'测不到就不贸然换')

 def test_fresh_running_session_is_never_rotated_mid_turn(self):
  env,st=self.fake_daemon(dict(state='working',tempo='active'));self.env.update(env)
  c,_,s=self.claude_worker();self.transcript(s,400000,10,compact=True)  # 正在干活：大但热
  self.assertEqual(self.cli('status','--coord',c)['jobs'][0]['context']['compactions'],1,'成对的压缩记录只算一次')
  out=self.reply(c);self.assertNotIn('rotated',out);self.assertEqual(out['shortId'],s)

 def test_fresh_explicit_session_flag_overrides(self):
  env,st=self.fake_daemon(dict(state='working',tempo='active'));self.env.update(env)
  c,_,s=self.done_worker();self.transcript(s,400000,6*3600,state='done',tempo='idle')
  self.assertEqual(self.reply(c,'--session','reuse')['shortId'],s)
  c2,_,s2=self.done_worker('web');self.transcript(s2,1000,10,state='done',tempo='idle')
  out=self.reply(c2,'--session','fresh',module='web');self.assertIn('rotated',out);self.assertNotEqual(out['shortId'],s2)

 def test_fresh_queued_retest_rotates_and_reports_it(self):
  env,st=self.fake_daemon(dict(state='working',tempo='active'));self.env.update(env)
  c,a,_=self.claude_worker('api')
  v=self.cli('prepare','--coord',c,'--module','verify','--backend','claude','--role','verify','--task',self.task)
  vs=self.cli('dispatch','--coord',c,'--module','verify')['shortId']
  self.receipt(c,v,result='failed',tests=[dict(command='UC-A2',result='failed',evidence='shot.png')])
  self.transcript(vs,340000,6*3600,state='done',tempo='idle')
  t=self.root/'re.md';t.write_text('复测 UC-A2');self.cli('queue-reply','--coord',c,'--module','verify','--after','api','--text-file',t)
  self.dev_done(c,a);acts=self.cli('advance','--coord',c)['actions']
  self.assertEqual([(x['module'],x['action']) for x in acts],[('verify','replied')]);self.assertIn('rotated',acts[0])
  self.assertNotEqual(self.rec(c,'verify')['shortId'],vs)
  self.assertIn('复测 UC-A2',[a for a in self.db()['calls'] if '--bg' in a][-1][-1])

 def test_fresh_codex_rollout_drives_the_same_rule(self):
  c,d,_=self.setup_worker(backend='codex');out=self.cli('dispatch','--coord',c,'--module','api')
  db=self.db();t=db['threads'][out['sessionId']];t['status']={'type':'idle'};t['turns'][-1]['status']='completed'
  (self.root/'db.json').write_text(json.dumps(db))
  day=self.root/'cx'/'sessions'/'2026'/'10'/'15';day.mkdir(parents=True)
  ev=dict(timestamp=self.iso(3*3600),type='event_msg',payload=dict(type='token_count',info=dict(last_token_usage=dict(input_tokens=260000))))
  (day/f"rollout-x-{out['sessionId']}.jsonl").write_text(json.dumps(ev)+'\n')
  r=self.reply(c);self.assertIn('rotated',r);self.assertNotEqual(r['sessionId'],out['sessionId'])
  self.assertEqual(len([x for x in self.db()['calls'] if x[0]=='thread/start']),2)

 def test_fresh_measure_is_incremental_and_tolerates_partial_line(self):
  f=self.root/'t.jsonl';cache=self.root/'cache.json'
  row=lambda n:json.dumps(dict(type='assistant',timestamp=self.iso(5),message=dict(usage=dict(input_tokens=n))))+'\n'
  f.write_text(row(100)+'{"type":"assist')  # 末尾半行：留到下次
  self.assertEqual(session_ctx.measure(f,'claude',cache)['tokens'],100)
  with f.open('a') as h:h.write('ant"}\n'+row(900)+json.dumps(dict(type='system',subtype='compact_boundary'))+'\n')
  x=session_ctx.measure(f,'claude',cache);self.assertEqual((x['tokens'],x['compactions']),(900,1))
  f.write_text(row(50));self.assertEqual(session_ctx.measure(f,'claude',cache)['tokens'],50,'文件变短（重写）时从头扫')


if __name__=='__main__':
 loader=unittest.TestLoader();loader.testMethodPrefix='test_fresh'
 unittest.main(testLoader=loader,verbosity=2)
