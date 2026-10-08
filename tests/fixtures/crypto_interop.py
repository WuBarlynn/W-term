"""Independent AES-GCM/HKDF interop with synthetic keys passed on stdin only."""
import base64
import json
import os
import sys
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

source = json.load(sys.stdin)
root = base64.b64decode(source['root'], validate=True)
packet = json.loads(source['packet'])
aad = json.dumps(packet['header'], ensure_ascii=False, separators=(',', ':')).encode()

def key(salt):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt,
                info=b'wterm-sync-v1' + aad).derive(root)

sealed = packet['sealed']
salt = base64.b64decode(sealed['salt'], validate=True)
nonce = base64.b64decode(sealed['nonce'], validate=True)
plaintext = AESGCM(key(salt)).decrypt(nonce, base64.b64decode(sealed['ciphertext'], validate=True), aad)
assert json.loads(plaintext)['records'][0]['value']['password'] == 'unique-sync-plaintext'
salt, nonce = os.urandom(32), os.urandom(12)
ciphertext = AESGCM(key(salt)).encrypt(nonce, plaintext, aad)
packet['sealed'] = {name: base64.b64encode(value).decode() for name, value in
                    [('salt', salt), ('nonce', nonce), ('ciphertext', ciphertext)]}
json.dump(packet, sys.stdout, ensure_ascii=False, separators=(',', ':'))
