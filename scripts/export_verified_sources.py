"""Export only sources with recorded complete-chain evidence from a corpus audit."""
import json, sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def export(corpus, report, output):
    sources={item['source']['bookSourceUrl']:item['source'] for item in corpus}
    selected=[]
    for result in report:
        if result.get('status')!='passed':continue
        if not result.get('chapters') or result.get('characters',0)<200:raise ValueError('Incomplete pass evidence')
        source=sources[result['source']]
        if 'cookie' in str(source.get('header','')).lower() or 'authorization' in str(source.get('header','')).lower():
            raise ValueError('Do not distribute authentication headers in the verified sample')
        selected.append(source)
    if not selected:raise ValueError('No complete chains passed')
    output.write_text(json.dumps(selected,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return len(selected)

if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    corpus=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    report=json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
    print(export(corpus,report,Path(sys.argv[3])))
