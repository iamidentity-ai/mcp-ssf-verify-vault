// Tests for the in-memory MFA deny counter.
//
// Per cookbook design (brainstorm decision 3): no time window. The counter
// accumulates indefinitely between explicit clearDeny() calls (which fire on
// any successful tool dispatch).

import { beforeEach, describe, expect, it } from 'vitest';
import {
  __resetForTests,
  clearDeny,
  getDenyCount,
  recordDeny,
} from './deny-counter.js';

beforeEach(() => {
  __resetForTests();
});

describe('recordDeny', () => {
  it('increments per call and flags thresholdReached on the 3rd call (inclusive)', () => {
    expect(recordDeny('A')).toEqual({ count: 1, thresholdReached: false, threshold: 3 });
    expect(recordDeny('A')).toEqual({ count: 2, thresholdReached: false, threshold: 3 });
    expect(recordDeny('A')).toEqual({ count: 3, thresholdReached: true, threshold: 3 });
  });

  it('clearDeny resets the counter — getDenyCount goes to 0 and next recordDeny returns count=1', () => {
    recordDeny('A');
    recordDeny('A');
    clearDeny('A');
    expect(getDenyCount('A')).toBe(0);
    expect(recordDeny('A')).toEqual({ count: 1, thresholdReached: false, threshold: 3 });
  });

  it('tracks different users independently', () => {
    recordDeny('A');
    recordDeny('A');
    const bResult = recordDeny('B');
    expect(bResult).toEqual({ count: 1, thresholdReached: false, threshold: 3 });
    expect(getDenyCount('A')).toBe(2);
    expect(getDenyCount('B')).toBe(1);
  });

  it('has no time window — accumulates across arbitrary durations between calls', async () => {
    // We can't realistically wait minutes in a test, but we can assert that
    // there's no clock-based reset by simulating a long pause and verifying
    // the counter keeps incrementing. The implementation must not consult
    // Date.now() for window expiry.
    recordDeny('A');
    await new Promise((r) => setTimeout(r, 50));
    const second = recordDeny('A');
    expect(second.count).toBe(2);
    await new Promise((r) => setTimeout(r, 50));
    const third = recordDeny('A');
    expect(third.count).toBe(3);
    expect(third.thresholdReached).toBe(true);
  });
});
