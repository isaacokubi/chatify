import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeApiKeyRequest,hashApiKey,createApiKeyToken,hasApiScope} from './business-public-api.js';
test('API key creation enforces labels, allowed scopes and bounded expiry',()=>{
 assert.deepEqual(normalizeApiKeyRequest({label:'Accounting sync',scopes:['catalog:read'],expiresInDays:30}),{label:'Accounting sync',scopes:['catalog:read'],expiresInDays:30});
 assert.throws(()=>normalizeApiKeyRequest({label:'',scopes:['catalog:read']}));
 assert.throws(()=>normalizeApiKeyRequest({label:'All access',scopes:['admin:*']}));
 assert.throws(()=>normalizeApiKeyRequest({label:'Long lived',expiresInDays:500}));
});
test('API key tokens are opaque and only their digest is used for lookup',()=>{
 const token=createApiKeyToken();assert.match(token,/^cfy_[A-Za-z0-9_-]{40,60}$/);
 assert.equal(hashApiKey(token),hashApiKey(token));assert.notEqual(hashApiKey(token),token);
});
test('revoked and expired keys cannot use a scope',()=>{
 assert.equal(hasApiScope({scopes:['catalog:read']},'catalog:read'),true);
 assert.equal(hasApiScope({scopes:['catalog:read'],revokedAt:new Date()},'catalog:read'),false);
 assert.equal(hasApiScope({scopes:['catalog:read'],expiresAt:new Date(0)},'catalog:read'),false);
});
