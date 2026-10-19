"""Download public rule collections for opt-in, bounded real-site checks."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib, json, re, urllib.request

ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'.build/source-audit'
URLS=[
    'https://raw.githubusercontent.com/XIU2/Yuedu/master/shuyuan',
    'https://raw.githubusercontent.com/aoaostar/legado/release/sources/b778fe6b.json',
    'https://raw.githubusercontent.com/aoaostar/legado/release/sources/71e56d4f.json',
    'https://raw.githubusercontent.com/aoaostar/legado/release/sources/4dc410d1.json',
    'https://shuyuan-api.yiove.com/import/book-source-collection/a8adf570-e115-4b99-87e3-ccaf298ae361'
]
def load(url):
    try:
        request=urllib.request.Request(url,headers={'User-Agent':'Gavin-source-compatibility-audit/1.0'})
        with urllib.request.urlopen(request,timeout=45) as response:
            data=response.read(16*1024*1024+1); actual=response.url
        if len(data)>16*1024*1024: raise ValueError('Collection exceeds 16 MB')
        rows=json.loads(data.decode('utf-8-sig'))
        if not isinstance(rows,list): raise ValueError('Expected source array')
        return {'url':url,'actual':actual,'sha256':hashlib.sha256(data).hexdigest(),'count':len(rows),'rows':rows}
    except Exception as error: return {'url':url,'error':str(error),'rows':[]}

def main():
    OUTPUT.mkdir(parents=True,exist_ok=True)
    collections=list(ThreadPoolExecutor(max_workers=2).map(load,URLS))
    sources=[];seen=set()
    for collection in collections:
        for source in collection['rows']:
            if not isinstance(source,dict):continue
            url=source.get('bookSourceUrl','')
            if not isinstance(url,str) or not url.startswith(('http://','https://')) or url in seen:continue
            if not source.get('searchUrl') or not isinstance(source.get('ruleSearch'),dict):continue
            if source.get('bookSourceType',0) not in [0,None]:continue
            seen.add(url)
            rules=json.dumps({k:v for k,v in source.items() if k.startswith('rule') or k in ['searchUrl','jsLib','header']},ensure_ascii=False)
            sources.append({'collection':collection['url'],'scripted':bool(re.search(r'@js:|<js>|\{\{',rules,re.I)),'source':source})
    assert sources,'No public collections were downloaded'
    (OUTPUT/'corpus.json').write_text(json.dumps(sources,ensure_ascii=False),encoding='utf-8')
    provenance=[{k:v for k,v in collection.items() if k!='rows'} for collection in collections]
    (OUTPUT/'provenance.json').write_text(json.dumps(provenance,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'sources':len(sources),'scripted':sum(s['scripted'] for s in sources),'collections':provenance},ensure_ascii=False))

if __name__=='__main__': main()
