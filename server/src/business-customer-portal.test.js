import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizePortalRequest} from './business-customer-portal.js';
test('customer portal requests require a supported type and useful reason',()=>{
 assert.deepEqual(normalizePortalRequest({type:'support',reason:'Please check my order'}),{type:'support',reason:'Please check my order'});
 assert.throws(()=>normalizePortalRequest({type:'other',reason:'Please check'}));
 assert.throws(()=>normalizePortalRequest({type:'return',reason:'no'}));
});
