"""Download public rule collections for opt-in, bounded real-site checks."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import ast, hashlib, json, re, time, urllib.request

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
        request=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1','Accept':'application/json,text/plain;q=0.9,*/*;q=0.5'})
        with urllib.request.urlopen(request,timeout=15) as response:
            chunks=[];size=0;deadline=time.monotonic()+60;actual=response.url
            while True:
                if time.monotonic()>deadline:raise TimeoutError('Collection download exceeds 60 seconds')
                chunk=response.read(128*1024)
                if not chunk:break
                size+=len(chunk)
                if size>20*1024*1024:raise ValueError('Collection exceeds 20 MB')
                chunks.append(chunk)
            data=b''.join(chunks)
        if len(data)>20*1024*1024: raise ValueError('Collection exceeds 20 MB')
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
            if source.get('enabled') is False:continue
            seen.add(url)
            personal_login=False
            header=source.get('header')
            if isinstance(header,str) and header.lstrip().startswith('{'):
                try:
                    try: values=json.loads(header)
                    except ValueError:values=ast.literal_eval(header)
                    if isinstance(values,dict):
                        for name,value in list(values.items()):
                            if str(name).lower()=='cookie' and re.search(r'phpsessid|session|jieqiuserinfo|usertoken',str(value),re.I):
                                personal_login=True;del values[name]
                        source={**source,'header':json.dumps(values,ensure_ascii=False)}
                except (ValueError,SyntaxError):pass
            rules=json.dumps({k:v for k,v in source.items() if k.startswith('rule') or k in ['searchUrl','jsLib','header']},ensure_ascii=False)
            sources.append({'collection':collection['url'],'scripted':bool(re.search(r'@js:|<js>|\{\{(?!\s*(?:key|page)\s*\}\})',rules,re.I)),'requiresPersonalLogin':personal_login,'source':source})
    assert sources,'No public collections were downloaded'
    (OUTPUT/'corpus.json').write_text(json.dumps(sources,ensure_ascii=False),encoding='utf-8')
    provenance=[{k:v for k,v in collection.items() if k!='rows'} for collection in collections]
    (OUTPUT/'provenance.json').write_text(json.dumps(provenance,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'sources':len(sources),'scripted':sum(s['scripted'] for s in sources),'collections':provenance},ensure_ascii=False))

if __name__=='__main__': main()
