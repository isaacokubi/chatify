import test from 'node:test';
import assert from 'node:assert/strict';
import {createAuthMiddleware} from '../src/auth.js';

function response() {
  return {statusCode:200,body:null,status(code) { this.statusCode=code; return this; },json(body) { this.body=body; return this; }};
}

test('payment route authentication rejects missing and invalid bearer tokens', async () => {
  let lookedUp = false;
  const auth = createAuthMiddleware({verifyToken(token) { if (token !== 'valid') throw new Error('bad token'); return {sub:'alice'}; },async findUser() { lookedUp=true; return {status:'active'}; }});
  for (const authorization of ['', 'Basic valid', 'Bearer invalid']) {
    const res=response(); let called=false;
    await auth({headers:{authorization}},res,()=>{called=true;});
    assert.equal(res.statusCode,401);
    assert.equal(called,false);
  }
  assert.equal(lookedUp,false);
});

test('payment route authentication attaches only an active authenticated user', async () => {
  const auth = createAuthMiddleware({verifyToken:token=>({sub:token}),async findUser(id) { return id==='active-user'?{_id:id,status:'active'}:{_id:id,status:'disabled'}; }});
  const authorized={headers:{authorization:'Bearer active-user'}}; const ok=response(); let proceeded=false;
  await auth(authorized,ok,()=>{proceeded=true;});
  assert.equal(proceeded,true);
  assert.equal(authorized.user._id,'active-user');
  const disabled={headers:{authorization:'Bearer disabled-user'}}; const denied=response();
  await auth(disabled,denied,()=>assert.fail('inactive user must not pass authentication'));
  assert.equal(denied.statusCode,401);
});
