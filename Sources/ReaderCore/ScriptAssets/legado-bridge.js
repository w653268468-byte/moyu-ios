/* Gavin's independently implemented compatibility adapters. */
(function () {
    'use strict';
    const C = globalThis.CryptoJS;
    const signed = w => Array.from({length:w.sigBytes}, (_,i) => ((w.words[i>>>2] >>> (24-(i%4)*8)) & 255) << 24 >> 24);
    function bytes(value) {
        if (value && Array.isArray(value.words) && Number.isInteger(value.sigBytes)) return value.clone();
        if (Array.isArray(value) || ArrayBuffer.isView(value)) {
            if (value.length > 2*1024*1024 || Array.from(value).some(x => !Number.isInteger(x) || x < -128 || x > 255)) throw new Error('Invalid byte array');
            const words=[]; for(let i=0;i<value.length;i++) words[i>>>2] = (words[i>>>2]||0) | ((value[i]&255) << (24-(i%4)*8));
            return C.lib.WordArray.create(words,value.length);
        }
        return C.enc.Utf8.parse(String(value ?? ''));
    }
    function encrypted(value) {
        if (typeof value !== 'string') return bytes(value);
        const text=value.replace(/\s/g,'');
        if (/^[\da-f]+$/i.test(text) && text.length%2===0) return C.enc.Hex.parse(text);
        if (!/^[A-Za-z0-9+/]*={0,2}$/.test(text) || text.length%4===1) throw new Error('Invalid ciphertext');
        return C.enc.Base64.parse(text);
    }
    function cipher(transformation,key,iv) {
        const parts=String(transformation).split('/');
        const name=parts[0].toUpperCase();
        const algorithm={AES:C.AES,DES:C.DES,DESEDE:C.TripleDES,TRIPLEDES:C.TripleDES}[name];
        const mode={CBC:C.mode.CBC,ECB:C.mode.ECB,CFB:C.mode.CFB,OFB:C.mode.OFB,CTR:C.mode.CTR}[(parts[1]||'ECB').toUpperCase()];
        const padding={PKCS5PADDING:C.pad.Pkcs7,PKCS7PADDING:C.pad.Pkcs7,NOPADDING:C.pad.NoPadding,ZEROPADDING:C.pad.ZeroPadding,ISO10126PADDING:C.pad.Iso10126,ISO97971PADDING:C.pad.Iso97971,ANSIX923PADDING:C.pad.AnsiX923}[(parts[2]||'PKCS5Padding').toUpperCase()];
        if (!algorithm || !mode || !padding || parts.length>3) throw new Error('Unsupported cipher transformation: '+transformation);
        let secret=key==null ? C.lib.WordArray.random(name==='AES'?16:name==='DES'?8:24) : bytes(key);
        const block=name==='AES'?16:8;
        if (!(name==='AES'?[16,24,32]:name==='DES'?[8]:[16,24]).includes(secret.sigBytes)) throw new Error('Invalid cipher key length');
        let vector=iv==null || iv==='' || iv.sigBytes===0 ? C.lib.WordArray.create(Array(block/4).fill(0),block) : bytes(iv);
        function options() { if(mode!==C.mode.ECB && vector.sigBytes!==block) throw new Error('Invalid cipher IV length'); return {iv:vector,mode,padding}; }
        function check(data) { if((mode===C.mode.ECB || mode===C.mode.CBC) && data.sigBytes%block!==0) throw new Error('Ciphertext is not block aligned'); }
        function decrypt(data) {
            const value=encrypted(data); check(value);
            // Verify PKCS#5/#7 padding instead of silently accepting a wrong key.
            if(padding===C.pad.Pkcs7) {
                const plain=algorithm.decrypt({ciphertext:value},secret,{...options(),padding:C.pad.NoPadding});
                const array=signed(plain), size=(array[array.length-1]||0)&255;
                if(size<1 || size>block || size>array.length || !array.slice(-size).every(x=>(x&255)===size)) throw new Error('Invalid cipher padding');
                plain.sigBytes-=size; plain.clamp(); return plain;
            }
            return algorithm.decrypt({ciphertext:value},secret,options());
        }
        function encrypt(data) {
            const value=bytes(data);
            if(padding===C.pad.NoPadding && (mode===C.mode.ECB || mode===C.mode.CBC)) check(value);
            return algorithm.encrypt(value,secret,options()).ciphertext;
        }
        return {
            decrypt:data=>signed(decrypt(data)),
            decryptStr:(data,charset='UTF-8')=>gavinCall('decodeBytes',[signed(decrypt(data)),charset]),
            encrypt:data=>signed(encrypt(data)),
            encryptBase64:data=>encrypt(data).toString(C.enc.Base64),
            encryptHex:data=>encrypt(data).toString(C.enc.Hex),
            setIv(value){vector=bytes(value);return this;},
            getSecretKey(){return {getEncoded:()=>signed(secret)};}
        };
    }
    const memory=new Map();
    globalThis.cache={
        get:key=>gavinCall('cacheGet',[String(key)]),
        put:(key,value,seconds=0)=>gavinCall('cachePut',[String(key),String(value),Number(seconds)]),
        delete:key=>gavinCall('cacheDelete',[String(key)]),
        getFile:key=>gavinCall('cacheGet',['file:'+key]),
        putFile:(key,value,seconds=0)=>gavinCall('cachePut',['file:'+key,String(value),Number(seconds)]),
        putMemory:(key,value)=>{if(memory.size>=1000&&!memory.has(key))memory.delete(memory.keys().next().value);memory.set(key,value);},
        getFromMemory:key=>memory.get(key)??null,
        deleteMemory:key=>memory.delete(key)
    };
    function map(value) {
        const result=typeof value==='string' ? JSON.parse(value||'{}') : value||{};
        if(!result || typeof result!=='object' || Array.isArray(result))throw new Error('Expected object map');
        Object.defineProperty(result,'get',{value:key=>result[key]??null,configurable:true}); return result;
    }
    globalThis.__gavinHydrate=function(name,value) {
        if(!['source','book','chapter'].includes(name) || !value || typeof value!=='object') return value;
        const id=name==='source' ? value.bookSourceUrl||'' : name==='book' ? value.bookUrl||'' : value.url||'';
        function get(key) { return name==='source' ? cache.get('source:'+key)??'' : gavinCall('get',[name+':'+id+':'+key]); }
        function put(key,item) { if(name==='source')cache.put('source:'+key,item??'');else gavinCall('put',[name+':'+id+':'+key,String(item??'')]);return item; }
        const methods={
            getKey:()=>id,
            getVariable:key=>get(key==null?'@variable':key) || (key==null?value.variable||'':''),
            putVariable:function(key,item){return arguments.length===1?put('@variable',key):put(key,item);},
            setVariable:item=>put('@variable',item),
            get,put,
            getLoginInfo:()=>get('@loginInfo')||null,
            getLoginInfoMap:()=>map(get('@loginInfo')),
            putLoginInfo:item=>put('@loginInfo',typeof item==='string'?item:JSON.stringify(item)),
            removeLoginInfo:()=>put('@loginInfo',''),
            getLoginHeader:()=>get('@loginHeader')||null,
            getLoginHeaderMap:()=>map(get('@loginHeader')),
            putLoginHeader:item=>put('@loginHeader',typeof item==='string'?item:JSON.stringify(item)),
            removeLoginHeader:()=>put('@loginHeader','')
        };
        for(const [key,fn] of Object.entries(methods))Object.defineProperty(value,key,{value:fn,enumerable:false,configurable:true});
        return value;
    };
    globalThis.cookie={
        getCookie:url=>gavinCall('getCookie',[String(url)]),
        getKey:(url,key)=>{const match=gavinCall('getCookie',[String(url)]).split(';').map(x=>x.trim()).find(x=>x.split('=')[0]===key);return match?match.slice(match.indexOf('=')+1):'';},
        setCookie:(url,value)=>gavinCall('setCookie',[String(url),String(value)]),
        replaceCookie:(url,value)=>{gavinCall('removeCookie',[String(url)]);gavinCall('setCookie',[String(url),String(value)]);},
        removeCookie:url=>gavinCall('removeCookie',[String(url)]),
        setWebCookie:(url,value)=>gavinCall('setCookie',[String(url),String(value)])
    };
    function JavaString(value,charset='UTF-8') { return new String(Array.isArray(value)||ArrayBuffer.isView(value)?gavinCall('decodeBytes',[Array.from(value),charset]):String(value??'')); }
    if(!String.prototype.getBytes)Object.defineProperty(String.prototype,'getBytes',{value:function(charset='UTF-8'){return gavinCall('encodeBytes',[String(this),charset]);}});
    const numeric={parseInt:value=>parseInt(value,10),parseLong:value=>parseInt(value,10),valueOf:value=>Number(value)};
    const helpers={
        createSymmetricCrypto:cipher,
        aesDecodeToString:(data,key,mode,iv)=>cipher(mode,key,iv).decryptStr(data),
        aesBase64DecodeToString:(data,key,mode,iv)=>cipher(mode,key,iv).decryptStr(data),
        aesDecodeToByteArray:(data,key,mode,iv)=>cipher(mode,key,iv).decrypt(data),
        aesEncodeToByteArray:(data,key,mode,iv)=>cipher(mode,key,iv).encrypt(data),
        aesEncodeToBase64String:(data,key,mode,iv)=>cipher(mode,key,iv).encryptBase64(data),
        aesDecodeArgsBase64Str:(data,key,mode,padding,iv)=>cipher('AES/'+mode+'/'+padding,C.enc.Base64.parse(key),C.enc.Base64.parse(iv)).decryptStr(data),
        desDecodeToString:(data,key,mode,iv)=>cipher(mode,key,iv).decryptStr(data),
        desBase64DecodeToString:(data,key,mode,iv)=>cipher(mode,key,iv).decryptStr(data),
        desEncodeToBase64String:(data,key,mode,iv)=>cipher(mode,key,iv).encryptBase64(data),
        tripleDESDecodeStr:(data,key,mode,padding,iv)=>cipher('DESede/'+mode+'/'+padding,key,iv).decryptStr(data),
        tripleDESEncodeBase64Str:(data,key,mode,padding,iv)=>cipher('DESede/'+mode+'/'+padding,key,iv).encryptBase64(data),
        base64Encode:value=>bytes(value).toString(C.enc.Base64),
        base64DecodeToByteArray:value=>signed(C.enc.Base64.parse(String(value))),
        byteArrayToString:(value,charset='UTF-8')=>gavinCall('decodeBytes',[Array.from(value),charset]),
        encodeURI:(value,charset='UTF-8')=>gavinCall('encodeURI',[String(value),charset]),
        decodeURI:value=>decodeURIComponent(String(value).replace(/\+/g,' ')),
        lang:{String:JavaString,Integer:numeric,Long:numeric,Double:{parseDouble:Number,valueOf:Number}},
        androidId:()=>{let id=cache.get('@installationID');if(!id){id=gavinCall('randomUUID',[]);cache.put('@installationID',id);}return id;}
    };
    const original=globalThis.java;
    globalThis.java=new Proxy(original,{get:(target,name)=>Object.prototype.hasOwnProperty.call(helpers,name)?helpers[name]:Reflect.get(target,name)});
    globalThis.Packages={java:globalThis.java,org:globalThis.org};
    globalThis.source=__gavinHydrate('source',globalThis.source);
    globalThis.book=__gavinHydrate('book',globalThis.book);
    globalThis.chapter=__gavinHydrate('chapter',globalThis.chapter);
})();
