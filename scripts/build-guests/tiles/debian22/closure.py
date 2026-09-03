import gzip,re,sys
pk={}; prov={}
for st in gzip.open(sys.argv[1],'rt',errors='replace').read().split('\n\n'):
    f={}
    for l in st.split('\n'):
        if ':' in l and not l.startswith(' '):
            k,v=l.split(':',1); f[k]=v.strip()
    if 'Package' in f:
        pk[f['Package']]=f
        for p in f.get('Provides','').split(','):
            p=p.strip()
            if p: prov.setdefault(p,f['Package'])
want=sys.argv[2:]; seen=[]; todo=list(want)
while todo:
    n=todo.pop(0)
    if n in seen: continue
    if n not in pk:
        if n in prov: n=prov[n]
        else: print('MISSING',n,file=sys.stderr); continue
        if n in seen: continue
    seen.append(n)
    for d in pk[n].get('Depends','').split(','):
        d=d.strip()
        if not d: continue
        alts=[re.split(r'[\s(]',a.strip())[0] for a in d.split('|')]
        pick=next((a for a in alts if a in pk or a in prov),alts[0])
        todo.append(pick)
for n in seen: print(pk[n]['Filename'])
