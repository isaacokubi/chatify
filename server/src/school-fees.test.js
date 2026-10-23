import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeFeeStructureInput, calculateSchoolFeeBalance} from './school-fees.js';

test('normalizes a class-specific fee structure and sums multiple items exactly', () => {
  assert.deepEqual(normalizeFeeStructureInput({
    className: ' Grade 4 ', academicYear: '2027', term: 'Term 1',
    items: [
      {description: 'Tuition', amount: 12000},
      {code: 'TRANSPORT', description: 'Transport', amount: 2500},
    ],
  }), {
    className: 'Grade 4', academicYear: '2027', term: 'Term 1',
    items: [
      {code: 'TUITION', description: 'Tuition', amount: 12000},
      {code: 'TRANSPORT', description: 'Transport', amount: 2500},
    ],
    totalAmount: 14500,
  });
});

test('rejects malformed, duplicate, negative and unsafe fee amounts', () => {
  for (const input of [
    {className:'', academicYear:'2027', term:'Term 1', items:[{description:'Tuition',amount:1}]},
    {className:'Grade 1', academicYear:'2027', term:'Term 1', items:[]},
    {className:'Grade 1', academicYear:'2027', term:'Term 1', items:[{description:'Tuition',amount:-1}]},
    {className:'Grade 1', academicYear:'2027', term:'Term 1', items:[{description:'Tuition',amount:1.5}]},
    {className:'Grade 1', academicYear:'2027', term:'Term 1', items:[{code:'TUITION',description:'Tuition',amount:1},{code:'TUITION',description:'Other',amount:2}]},
  ]) assert.equal(normalizeFeeStructureInput(input), null);
});

test('only confirmed payments reduce an issued fee charge', () => {
  assert.deepEqual(calculateSchoolFeeBalance({
    chargeAmount: 14500,
    payments: [
      {status:'CONFIRMED', amount:4000},
      {status:'PENDING_STK', amount:3000},
      {status:'FAILED', amount:2000},
      {status:'CANCELLED', amount:1000},
      {status:'REVERSED', amount:500},
    ],
  }), {chargeAmount:14500, credits:0, confirmedPaid:4000, balance:10500, overpayment:0, status:'PARTIALLY_PAID'});
});

test('fully paid balances, credits and overpayments are explicit', () => {
  assert.equal(calculateSchoolFeeBalance({chargeAmount:1000,payments:[{status:'CONFIRMED',amount:1000}]}).status, 'PAID');
  assert.deepEqual(calculateSchoolFeeBalance({chargeAmount:0}), {chargeAmount:0,credits:0,confirmedPaid:0,balance:0,overpayment:0,status:'PAID'});
  assert.deepEqual(calculateSchoolFeeBalance({chargeAmount:1000,credits:200,payments:[{status:'CONFIRMED',amount:1000}]}), {chargeAmount:1000,credits:200,confirmedPaid:1000,balance:0,overpayment:200,status:'PAID'});
});

test('unconfigured classes are not represented as zero-fee or paid', () => {
  assert.deepEqual(calculateSchoolFeeBalance({configured:false}), {
    chargeAmount:null, credits:0, confirmedPaid:0, balance:null, overpayment:0, status:'NOT_CONFIGURED',
  });
  assert.throws(() => calculateSchoolFeeBalance({configured:false, chargeAmount:-1}), /whole-KSh/);
});

test('balance rejects non-integer monetary amounts instead of silently rounding', () => {
  assert.throws(() => calculateSchoolFeeBalance({chargeAmount:10.5}), /whole-KSh/);
  assert.throws(() => calculateSchoolFeeBalance({chargeAmount:10,payments:[{status:'CONFIRMED',amount:2.5}]}), /whole-KSh/);
});
