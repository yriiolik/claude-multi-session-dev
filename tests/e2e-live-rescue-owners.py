#!/usr/bin/env python3
"""真实 daemon e2e：主 session 被回收后，worker 交回执，rescue-owners 原地复活主 session 并注入唤醒。

不在 run-all.sh 里（会起一个真实的 haiku 后台会话、耗少量 token）：
    python3 tests/e2e-live-rescue-owners.py
worker 侧用假 claude CLI（与 test_fleet_v2 同款），主 session 侧全是真的：daemon dispatch → kill（模拟 watchdog 回收）
→ rescue-owners → 断言同一 short/sessionId 复活、transcript 里出现唤醒消息且之后有 assistant 回复。
"""
import glob, json, os, pathlib, shutil, subprocess, sys, tempfile, time, uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
FLEET = ROOT/'scripts/cc-fleet'
sys.path.insert(0, str(ROOT/'tests')); sys.path.insert(0, str(ROOT/'scripts'))
from test_fleet_v2 import FAKE  # noqa: E402
import importlib.machinery, importlib.util  # noqa: E402
_l = importlib.machinery.SourceFileLoader('ccfleet', str(FLEET))
fleet = importlib.util.module_from_spec(importlib.util.spec_from_loader('ccfleet', _l)); _l.exec_module(fleet)

def check(cond, msg):
    print(('  ✅ ' if cond else '  ❌ ') + msg)
    if not cond: raise SystemExit(1)

def transcript(sid):
    hits = glob.glob(str(pathlib.Path.home()/'.claude'/'projects'/'*'/f'{sid}.jsonl'))
    return pathlib.Path(hits[0]) if hits else None

def messages(sid):
    p = transcript(sid); out = []
    for line in (p.read_text().splitlines() if p else []):
        with __import__('contextlib').suppress(ValueError):
            r = json.loads(line); m = r.get('message')
            if r.get('type') in ('user', 'assistant') and isinstance(m, dict):
                c = m.get('content'); out.append((r['type'], c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)))
    return out

def wait(pred, limit, step=3):
    end = time.time() + limit
    while time.time() < end:
        if pred(): return True
        time.sleep(step)
    return False

def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix='rescue-e2e-'))
    short, sid = uuid.uuid4().hex[:8], str(uuid.uuid4())
    try:
        print('① 起一个真实的后台主 session 并等它结束本轮')
        own = tmp/'owner'; own.mkdir()
        flags = ['--model', 'claude-haiku-5-5', '--name', 'rescue-e2e-可删']
        d = dict(proto=1, short=short, sessionId=sid, createdAt=int(time.time()*1000), source='fleet', cwd=str(own),
                 launch=dict(mode='prompt', args=['你是自动化测试会话。现在只回复 READY；之后收到任何消息只回复 ACK，不要调用任何工具。', *flags]),
                 seed=dict(intent='rescue e2e', name='rescue-e2e-可删'), agent='claude', isolation='none', respawnFlags=flags)
        check(fleet.daemon_call(dict(op='dispatch', d=d, timeoutMs=15000), timeout=30).get('ok'), f'dispatch 主 session {short}')
        check(wait(lambda: any(t == 'assistant' for t, _ in messages(sid)) and
                   (fleet.job_state(short) or {}).get('tempo') != 'active', 120), '主 session 已回复并空闲')

        print('② 搭协调目录：主端=这个真实 session，worker 用假 CLI')
        repo = tmp/'repo'; repo.mkdir()
        for a in (['init', '-q', '-b', 'main'], ['config', 'user.name', 't'], ['config', 'user.email', 't@e.invalid']):
            subprocess.check_call(['git', '-C', str(repo), *a])
        (repo/'a.txt').write_text('x'); subprocess.check_call(['git', '-C', str(repo), 'add', '.'])
        subprocess.check_call(['git', '-C', str(repo), 'commit', '-qm', 'base'])
        fake = tmp/'claude'; fake.write_text(FAKE); fake.chmod(0o755)
        task = tmp/'task.md'; task.write_text('noop')
        env = dict(os.environ, FAKE_DB=str(tmp/'db.json'), CLAUDE_CLI_PATH=str(fake), CC_FLEET_PANEL='0',
                   CC_FLEET_PANEL_REGISTRY=str(tmp/'coords.json'), CC_FLEET_HOME=str(tmp/'fh'),
                   CLAUDE_FLEET_CONFIG=str(tmp/'none.json'), CODEX_MULTI_SESSION_CONFIG=str(tmp/'none2.json'),
                   CLAUDE_CODE_SESSION_ID=sid)  # claude-code 主端身份取自所在 session，而不是 --owner-id
        env.pop('CLAUDE_SESSION_ID', None)
        cli = lambda *a: json.loads(subprocess.run([str(FLEET), *map(str, a)], env=env, text=True, capture_output=True, check=True).stdout)
        c = pathlib.Path(cli('init', '--cwd', repo, '--host', 'claude-code', '--owner-id', sid)['coord'])
        md = cli('prepare', '--coord', c, '--module', 'api', '--backend', 'claude', '--task', task)
        cli('dispatch', '--coord', c, '--module', 'api')
        check(cli('rescue-owners', '--coord', c)['results'] == [], '首轮只记基线')

        print('③ 模拟 watchdog 回收主 session，然后 worker 交回执')
        fleet.daemon_call(dict(op='kill', short=short, signal='SIGTERM'))
        check(wait(lambda: not fleet.daemon_call(dict(op='has', short=short)).get('present'), 30, 1), '主 session 已不在 daemon')
        rq = json.loads((c/'fleet.json').read_text())['rq']
        (c/'api.receipt.json').write_text(json.dumps(dict(version=2, rq=rq, module='api', attempt=md['attempt'], result='done',
                                                         summary='e2e 完成', tests=[dict(command='x', result='passed', evidence='ok')], commit='')))
        n_before = len(messages(sid))

        print('④ rescue-owners 应复活并唤醒主 session')
        r = cli('rescue-owners', '--coord', c)['results']
        check(len(r) == 1 and r[0]['action'] == 'woke' and r[0]['revive'] is True, f'结果 {r}')
        check(fleet.daemon_call(dict(op='has', short=short)).get('present'), '同一 short 已回到 daemon')
        check(wait(lambda: any(t == 'user' and '⟦fleet 自动唤醒⟧' in x for t, x in messages(sid)[n_before:]), 60), '唤醒消息进入同一 sessionId 的对话')
        check(wait(lambda: messages(sid)[-1][0] == 'assistant' and len(messages(sid)) > n_before + 1, 120), '主 session 对唤醒作出回复')
        check(cli('rescue-owners', '--coord', c)['results'] == [], '同一次完成不重复唤醒')
        print('==== rescue-owners live e2e：全部通过 ====')
    finally:
        with __import__('contextlib').suppress(Exception): fleet.daemon_call(dict(op='kill', short=short, signal='SIGTERM'))
        subprocess.run(['claude', 'rm', short], capture_output=True)
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == '__main__':
    main()
