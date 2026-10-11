import test from 'node:test';
import assert from 'node:assert/strict';
import {resolveDemoSeedConfig} from '../src/seedConfig.js';

const valid={NODE_ENV:'development',CHATIFY_SEED_DEMO:'YES',DEMO_SEED_PASSWORD:'safe-demo-password',MONGODB_URI:'mongodb://test.invalid/chatify-demo'};

test('demo seeding requires development, explicit opt-in, password and database',()=>{
  assert.deepEqual(resolveDemoSeedConfig(valid),{uri:valid.MONGODB_URI,passwordValue:valid.DEMO_SEED_PASSWORD});
  for(const patch of [{NODE_ENV:'production'},{CHATIFY_SEED_DEMO:'NO'},{DEMO_SEED_PASSWORD:undefined},{DEMO_SEED_PASSWORD:'short'},{MONGODB_URI:''}]){
    assert.throws(()=>resolveDemoSeedConfig({...valid,...patch}));
  }
});
