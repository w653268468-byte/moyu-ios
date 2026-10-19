/* Explicit Java API adapters for source scripts; no access to the host JVM or files. */
(function () {
    'use strict';
    const C=globalThis.CryptoJS, nativeJava=globalThis.java;
    function array(value) {
        const result=typeof value==='string'||value instanceof String?Array.from(value.getBytes()):Array.from(value||[]);
        if(result.length>2*1024*1024 || result.some(x=>!Number.isInteger(x)||x < -128||x > 255))throw new Error('Invalid Java byte array');
        return result.map(x=>x<<24>>24);
    }
    function word(value) {const a=array(value),w=[];for(let i=0;i<a.length;i++)w[i>>>2]=(w[i>>>2]||0)|((a[i]&255)<<(24-i%4*8));return C.lib.WordArray.create(w,a.length);}
    function signed(w) {return Array.from({length:w.sigBytes},(_,i)=>((w.words[i>>>2]>>>(24-i%4*8))&255)<<24>>24);}
    function SecretKeySpec(value,algorithm) {const key=array(value);return {algorithm:String(algorithm),getEncoded:()=>key.slice(),getAlgorithm:()=>String(algorithm),kind:'secret'};}
    function IvParameterSpec(value) {const iv=array(value);return {getIV:()=>iv.slice()};}
    function keySpec(value) {const encoded=array(value);return {getEncoded:()=>encoded.slice()};}
    function PKCS8EncodedKeySpec(value){return keySpec(value);}
    function X509EncodedKeySpec(value){return keySpec(value);}
    function ByteArrayOutputStream() {let buffer=[];return {
        write(value,offset=0,length){const bytes=typeof value==='number'?[value<<24>>24]:array(value);const count=length==null?bytes.length-offset:length;if(!Number.isInteger(offset)||!Number.isInteger(count)||offset<0||count<0||offset+count>bytes.length||buffer.length+count>2*1024*1024)throw new Error('ByteArrayOutputStream range or size exceeded');buffer=buffer.concat(bytes.slice(offset,offset+count));},
        toByteArray:()=>buffer.slice(),size:()=>buffer.length,reset(){buffer=[];},close(){},toString:(charset='UTF-8')=>nativeJava.byteArrayToString(buffer,charset)
    };}
    const KeyFactory={getInstance(algorithm){if(String(algorithm).toUpperCase()!=='RSA')throw new Error('Unsupported KeyFactory: '+algorithm);return {
        generatePrivate:spec=>({getEncoded:()=>array(spec.getEncoded()),kind:'private'}),
        generatePublic:spec=>({getEncoded:()=>array(spec.getEncoded()),kind:'public'})
    };}};
    const Cipher={ENCRYPT_MODE:1,DECRYPT_MODE:2,getInstance(algorithm){let implementation,mode,key;
        return {init(operation,secret,parameters){
            if(operation!==1&&operation!==2)throw new Error('Unsupported Cipher mode');mode=operation;key=secret;
            if(String(algorithm).toUpperCase().startsWith('RSA')) {
                implementation=nativeJava.createAsymmetricCrypto(algorithm);
                if(secret.kind==='public')implementation.setPublicKey(secret.getEncoded());
                else if(secret.kind==='private')implementation.setPrivateKey(secret.getEncoded());
                else throw new Error('RSA Cipher requires an RSA key');
            } else implementation=nativeJava.createSymmetricCrypto(algorithm,secret.getEncoded(),parameters?parameters.getIV():null);
        },doFinal(value){
            if(!implementation)throw new Error('Cipher is not initialized');
            if(String(algorithm).toUpperCase().startsWith('RSA'))return mode===1?implementation.encrypt(array(value),key.kind==='public'):implementation.decrypt(array(value),key.kind==='public');
            return mode===1?implementation.encrypt(array(value)):implementation.decrypt(array(value));
        }};
    }};
    const Base64={
        getDecoder:()=>({decode:value=>signed(C.enc.Base64.parse(String(value)))}),
        getEncoder:()=>({encodeToString:value=>word(value).toString(C.enc.Base64),encode:value=>array(word(value).toString(C.enc.Base64))}),
        getUrlDecoder:()=>({decode:value=>signed(C.enc.Base64.parse(String(value).replace(/-/g,'+').replace(/_/g,'/')))}),
        getUrlEncoder:()=>({encodeToString:value=>word(value).toString(C.enc.Base64).replace(/\+/g,'-').replace(/\//g,'_')})
    };
    const Arrays={copyOfRange(value,start,end){const a=array(value);if(!Number.isInteger(start)||!Number.isInteger(end)||start<0||start>a.length||end<start||end-start>2*1024*1024)throw new Error('Invalid array range');return Array.from({length:end-start},(_,i)=>a[start+i]??0);},copyOf:(value,length)=>Arrays.copyOfRange(value,0,length)};
    const MessageDigest={getInstance(algorithm){const name=String(algorithm).toUpperCase().replace(/-/g,''),digest={MD5:C.MD5,SHA1:C.SHA1,SHA256:C.SHA256,SHA384:C.SHA384,SHA512:C.SHA512}[name];if(!digest)throw new Error('Unsupported MessageDigest: '+algorithm);let chunks=[];return {
        update(value){chunks=chunks.concat(array(value));if(chunks.length>2*1024*1024)throw new Error('Digest input too large');},
        digest(value){if(value!=null)this.update(value);const result=signed(digest(word(chunks)));chunks=[];return result;},reset(){chunks=[];}
    };}};
    const Signature={getInstance(algorithm){let signer,mode,buffer=[];return {
        initSign(key){signer=nativeJava.createSign(algorithm).setPrivateKey(key.getEncoded());mode='sign';buffer=[];},
        initVerify(key){signer=nativeJava.createSign(algorithm).setPublicKey(key.getEncoded());mode='verify';buffer=[];},
        update(value){buffer=buffer.concat(array(value));if(buffer.length>2*1024*1024)throw new Error('Signature input too large');},
        sign(){if(mode!=='sign')throw new Error('Signature is not initialized for signing');const value=signer.sign(buffer);buffer=[];return value;},
        verify(value){if(mode!=='verify')throw new Error('Signature is not initialized for verification');const valid=signer.verify(buffer,array(value));buffer=[];return valid;}
    };}};
    function JavaImporter(...packages) {
        const imports={};
        Object.defineProperty(imports,'importPackage',{value:function(...values){for(const value of values){if(value&&value.__javaName){imports[value.__javaName]=value;continue;}if(!value||typeof value!=='object')throw new Error('Unsupported Java package');Object.assign(imports,value);}return imports;}});
        Object.defineProperty(imports,'importClass',{value:function(...values){for(const value of values){const name=value&&value.__javaName||value&&value.name;if(!name)throw new Error('Unsupported Java class');imports[name]=value;}return imports;}});
        imports.importPackage(...packages);return imports;
    }
    for(const [name,value] of Object.entries({Cipher,KeyFactory,MessageDigest,Signature,Base64,Arrays,SecretKeySpec,IvParameterSpec,PKCS8EncodedKeySpec,X509EncodedKeySpec,ByteArrayOutputStream,String:nativeJava.lang.String}))Object.defineProperty(value,'__javaName',{value:name});
    const security={KeyFactory,MessageDigest,Signature,spec:{PKCS8EncodedKeySpec,X509EncodedKeySpec}};
    const util={Base64,Arrays};
    const io={ByteArrayOutputStream};
    function toNumChapter(value) {
        if(value==null)return null;
        const match=String(value).match(/第(.+?)章/);if(!match)return String(value);
        const raw=match[1].replace(/[０-９]/g,ch=>String(ch.charCodeAt(0)-0xff10)).replace(/\s/g,'');
        const digits={'零':0,'〇':0,'一':1,'壹':1,'二':2,'贰':2,'貳':2,'两':2,'兩':2,'三':3,'叁':3,'參':3,'四':4,'肆':4,'五':5,'伍':5,'六':6,'陆':6,'陸':6,'七':7,'柒':7,'八':8,'捌':8,'九':9,'玖':9};
        const units={'十':10,'拾':10,'百':100,'佰':100,'千':1000,'仟':1000,'万':10000,'萬':10000,'亿':100000000,'億':100000000};
        let number=-1;
        if(/^\d+$/.test(raw))number=Number(raw);
        else if(Array.from(raw).every(ch=>ch in digits))number=Number(Array.from(raw,ch=>digits[ch]).join(''));
        else {
            let total=0,section=0,current=0,previous=0,valid=true;
            for(const [index,ch] of Array.from(raw).entries()) {
                if(ch in digits) {current=digits[ch];if(index===raw.length-1&&previous>=100)current*=previous/10;previous=0;}
                else if(ch in units) {const unit=units[ch];if(unit<10000)section+=(current||1)*unit;else if(unit===10000)section=(section+current)*unit;else {total+=(section+current)*unit;section=0;}current=0;previous=unit;}
                else {valid=false;break;}
            }
            if(valid)number=total+section+current;
        }
        if(!Number.isInteger(number)||number<0||number>2147483647)number=-1;
        return '第'+number+'章';
    }
    globalThis.java=new Proxy(nativeJava,{get:(target,name)=>name==='security'?security:name==='util'?util:name==='io'?io:name==='toNumChapter'?toNumChapter:Reflect.get(target,name)});
    const javax={crypto:{Cipher,spec:{SecretKeySpec,IvParameterSpec}}};
    const CodecBase64={encode:value=>word(value).toString(C.enc.Base64),decode:value=>signed(C.enc.Base64.parse(String(value))),decodeStr:value=>C.enc.Base64.parse(String(value)).toString(C.enc.Utf8),encodeUrlSafe:value=>word(value).toString(C.enc.Base64).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'')};
    function digestFacade(algorithm,key) {
        const name=String(algorithm).toUpperCase().replace(/^HMAC/,'').replace(/-/g,''),hash={MD5:C.MD5,SHA1:C.SHA1,SHA256:C.SHA256,SHA384:C.SHA384,SHA512:C.SHA512}[name];
        if(!hash)throw new Error('Unsupported digest: '+algorithm);
        const keyed={MD5:C.HmacMD5,SHA1:C.HmacSHA1,SHA256:C.HmacSHA256,SHA384:C.HmacSHA384,SHA512:C.HmacSHA512}[name];
        const digest=value=>key==null?hash(word(value)):keyed(word(value),word(key));
        return {digest:value=>signed(digest(value)),digestHex:value=>digest(value).toString(C.enc.Hex),digestBase64:value=>digest(value).toString(C.enc.Base64)};
    }
    function MD5(){return digestFacade('MD5');}MD5.create=()=>MD5();
    function HMac(algorithm,key){return digestFacade(algorithm,key);}
    const HmacAlgorithm={HmacMD5:'HmacMD5',HmacSHA1:'HmacSHA1',HmacSHA256:'HmacSHA256',HmacSHA384:'HmacSHA384',HmacSHA512:'HmacSHA512'};
    const DigestUtil={md5Hex:value=>MD5().digestHex(value),sha1Hex:value=>digestFacade('SHA1').digestHex(value),sha256Hex:value=>digestFacade('SHA256').digestHex(value),hmac:(algorithm,key)=>HMac(algorithm,key)};
    const SecureUtil={...DigestUtil,aes:key=>nativeJava.createSymmetricCrypto('AES/ECB/PKCS5Padding',key),des:key=>nativeJava.createSymmetricCrypto('DES/ECB/PKCS5Padding',key)};
    const CharsetUtil={UTF_8:'UTF-8',CHARSET_UTF_8:'UTF-8',GBK:'GBK'};
    const StrUtil={isBlank:value=>value==null||!String(value).trim(),isNotBlank:value=>value!=null&&!!String(value).trim(),utf8Str:value=>nativeJava.byteArrayToString(array(value),'UTF-8'),bytes:(value,charset='UTF-8')=>String(value).getBytes(charset)};
    function RequestBody(){}RequestBody.create=(first,second)=>{
        const isMedia=value=>value&&value.__mediaType;
        const data=isMedia(first)?second:first,type=isMedia(first)?first:second;
        return {text:Array.isArray(data)||ArrayBuffer.isView(data)?undefined:String(data??''),bytes:Array.isArray(data)||ArrayBuffer.isView(data)?array(data):undefined,type:type&&type.__mediaType||'application/octet-stream'};
    };
    const MediaType={parse:value=>({__mediaType:String(value)}),get:value=>({__mediaType:String(value)})};
    function RequestBuilder(){let address='',method='GET',body;const headers={};const api={
        url(value){address=String(value);return api;},get(){method='GET';body=undefined;return api;},post(value){if(!value||(typeof value.text!=='string'&&!Array.isArray(value.bytes)))throw new Error('Invalid RequestBody');method='POST';body=value;headers['Content-Type']=value.type;return api;},
        addHeader(name,value){headers[String(name)]=String(value);return api;},header(name,value){return api.addHeader(name,value);},
        build(){if(!/^https?:\/\//i.test(address))throw new Error('Request requires an HTTP URL');return {url:address,method,body,headers:{...headers}};}
    };return api;}
    const Request={Builder:RequestBuilder};
    function OkHttpClient(){return {newCall:request=>({execute(){
        const options={method:request.method,headers:request.headers};if(request.method==='POST'){if(request.body.bytes)options.bodyBase64=CodecBase64.encode(request.body.bytes);else options.body=request.body.text;}
        return gavinCall('connect',[request.url+','+JSON.stringify(options)]).raw();
    }})};}OkHttpClient.Builder=function(){return {build:()=>OkHttpClient()};};
    StrUtil.reverse=value=>Array.from(String(value)).reverse().join('');
    const ZipUtil={gzip:value=>gavinCall('gzip',[array(value)]),unGzip:value=>gavinCall('ungzip',[array(value)])};
    const cn={hutool:{core:{codec:{Base64:CodecBase64},util:{CharsetUtil,StrUtil,ZipUtil}},crypto:{SecureUtil,digest:{MD5,HMac,HmacAlgorithm,DigestUtil}}}};
    const okhttp3={Request,RequestBody,MediaType,OkHttpClient};
    for(const [name,value] of Object.entries({MD5,HMac,HmacAlgorithm,DigestUtil,SecureUtil,CharsetUtil,StrUtil,ZipUtil,Request,RequestBody,MediaType,OkHttpClient}))Object.defineProperty(value,'__javaName',{value:name});
    Object.defineProperty(CodecBase64,'__javaName',{value:'Base64'});
    globalThis.Packages={...globalThis.Packages,java:globalThis.java,javax,cn,okhttp3};
    globalThis.javax=javax;globalThis.JavaImporter=JavaImporter;
})();
