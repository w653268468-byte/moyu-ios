// Generates public TEST KEYS only. Never use these keys for real accounts.
const crypto=require('node:crypto'),fs=require('node:fs');
const {publicKey,privateKey}=crypto.generateKeyPairSync('rsa',{modulusLength:2048});
const text='三国演义·复杂书源兼容验证';
const value={notice:'Public test keypair; not a credential.',text,
    publicKey:publicKey.export({format:'pem',type:'spki'}),privateKey:privateKey.export({format:'pem',type:'pkcs8'}),
    publicPKCS1:publicKey.export({format:'pem',type:'pkcs1'}),privatePKCS1:privateKey.export({format:'pem',type:'pkcs1'}),
    publicCipher:crypto.publicEncrypt({key:publicKey,padding:crypto.constants.RSA_PKCS1_PADDING},Buffer.from(text)).toString('base64'),
    privateCipher:crypto.privateEncrypt({key:privateKey,padding:crypto.constants.RSA_PKCS1_PADDING},Buffer.from(text)).toString('base64'),
    oaepCipher:crypto.publicEncrypt({key:publicKey,padding:crypto.constants.RSA_PKCS1_OAEP_PADDING,oaepHash:'sha256'},Buffer.from(text)).toString('base64'),
    signatures:Object.fromEntries(['md5','sha1','sha256','sha384','sha512'].map(algorithm=>[algorithm,crypto.sign(algorithm,Buffer.from(text),privateKey).toString('base64')]))};
fs.mkdirSync('Tests/ReaderCoreTests/Fixtures',{recursive:true});
fs.writeFileSync('Tests/ReaderCoreTests/Fixtures/rsa-public-test-keys.json',JSON.stringify(value,null,2)+'\n');
console.log('Generated independent RSA/OpenSSL vectors with public test keys.');
