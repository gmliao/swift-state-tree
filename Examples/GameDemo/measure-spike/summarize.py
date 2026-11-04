import json,subprocess,sys,os,glob,re
root=sys.argv[1]; M=os.path.dirname(os.path.abspath(__file__))
groups={}
for d in sorted(glob.glob(root+'/*-[0-9]')):
    key=re.sub(r'-\d$','',os.path.basename(d))
    try: r=json.loads(subprocess.check_output(['python3',M+'/analyze.py',d],stderr=subprocess.DEVNULL))
    except Exception as e: print('ERR',d,e); continue
    groups.setdefault(key,[]).append(r)
def g(r,path):
    x=r
    for p in path.split('.'):
        if not isinstance(x,dict) or p not in x: return None
        x=x[p]
    return x
fields=['tick.p99','turn.p99','syncTurn.p50','syncTurn.p99','turn.p50','sync.p99','tickInterval.p50','tickInterval.p99','apply.p99','decode.p99','redecode.p99','client.rtt.p95','client.update.p99','client.errorRate','client.disconnectRate','client.connections','counters.deferredTurns','counters.backlogSkips','counters.busySkips','counters.foldedSyncs']
for k,rs in groups.items():
    print('==',k,'n=%d'%len(rs))
    for f in fields:
        vals=[g(r,f) for r in rs]
        if all(v is None for v in vals): continue
        print('  %-22s %s'%(f,vals))
