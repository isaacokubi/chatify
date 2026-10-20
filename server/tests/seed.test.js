import test from 'node:test';
import assert from 'node:assert/strict';
import {nextDemoSessionVersion,resolveDemoSeedConfig} from '../src/seedConfig.js';

const valid={NODE_ENV:'development',CHATIFY_SEED_DEMO:'YES',SEED_DEMO_PASSWORD:'safe-demo-password',MONGODB_URI:'mongodb://test.invalid/chatify-demo'};

test('demo seeding validates environment, explicit opt-in, secret and a clearly non-production database',()=>{
  assert.deepEqual(resolveDemoSeedConfig(valid),{uri:valid.MONGODB_URI,databaseName:'chatify-demo',passwordValue:valid.SEED_DEMO_PASSWORD,dryRun:false});
  assert.equal(resolveDemoSeedConfig(valid,['--dry-run']).dryRun,true);
  assert.equal(resolveDemoSeedConfig({...valid,SEED_DEMO_PASSWORD:undefined,DEMO_SEED_PASSWORD:'safe-legacy-password'}).passwordValue,'safe-legacy-password');
  assert.equal(resolveDemoSeedConfig({...valid,MONGODB_URI:'mongodb://test.invalid/chatify',CHATIFY_SEED_ALLOW_UNCLASSIFIED_DATABASE:'YES'}).databaseName,'chatify');
  for(const patch of [{NODE_ENV:'production'},{CHATIFY_SEED_DEMO:'NO'},{SEED_DEMO_PASSWORD:undefined},{SEED_DEMO_PASSWORD:'short'},{MONGODB_URI:''},{MONGODB_URI:'mongodb://localhost/chatify'},{MONGODB_URI:'mongodb://localhost/chatify-production'}]){
    assert.throws(()=>resolveDemoSeedConfig({...valid,...patch}));
  }
});

test('changing a managed demo password revokes prior sessions, while a matching password preserves them',()=>{
  assert.equal(nextDemoSessionVersion(3,false),4);
  assert.equal(nextDemoSessionVersion(3,true),3);
  assert.equal(nextDemoSessionVersion(undefined,false),1);
});
