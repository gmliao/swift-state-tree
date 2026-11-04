import json, sys, glob, os, datetime
def pct(h, q):
    tot=sum(n for _,n in h)
    if tot==0: return None
    k=q*tot; acc=0
    for b,n in h:
        acc+=n
        if acc>=k: return b
    return h[-1][0]
def analyze(out, post=5, steady=65):
    rep=sorted(glob.glob(out+'/ws-loadtest-*.json'))
    rep=[r for r in rep if 'system' not in r]
    d=json.load(open(rep[-1]))
    end=datetime.datetime.fromisoformat(d['meta']['generatedAt'].replace('Z','+00:00')).timestamp()
    ws=end-post-steady+5; we=end-post-1
    merged={}; counters={}; nwin=0
    for line in open(out+'/metrics.jsonl'):
        w=json.loads(line); t=w['t']
        if t-5<ws or t>we: continue
        nwin+=1
        for k,v in w['hist'].items():
            m=merged.setdefault(k,{})
            for b,n in v: m[b]=m.get(b,0)+n
        for k,v in w['counters'].items(): counters[k]=counters.get(k,0)+v
    res={'windows':nwin,'counters':counters}
    for k,m in merged.items():
        h=sorted(m.items())
        res[k]={'n':sum(n for _,n in h),'p50':pct(h,.5),'p95':pct(h,.95),'p99':pct(h,.99),'max':h[-1][0]}
    st=[p for p in d['phases'] if p['name']=='steady'][0]
    res['client']={'rtt':st['rtt'],'update':st['update'],'errorRate':st['errorRate'],'disconnectRate':st['disconnectRate'],'connections':st['connections']}
    return res
if __name__=='__main__':
    print(json.dumps(analyze(sys.argv[1]),indent=1))
