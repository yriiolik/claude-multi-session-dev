#!/usr/bin/env python3
"""端到端：依赖图自动推进的完整一轮编排（真实 git / 真实 cc-fleet-land / 真实 await 进程；Claude CLI 与 daemon 用替身）。

场景 = 新版默认编排形态：
  api、web 两张开发卡并行 + verify 卡同时进入「编写阶段」写验收脚本；
  regression 排队在 api、web 之后（自动派发、用 runner 配置）；verify 的「执行阶段」排队在 regression 之后。
  主端挂一次 await，中间所有接续都不唤醒它，只在整条流水线收尾时醒一次。
  随后验收发现缺陷：回修 reply 给已被回收的 api 原会话（自动原地复活），verify 复测排队在 api 之后，再次只醒一次。
"""
import json, pathlib, subprocess, sys, time, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import test_fleet_v2 as base

ROOT = base.ROOT; LAND = ROOT/'scripts/cc-fleet-land'

class PipelineE2E(base.FleetTests):
    def commit(self, wt, f, text, msg):
        (pathlib.Path(wt)/f).write_text(text); self.git('add', '.', cwd=wt); self.git('commit', '-qm', msg, cwd=wt)
    def land(self, wt):
        subprocess.run([str(LAND), self.rq], cwd=wt, check=True, capture_output=True)
        return self.git('rev-parse', 'fleet/'+self.rq)
    def text(self, body):
        p = self.root/f'msg-{time.time_ns()}.md'; p.write_text(body); return p
    def accept(self, c, m):
        """验收/回归 worker：合并最新集成分支、落地、按集成 HEAD 回执全部 passed。"""
        d = self.rec(c, m); wt = d['worktree']
        self.git('merge', '-q', '--no-edit', 'fleet/'+self.rq, cwd=wt)
        tip = self.land(wt)
        self.receipt(c, d, commit=tip, tests=[dict(command='page acceptance', result='passed', evidence='report.md')])
        return tip
    def running(self, c, m, timeout=30):
        end = time.time()+timeout
        while time.time() < end:
            d = self.rec(c, m)
            if d['state'] == 'running': return d
            time.sleep(0.5)
        self.fail(f'{m} 没有被编排器推进到 running')

    def test_full_pipeline_wakes_owner_only_at_the_end(self):
        conf = self.root/'conf.json'
        conf.write_text(json.dumps(dict(worker=dict(model='big', effort='high'), runner=dict(model='small', effort='medium'))))
        env, st = self.fake_daemon(dict(state='working', tempo='active'))
        self.env = dict(env, CLAUDE_FLEET_CONFIG=str(conf))
        f = self.cli('init', '--cwd', self.repo, '--host', 'claude-code'); c = pathlib.Path(f['coord']); self.rq = f['rq']
        prep = lambda m, *a: self.cli('prepare', '--coord', c, '--module', m, '--backend', 'claude', '--task', self.task, *a)
        api = prep('api'); web = prep('web')
        prep('verify', '--role', 'verify', '--phase', 'author')
        prep('regression', '--role', 'regression', '--after', 'api,web')
        self.cli('queue-reply', '--coord', c, '--module', 'verify', '--after', 'regression', '--phase', 'execute',
                 '--text-file', self.text('按 use-cases.md 全部执行'))
        for m in ('api', 'web', 'verify'): self.cli('dispatch', '--coord', c, '--module', m)

        # ---- 第一轮：主端只挂一次 await ----
        p = self.run_await(c); time.sleep(1.5)
        self.commit(api['worktree'], 'api.txt', 'api v1', 'api'); self.receipt(c, api, commit=self.land(api['worktree']))
        self.commit(web['worktree'], 'web.txt', 'web v1', 'web'); self.receipt(c, web, commit=self.land(web['worktree']))
        v = self.rec(c, 'verify')
        self.commit(v['worktree'], 'verify.spec', 'spec', 'verify specs')
        self.receipt(c, v, commit='', tests=[dict(command='author specs', result='not-run', evidence='verify.spec')])
        reg = self.running(c, 'regression')
        self.assertIsNone(p.poll(), '开发完成→回归自动派发，不应唤醒主端')
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=reg['worktree']), self.git('rev-parse', 'fleet/'+self.rq),
                         '回归在含 api+web 的最新集成基线上启动')
        bg = [x for x in self.db()['calls'] if '--bg' in x]
        self.assertEqual([x[x.index('--model')+1] for x in bg], ['big', 'big', 'big', 'small'], '回归卡用 runner 配置')
        self.accept(c, 'regression')
        end = time.time()+30
        while time.time() < end and not [q for q in st['calls'] if q['op'] == 'reply']: time.sleep(0.5)
        self.assertEqual(self.rec(c, 'verify')['phase'], 'execute')
        self.assertIn('执行阶段', [q for q in st['calls'] if q['op'] == 'reply'][-1]['text'])
        self.assertIsNone(p.poll(), '回归通过→验收自动进入执行阶段，不应唤醒主端')
        final = self.accept(c, 'verify')
        j = self.finish(p)
        self.assertEqual([x['module'] for x in j['changed']], ['verify']); self.assertEqual(j['stillPending'], [])
        self.assertEqual([(x['module'], x['action']) for x in j['advanced']], [('regression', 'dispatched'), ('verify', 'replied')])
        rows = {r['module']: r['state'] for r in self.cli('status', '--coord', c)['jobs']}
        self.assertEqual(rows, dict(api='done', web='done', verify='done', regression='needs-review'),
                         '回归基线已被 verify 合入推进 → 旧回归证据失效，status 如实提示')
        for x in ('api.txt', 'web.txt', 'verify.spec'):
            self.assertEqual(subprocess.run(['git', '-C', str(self.repo), 'cat-file', '-e', f'{final}:{x}']).returncode, 0)

        # ---- 第二轮：验收发现缺陷 → 回修交回已被回收的 api 原会话 → 验收自动复测 ----
        api = self.rec(c, 'api'); st['live'] = None   # watchdog 已回收 done 的 api 会话
        self.job(api['shortId'], sessionId=api['sessionId'], state='done', tempo='idle', respawnFlags=['--name', api['name']], cwd=api['cwd'],
                 updatedAt=self.old(120))  # 回收前最后一次刷新在两分钟前
        out = self.cli('reply', '--coord', c, '--module', 'api', '--text-file', self.text('UC-A2 失败：金额四舍五入错误'))
        self.assertTrue(out['revived']); self.assertEqual(out['replies'], 1)
        self.assertEqual(next(q for q in st['calls'] if q['op'] == 'dispatch')['d']['launch']['mode'], 'resume')
        self.cli('queue-reply', '--coord', c, '--module', 'verify', '--after', 'api', '--text-file', self.text('复测 UC-A2 与主流程'))
        p = self.run_await(c); time.sleep(1.5)
        api = self.rec(c, 'api')
        self.commit(api['worktree'], 'api.txt', 'api v2', 'fix UC-A2'); self.receipt(c, api, commit=self.land(api['worktree']))
        end = time.time()+30
        sent = len([q for q in st['calls'] if q['op'] == 'reply'])
        while time.time() < end and len([q for q in st['calls'] if q['op'] == 'reply']) == sent: time.sleep(0.5)
        self.assertIsNone(self.rec(c, 'verify').get('queuedReply'),
                          f"回修合入后编排器应自动发出复测消息；await={p.poll()} {p.stdout.read() if p.poll() is not None else ''} "
                          f"advance={self.cli('advance', '--coord', c)}")
        self.assertIn('复测 UC-A2', [q for q in st['calls'] if q['op'] == 'reply'][-1]['text'])
        self.assertIsNone(p.poll(), '回修完成→验收自动复测，不应唤醒主端')
        final = self.accept(c, 'verify')
        j = self.finish(p)
        self.assertEqual([x['module'] for x in j['changed']], ['verify'])
        self.assertEqual(self.git('show', f'{final}:api.txt'), 'api v2')

if __name__ == '__main__':
    unittest.main(defaultTest='PipelineE2E.test_full_pipeline_wakes_owner_only_at_the_end', verbosity=2)
