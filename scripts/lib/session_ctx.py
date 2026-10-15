"""会话上下文体量：决定一条回修/复测消息是复用原会话，还是换新会话靠落盘交接。

原则（不分会话类型）：上下文「热且小」才复用——距上一轮结束 < FRESH_IDLE 秒（提示缓存还在）、
当前上下文 < FRESH_CTX token、没压缩过；任一不满足就换新会话。
- token：每轮都要重读整段上下文，成本≈上下文大小×轮数；缓存凉了首轮还要整段重写缓存。
- 效果：旧过程（旧结论/旧 SHA/旧失败项）超过一定体量后，锚定与注意力稀释盖过它的价值；压缩过的已是有损摘要。
测不到（transcript/rollout 找不到）时返回 None，调用方按复用处理——无法证明它又大又凉，就不贸然换。
"""
import json, os, time
from pathlib import Path

FRESH_CTX = int(os.environ.get('CC_FLEET_FRESH_CTX', '150000'))
FRESH_IDLE = int(os.environ.get('CC_FLEET_FRESH_IDLE', '3600'))


def _ts(v):
    import datetime
    try: return datetime.datetime.fromisoformat(str(v).replace('Z', '+00:00')).timestamp()
    except Exception: return 0.0


def claude_transcript(session_id, cwd='', link=''):
    """优先用 job state.json 的 linkScanPath；否则按 cwd 推算 projects/<slug>/<sid>.jsonl，再扫一遍项目目录。"""
    if link and Path(link).is_file(): return Path(link)
    if not session_id: return None
    root = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home()/'.claude')/'projects'
    name = f'{session_id}.jsonl'
    if cwd:
        guess = root/''.join(ch if ch.isalnum() and ch.isascii() else '-' for ch in str(cwd))/name
        if guess.is_file(): return guess
    try: dirs = list(root.iterdir())
    except OSError: return None
    return next((d/name for d in dirs if (d/name).is_file()), None)


def codex_rollout(thread_id, max_days=7):
    if not thread_id: return None
    root = Path(os.environ.get('CODEX_HOME') or Path.home()/'.codex')/'sessions'
    days = sorted(root.glob('[0-9]*/[0-9]*/[0-9]*'), reverse=True)[:max_days]
    for d in days:
        hit = next((f for f in d.glob(f'*{thread_id}*.jsonl')), None)
        if hit: return hit
    return None


def _scan_line(ev, backend, st):
    t = _ts(ev.get('timestamp'))
    if backend == 'claude':
        # 每次压缩成对落盘：system/compact_boundary + isCompactSummary 的 user 摘要，只数前者
        if ev.get('type') == 'system' and ev.get('subtype') == 'compact_boundary':
            st['compactions'] += 1
        u = (ev.get('message') or {}).get('usage') if ev.get('type') == 'assistant' else None
        if u and not ev.get('isSidechain'):
            st['tokens'] = (u.get('input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0) \
                + (u.get('cache_creation_input_tokens') or 0)
            st['lastAt'] = t or st['lastAt']
        return
    p = ev.get('payload') or {}
    if ev.get('type') == 'compacted' or p.get('type') == 'context_compacted':
        st['compactions'] += 1
    if p.get('type') == 'token_count':
        u = ((p.get('info') or {}).get('last_token_usage')) or {}
        if u.get('input_tokens') is not None:
            st['tokens'] = u['input_tokens']; st['lastAt'] = t or st['lastAt']


def measure(path, backend, cache=None):
    """增量扫描（按文件偏移缓存在 cache 文件里，大 transcript 不必每次全读）。
    返回 {tokens, lastAt, compactions, path}；tokens=最近一次模型调用的输入上下文。"""
    path = Path(path); key = str(path)
    allc = {}
    if cache:
        try: allc = json.loads(Path(cache).read_text())
        except Exception: allc = {}
    st = allc.get(key) or {}
    size = path.stat().st_size
    if st.get('offset', 0) > size or st.get('backend') != backend:
        st = {}
    st = dict(dict(offset=0, tokens=0, lastAt=0.0, compactions=0, backend=backend), **st)
    with path.open('rb') as f:
        f.seek(st['offset']); buf = f.read()
    end = buf.rfind(b'\n') + 1  # 末尾半行留到下次
    for line in buf[:end].splitlines():
        try: ev = json.loads(line)
        except Exception: continue
        if isinstance(ev, dict): _scan_line(ev, backend, st)
    st['offset'] += end
    if cache:
        allc[key] = st
        try:
            tmp = Path(str(cache)+f'.{os.getpid()}.tmp'); tmp.write_text(json.dumps(allc)); os.replace(tmp, cache)
        except OSError: pass
    return dict(tokens=st['tokens'], lastAt=st['lastAt'] or None, compactions=st['compactions'], path=key)


def decide(ctx, now=None):
    """(复用?, 原因列表)。ctx 为 None（测不到）→ 复用。"""
    if not ctx: return True, []
    now = now or time.time(); why = []
    if ctx.get('tokens', 0) >= FRESH_CTX: why.append(f"上下文 {ctx['tokens']//1000}k≥{FRESH_CTX//1000}k")
    if ctx.get('lastAt') and now-ctx['lastAt'] >= FRESH_IDLE:
        why.append(f"空闲 {int(now-ctx['lastAt'])//60} 分钟≥{FRESH_IDLE//60} 分钟（缓存已凉）")
    if ctx.get('compactions'): why.append(f"已压缩 {ctx['compactions']} 次")
    return not why, why
