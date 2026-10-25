import test from 'node:test';
import assert from 'node:assert/strict';
import {createWorkflowTickRunner} from './workflow-scheduler.js';

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
}

test('workflow tick skips database work while MongoDB is disconnected', async () => {
  let calls = 0;
  const runner = createWorkflowTickRunner({
    runTick: async () => { calls += 1; },
    isDatabaseReady: () => false,
    logger: {error() { throw new Error('unexpected scheduler error log'); }},
  });

  assert.deepEqual(await runner(), {skipped: 'database_unavailable'});
  assert.equal(calls, 0);
});

test('workflow tick runner prevents overlapping ticks and releases its guard', async () => {
  const started = deferred();
  const release = deferred();
  let calls = 0;
  const runner = createWorkflowTickRunner({
    runTick: async () => {
      calls += 1;
      started.resolve();
      await release.promise;
    },
    isDatabaseReady: () => true,
    logger: {error() {}},
  });

  const first = runner();
  await started.promise;
  assert.deepEqual(await runner(), {skipped: 'already_running'});
  assert.equal(calls, 1);
  release.resolve();
  assert.deepEqual(await first, {ok: true});
  assert.deepEqual(await runner(), {ok: true});
  assert.equal(calls, 2);
});

test('workflow tick logs sanitized error details and can recover on the next tick', async () => {
  const logs = [];
  let shouldFail = true;
  const runner = createWorkflowTickRunner({
    runTick: async () => {
      if (shouldFail) {
        shouldFail = false;
        throw new Error('database unavailable mongodb://user:password@example.test/db Bearer top-secret');
      }
    },
    isDatabaseReady: () => true,
    logger: {error: (...args) => logs.push(args)},
  });

  await assert.rejects(runner(), /database unavailable/);
  assert.equal(logs.length, 1);
  assert.equal(logs[0][0], 'Business workflow scheduler tick failed');
  assert.equal(logs[0][1].name, 'Error');
  assert.match(logs[0][1].message, /\[redacted MongoDB URI\]/);
  assert.match(logs[0][1].message, /Bearer \[redacted\]/);
  assert.doesNotMatch(JSON.stringify(logs), /top-secret|user:password/);
  assert.deepEqual(await runner(), {ok: true});
});
