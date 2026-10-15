import test from 'node:test';
import assert from 'node:assert/strict';
import {parseCsv} from './business-customer-import.js';
test('CSV parser handles quoted commas, escaped quotes and CRLF',()=>{
 const rows=parseCsv('name,email,company,notes\r\n"Jane Doe",jane@example.com,"Acme, Inc.","said ""hello"""\r\n');
 assert.equal(rows.length,1);assert.equal(rows[0].record.company,'Acme, Inc.');assert.equal(rows[0].record.notes,'said "hello"');
});
test('CSV rejects missing required identifiers, bad email and unsupported headers',()=>{
 assert.match(parseCsv('name,email\nJane,not-an-email')[0].error,/Invalid email/);
 assert.match(parseCsv('name,email\nJane,')[0].error,/email address or phone/);
 assert.throws(()=>parseCsv('name,password\nJane,secret'),/Unsupported CSV header/);
});
test('CSV rejects malformed quotes and row counts beyond the limit',()=>{
 assert.throws(()=>parseCsv('name,email\n"Jane,jane@example.com'),/unclosed/);
 assert.throws(()=>parseCsv('name,email\n'+Array.from({length:501},(_,i)=>'Name '+i+',a'+i+'@example.com').join('\n')),/500/);
});
