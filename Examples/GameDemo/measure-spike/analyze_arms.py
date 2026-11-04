# usage: analyze_arms.py <results/arms>  -> per arm and rooms: per-run values, n=3
import sys, os, glob, json, re, collections, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import windows, steady_bounds, cpu
root = sys.argv[1]; here = os.path.dirname(os.path.abspath(__file__))

def arm_ab(d):
    ws, we = steady_bounds(d); w = windows(d, ws, we)
    g = lambda k, f: (w.get(k) or {}).get(f)
    dec = w.get('clientDecode') or {}
    return {'tick.p99': g('tick', 'p99'), 'sync.p99': g('sync', 'p99'),
            'update.p99us': g('clientUpdateInterval', 'p99'), 'rtt.p95~p99us': g('clientRTT', 'p99'),
            'clientDecode.p99us': dec.get('p99'), 'clientDecodeCores': round(dec.get('sumUs', 0) / 1e6 / max(1, w['seconds']), 3),
            'cpu(process)': cpu(d, ws, we)}

def arm_c(d):
    a = json.loads(subprocess.check_output(['python3', here + '/analyze.py', d]))
    ws, we = steady_bounds(d)
    res = {'tick.p99': a.get('tick', {}).get('p99'), 'sync.p99': a.get('sync', {}).get('p99'),
           'update.p99ms': a['client']['update']['p99'], 'rtt.p95ms': a['client']['rtt']['p95'],
           'disconnectRate': a['client']['disconnectRate'], 'cpu': cpu(d, ws, we)}
    closes = collections.Counter(); lag = []; wcpu = []
    for f in glob.glob(d + '/client/*.json'):
        x = json.load(open(f)); t0 = x['t0']; dur = (x['tEnd'] - t0) / 1000
        for e in x['events']:
            if e['ev'] in ('close', 'error', 'unexpected-response'):
                rel = (e['t'] - t0) / 1000
                when = 'connect(<10s)' if rel < 10 else ('end(last 3s)' if rel > dur - 3 else 'mid')
                closes[(x['phase'], e['ev'], str(e.get('code')), e.get('reason') or e.get('msg') or '', when, 'joined' if e.get('joined') else 'notJoined')] += 1
        if x['phase'] == 'steady':
            lag += [s['lagP99Ms'] for s in x['samples']]; wcpu += [s['cpuPct'] for s in x['samples']]
    res['clientCloses'] = {' | '.join(k): v for k, v in closes.most_common(12)}
    if lag:
        lag.sort(); res['workerLagP99ms(p50,max over seconds)'] = (lag[len(lag) // 2], lag[-1])
        res['workerCpuPct(mean)'] = round(sum(wcpu) / len(wcpu), 1)
    log = open(d + '/server.log', errors='replace').read()
    pats = {'pongTimeout': 'Pong timeout', 'connReset': 'reset by peer', 'writerCeiling': 'writer ceiling',
            'duplicateLogin': 'Duplicate playerID', 'wsErrorOther': None}
    sv = {k: log.count(p) for k, p in pats.items() if p}
    sv['wsErrorOther'] = len(re.findall(r'WebSocket error', log)) - sv['connReset']
    res['serverCloses'] = sv
    def nums(p):
        out = {}
        for line in open(p, errors='replace'):
            m = re.match(r'\s*(\d+)\s+(.*)', line)
            if m: out[m.group(2).strip()] = int(m.group(1)); continue
            m = re.match(r'\s*(\S+)\s+(\d+)', line)
            if m: out[m.group(1)] = int(m.group(2))
        return out
    b, a2 = nums(d + '/tcp-before.txt'), nums(d + '/tcp-after.txt')
    keys = [k for k in a2 if re.search(r'overflow|ListenDrop|ListenOverflow|reset|Rst|drop', k, re.I)]
    res['tcpDelta'] = {k: a2[k] - b.get(k, 0) for k in keys if a2[k] - b.get(k, 0)}
    return res

groups = collections.defaultdict(list)
for d in sorted(glob.glob(root + '/[ABC]*-*-[0-9]')):
    arm, n, i = os.path.basename(d).rsplit('-', 2)
    try: groups[(arm, n)].append(arm_ab(d) if arm in ('A', 'B') else arm_c(d))
    except Exception as e: groups[(arm, n)].append({'error': str(e)})
for (arm, n), rs in sorted(groups.items(), key=lambda x: (int(x[0][1]), x[0][0])):
    print(f'== arm {arm}, {n} rooms, n={len(rs)}')
    for k in rs[0]:
        print(f'  {k:38} {[r.get(k) for r in rs]}')
