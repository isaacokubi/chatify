import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeReview} from './business-reviews.js';
test('verified review requires a valid rating and a substantive comment',()=>{
 assert.deepEqual(normalizeReview({rating:5,title:'Great',comment:'Fast and helpful service'}),{rating:5,title:'Great',comment:'Fast and helpful service'});
 assert.throws(()=>normalizeReview({rating:6,comment:'Very good service'}));
 assert.throws(()=>normalizeReview({rating:3,comment:'ok'}));
});
