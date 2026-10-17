import test from 'node:test';
import assert from 'node:assert/strict';
import {
  escapeMarketplaceRegex,
  matchesMarketplaceLocation,
  normalizeMarketplaceFilters,
} from './business-marketplace.js';

test('marketplace filters normalize text and bound pagination', () => {
  assert.deepEqual(normalizeMarketplaceFilters({
    q: '  office   chair ', category: ' Furniture ', country: 'ke',
    location: ' Nairobi ', page: '2', pageSize: '500',
  }), {
    q: 'office chair', category: 'Furniture', country: 'KE',
    location: 'Nairobi', page: 2, pageSize: 50,
  });
  assert.equal(normalizeMarketplaceFilters({page: '-1', pageSize: '0'}).page, 1);
  assert.equal(normalizeMarketplaceFilters({page: '-1', pageSize: '0'}).pageSize, 20);
  assert.equal(normalizeMarketplaceFilters({q: '  @Prime-Cafe '}).q, 'Prime-Cafe');
});

test('marketplace regex escapes user-supplied operators', () => {
  const literal = new RegExp(escapeMarketplaceRegex('chair (15)+'), 'i');
  assert.equal(literal.test('office chair (15)+'), true);
  assert.equal(literal.test('office chair 15555'), false);
});

test('marketplace location matching checks country and branch addresses only', () => {
  const business = {country: 'KE', branches: [{name: 'Westlands', address: 'Nairobi, Kenya'}]};
  assert.equal(matchesMarketplaceLocation(business, 'Nairobi'), true);
  assert.equal(matchesMarketplaceLocation(business, 'KE'), true);
  assert.equal(matchesMarketplaceLocation(business, 'Mombasa'), false);
  assert.equal(matchesMarketplaceLocation(business, ''), true);
});
