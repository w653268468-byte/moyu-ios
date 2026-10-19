"""Fetch pinned upstream CryptoJS with npm's SHA-512 integrity verification."""
from pathlib import Path
import base64, hashlib, io, json, tarfile, urllib.request

ROOT=Path(__file__).resolve().parents[1]
VERSION='4.2.0'
metadata=json.load(urllib.request.urlopen('https://registry.npmjs.org/crypto-js/'+VERSION,timeout=45))
blob=urllib.request.urlopen(metadata['dist']['tarball'],timeout=45).read()
algorithm,digest=metadata['dist']['integrity'].split('-',1)
assert algorithm=='sha512' and base64.b64encode(hashlib.sha512(blob).digest()).decode()==digest
with tarfile.open(fileobj=io.BytesIO(blob),mode='r:gz') as archive:
    upstream=archive.extractfile('package/crypto-js.js').read()
    license=archive.extractfile('package/LICENSE').read()
code=b'/*\n'+license+b'\n*/\n'+upstream
assets=ROOT/'Sources/ReaderCore/ScriptAssets'
vendor=ROOT/'Vendor/CryptoJS'
assets.mkdir(parents=True,exist_ok=True);vendor.mkdir(parents=True,exist_ok=True)
(assets/'crypto-js.js').write_bytes(code)
(vendor/'LICENSE').write_bytes(license)
(vendor/'UPSTREAM.json').write_text(json.dumps({'version':VERSION,'source':'https://github.com/brix/crypto-js','tarball':metadata['dist']['tarball'],'npmIntegrity':metadata['dist']['integrity'],'upstreamJavascriptSHA256':hashlib.sha256(upstream).hexdigest(),'javascriptSHA256':hashlib.sha256(code).hexdigest(),'modifications':'Prepended upstream MIT notice; algorithm implementation unchanged.'},indent=2)+'\n',encoding='utf-8')
print('Verified CryptoJS',VERSION,len(code),'bytes',hashlib.sha256(code).hexdigest())
