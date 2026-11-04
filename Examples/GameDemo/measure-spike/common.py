import json, glob, os, re
PRE, STEADY = 8, 65   # pre/ramp-up and steady seconds of every scenario here

def pct(h, q):
    tot = sum(n for _, n in h)
    if not tot: return None
    k = q * tot; acc = 0
    for b, n in h:
        acc += n
        if acc >= k: return b
    return h[-1][0]

def windows(out, ws, we):
    merged, counters, nwin = {}, {}, 0
    for line in open(out + '/metrics.jsonl'):
        w = json.loads(line); t = w['t']
        if t - 5 < ws or t > we: continue
        nwin += 1
        for k, v in w['hist'].items():
            m = merged.setdefault(k, {})
            for b, n in v: m[b] = m.get(b, 0) + n
        for k, v in w['counters'].items(): counters[k] = counters.get(k, 0) + v
    res = {'windows': nwin, 'seconds': nwin * 5, 'counters': counters}
    for k, m in merged.items():
        h = sorted((int(b), n) for b, n in m.items())
        res[k] = {'n': sum(n for _, n in h), 'p50': pct(h, .5), 'p99': pct(h, .99), 'sumUs': sum(b * n for b, n in h)}
    return res

def steady_bounds(out):
    start = int(open(out + '/start').read())
    return start + PRE + 5, start + PRE + STEADY - 1

def cpu(out, ws, we):
    rows = [list(map(float, l.split())) for l in open(out + '/cpu.txt') if l.strip()]
    rows = [r for r in rows if ws <= r[0] <= we]
    if len(rows) < 2: return None
    dt = rows[-1][0] - rows[0][0]
    return {'serverCores': round((rows[-1][1] - rows[0][1]) / dt, 2), 'nodeWorkersCores': round((rows[-1][2] - rows[0][2]) / dt, 2)}
