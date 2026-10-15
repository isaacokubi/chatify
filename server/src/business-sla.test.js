import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeSlaTargets,calculateCaseSla,nextEscalationPriority} from './business-sla.js';
test('SLA targets accept bounded whole minutes and reject invalid values',()=>{
 assert.equal(normalizeSlaTargets({normal:60}).normal,60);
 assert.throws(()=>normalizeSlaTargets({urgent:2}));
 assert.throws(()=>normalizeSlaTargets({low:1.5}));
});
test('case SLA uses explicit due date or priority target and ignores closed cases',()=>{
 const now=new Date('2026-01-01T12:00:00Z');
 const breached=calculateCaseSla({createdAt:new Date('2026-01-01T00:00:00Z'),status:'open',priority:'normal'},normalizeSlaTargets(),now);
 assert.equal(breached.breached,true);
 const closed=calculateCaseSla({createdAt:new Date('2026-01-01T00:00:00Z'),status:'closed',priority:'normal'},normalizeSlaTargets(),now);
 assert.equal(closed.breached,false);
});
test('overdue cases escalate predictably',()=>{
 assert.equal(nextEscalationPriority('normal',10,60),'high');
 assert.equal(nextEscalationPriority('high',121,60),'urgent');
 assert.equal(nextEscalationPriority('urgent',30,60),'urgent');
 assert.equal(nextEscalationPriority('normal',0,60),'normal');
});
