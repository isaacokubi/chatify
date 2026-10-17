import test from 'node:test';
import assert from 'node:assert/strict';
import {candidate} from './memory.js';

test('memory extraction captures useful first-person context with descriptive titles', () => {
  const items = candidate('I work as a software developer at Acme and my goal is to launch a small business.');
  assert.ok(items.some(item => item.type === 'NOTE' && item.title === 'Work or business'));
  assert.ok(items.some(item => item.type === 'NOTE' && item.title === 'Goal or plan'));
});

test('memory extraction captures details about the other person in a conversation', () => {
  const items = candidate('She works at a hospital and she prefers to communicate in the morning.');
  assert.ok(items.some(item => item.type === 'NOTE' && item.title === "Other person's details"));
});

test('memory extraction keeps specific dates, preferences and dietary restrictions in the description', () => {
  const birthday = candidate('My birthday is on 12 November and I will celebrate with family.');
  const dietary = candidate("I am allergic to peanuts and I cannot eat food cooked with them.");
  assert.ok(birthday.some(item => item.title === 'Birthday or anniversary' && item.description.includes('12 November')));
  assert.ok(dietary.some(item => item.title === 'Dietary or sensitivity detail' && item.description.includes('peanuts')));
});

test('ordinary small talk does not become a memory suggestion', () => {
  assert.deepEqual(candidate('That sounds good, thank you!'), []);
});
