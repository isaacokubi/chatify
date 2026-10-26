import test from 'node:test';
import assert from 'node:assert/strict';
import jwt from 'jsonwebtoken';
import {createAuthMiddleware,createAdminMiddleware} from './auth.js';
function response() { return {statusCode:200,body:undefined,status(code){this.statusCode=code;return this;},json(value){this.body=value;return this;}}; }
async function runAuth({payload,user,token='test-token',verifyToken=()=>payload}) {
 const req={headers:{authorization:`Bearer ${token}`}}; const res=response(); let continued=false;
 const middleware=createAuthMiddleware({verifyToken,findUser:async()=>user});
 await middleware(req,res,()=>{continued=true;}); return {req,res,continued};
}
test('accepts a token with the current session version',async()=>{const x=await runAuth({payload:{sub:'user-1',sv:3},user:{_id:'user-1',status:'active',sessionVersion:3}});assert.equal(x.continued,true);});
test('rejects an expired signed JWT before looking up its account',async()=>{const secret='auth-expiry-test-secret-0123456789abcdef';const token=jwt.sign({sub:'user-1',sv:0},secret,{expiresIn:-1});let accountLookups=0;const res=response();let continued=false;const middleware=createAuthMiddleware({verifyToken:value=>jwt.verify(value,secret),findUser:async()=>{accountLookups++;return {_id:'user-1',status:'active',sessionVersion:0};}});await middleware({headers:{authorization:`Bearer ${token}`}},res,()=>{continued=true;});assert.equal(res.statusCode,401);assert.deepEqual(res.body,{error:'Authentication required'});assert.equal(accountLookups,0);assert.equal(continued,false);});
test('rejects tokens issued before a password change',async()=>{const x=await runAuth({payload:{sub:'user-1',sv:2},user:{_id:'user-1',status:'active',sessionVersion:3}});assert.equal(x.res.statusCode,401);assert.match(x.res.body.error,/Session expired/);});
test('accepts legacy tokens only while account version is zero',async()=>{const valid=await runAuth({payload:{sub:'user-1'},user:{_id:'user-1',status:'active',sessionVersion:0}});const revoked=await runAuth({payload:{sub:'user-1'},user:{_id:'user-1',status:'active',sessionVersion:1}});assert.equal(valid.continued,true);assert.equal(revoked.res.statusCode,401);});
test('rejects suspended or missing accounts',async()=>{const suspended=await runAuth({payload:{sub:'user-1',sv:0},user:{_id:'user-1',status:'suspended',sessionVersion:0}});const missing=await runAuth({payload:{sub:'user-1',sv:0},user:null});assert.equal(suspended.res.statusCode,401);assert.equal(missing.res.statusCode,401);});
test('rejects invalid session-version claims',async()=>{const x=await runAuth({payload:{sub:'user-1',sv:'NaN'},user:{_id:'user-1',status:'active',sessionVersion:0}});assert.equal(x.res.statusCode,401);});
test('administrator middleware allows only a server-loaded admin role',()=>{
 const requireAdmin=createAdminMiddleware();
 const res=response(); let nextCalls=0;
 requireAdmin({user:{role:'admin'}},res,()=>{nextCalls+=1;});
 assert.equal(nextCalls,1);
 for(const req of [{},{user:{role:'user'}},{user:{role:'owner'}}]) {
  requireAdmin(req,res,()=>{nextCalls+=1;});
  assert.equal(res.statusCode,403);
  assert.deepEqual(res.body,{error:'Administrator access required'});
 }
 assert.equal(nextCalls,1);
});
