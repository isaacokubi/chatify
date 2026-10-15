import test from 'node:test';
import assert from 'node:assert/strict';
import {buildCustomerStatement} from './business-statements.js';

test('customer statements compute balances and group totals by currency', () => {
  const statement = buildCustomerStatement([
    {_id: 'a', number: 'INV-1', type: 'invoice', status: 'part_paid', currency: 'KES', total: 1000, paidAmount: 300, createdAt: '2026-01-01T00:00:00Z'},
    {_id: 'b', number: 'INV-2', type: 'invoice', status: 'paid', currency: 'KES', total: 200, paidAmount: 500, createdAt: '2026-01-02T00:00:00Z'},
    {_id: 'c', number: 'INV-3', type: 'invoice', status: 'sent', currency: 'USD', total: 20, paidAmount: 0, createdAt: '2026-01-03T00:00:00Z'},
  ], {now: new Date('2026-01-04T00:00:00Z')});
  assert.equal(statement.count, 3);
  assert.equal(statement.documents[0].balanceDue, 700);
  assert.equal(statement.documents[1].paidAmount, 200);
  assert.deepEqual(statement.totals.KES, {billed: 1200, paid: 500, balanceDue: 700});
  assert.deepEqual(statement.totals.USD, {billed: 20, paid: 0, balanceDue: 20});
});

test('customer statement filters by date and rejects invalid ranges', () => {
  const docs = [{number: 'A', total: 10, paidAmount: 0, createdAt: '2026-01-02T00:00:00Z'}];
  assert.equal(buildCustomerStatement(docs, {from: '2026-01-03', now: new Date('2026-01-04')}).count, 0);
  assert.throws(() => buildCustomerStatement(docs, {from: 'bad-date'}), /invalid statement start date/i);
  assert.throws(() => buildCustomerStatement(docs, {from: '2026-02-01', to: '2026-01-01'}), /must not be after/i);
});
