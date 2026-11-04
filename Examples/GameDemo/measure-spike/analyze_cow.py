# usage: analyze_cow.py <results/cow>  -> copies per cycle, copies/s, bytes/s, copy time share of tick time
import sys, os, glob, json, re, collections, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import windows, steady_bounds
groups = collections.defaultdict(list)
for d in sorted(glob.glob(sys.argv[1] + '/*-[0-9]')):
    key = os.path.basename(d).rsplit('-', 1)[0]
    ws, we = steady_bounds(d); w = windows(d, ws, we); c = w['counters']; s = max(1, w['seconds'])
    tickUs = (w.get('tick') or {}).get('sumUs', 0)  # the tick histogram wraps the whole turn
    pc = w.get('cowHolderPerCycle') or {}
    groups[key].append({
        'holderPerCycle.p50': pc.get('p50'), 'holderPerCycle.p99': pc.get('p99'), 'cycles/s': round(c.get('cowCycles', 0) / s, 1),
        'holderCopies/s': round(c.get('cowHolderCopies', 0) / s, 1), 'holderInSync/s': round(c.get('cowHolderCopiesInSync', 0) / s, 1),
        'holderMB/s': round(c.get('cowHolderBytes', 0) / s / 1e6, 3),
        'holderShareOfTick%': round(100 * c.get('cowHolderNs', 0) / 1e3 / tickUs, 2) if tickUs else None,
        '94Copies/s': round(c.get('cow94Copies', 0) / s, 1), '94MB/s': round(c.get('cow94Bytes', 0) / s / 1e6, 3),
        '94ShareOfTick%': round(100 * c.get('cow94Ns', 0) / 1e3 / tickUs, 2) if tickUs else None,
        'tick.p99us': (w.get('tick') or {}).get('p99')})
for k, rs in sorted(groups.items()):
    print(f'== {k} n={len(rs)}')
    for f in rs[0]: print(f'  {f:22} {[r[f] for r in rs]}')
