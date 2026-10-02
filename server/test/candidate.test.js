import test from 'node:test';
import assert from 'node:assert/strict';
import {candidate} from '../src/memory.js';

test('memory extraction identifies an event with time and place', () => {
  const result = candidate('Meeting tomorrow at 3:30 PM at Nairobi office.');
  assert.equal(result[0].type, 'EVENT');
  assert.equal(result[0].time, '3:30 PM');
  assert.equal(result[0].location, 'Nairobi office');
});

test('memory extraction identifies tasks', () => {
  const result = candidate('Remember to submit the project report.');
  assert.equal(result[0].type, 'TASK');
  assert.match(result[0].description, /submit the project report/i);
});

test('memory extraction identifies KES payments', () => {
  const result = candidate('I paid KES 2,500 for hosting.');
  assert.equal(result[0].type, 'PAYMENT');
});
