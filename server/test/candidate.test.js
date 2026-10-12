import test from 'node:test';
import assert from 'node:assert/strict';
import {candidate} from '../src/memory.js';

test('detects an event with time and location', () => {
  const result = candidate('Meeting tomorrow at 3:30 PM at Nairobi office.');
  assert.equal(result[0].type, 'EVENT');
  assert.equal(result[0].time, '3:30 PM');
  assert.match(result[0].location, /Nairobi office/i);
});

test('detects explicit task reminders', () => {
  const result = candidate('Remember to submit the project report.');
  assert.equal(result[0].type, 'TASK');
  assert.match(result[0].description, /submit the project report/i);
});

test('detects Kenyan shilling payments', () => {
  const result = candidate('I paid KES 2,500 for hosting.');
  assert.equal(result[0].type, 'PAYMENT');
});

test('detects useful personal details', () => {
  const result = candidate('I live in Nairobi and I prefer quiet places.');
  assert.ok(result.some(item => item.type === 'NOTE'));
  assert.ok(result.some(item => item.type === 'PLACE'));
});

test('ordinary conversation does not create noisy suggestions', () => {
  assert.deepEqual(candidate('Okay, see you soon.'), []);
  assert.deepEqual(candidate('Thanks for the help!'), []);
});

test('empty, non-text and oversized inputs are handled safely', () => {
  assert.deepEqual(candidate(''), []);
  assert.deepEqual(candidate(null), []);
  assert.ok(candidate('Remember to ' + 'x'.repeat(6000)).length <= 3);
});
