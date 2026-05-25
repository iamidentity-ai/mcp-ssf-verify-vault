// Tests for the CAEP session-revoked Antenna emitter.
//
// We do NOT stub globalThis.fetch — vitest's parallel test runners make global
// fetch mocking flaky. Instead the module exports __setFetchForTests() so each
// test injects its own fake fetch.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  __setFetchForTests,
  emitSessionRevoked,
  SESSION_REVOKED_URI,
} from './antenna-emitter.js';

type FetchFn = typeof fetch;

afterEach(() => {
  __setFetchForTests(undefined);
});

describe('emitSessionRevoked', () => {
  it('POSTs JSON to a URL matching /sources/<id>/events', async () => {
    const fakeFetch = vi.fn<FetchFn>(async () =>
      new Response('', { status: 202 }),
    );
    __setFetchForTests(fakeFetch);

    await emitSessionRevoked({
      verifyUserId: 'abc123',
      email: 'clinician@example.com',
      reason: 'unit test',
    });

    expect(fakeFetch).toHaveBeenCalledOnce();
    const [url, init] = fakeFetch.mock.calls[0]!;
    expect(String(url)).toMatch(/\/sources\/[^/]+\/events$/);
    expect(init?.method).toBe('POST');
    const headers = new Headers(init?.headers);
    expect(headers.get('content-type')).toBe('application/json');
  });

  it('builds sub_id with format=email + email + verifyUserId when email supplied', async () => {
    let captured: unknown;
    const fakeFetch = vi.fn<FetchFn>(async (_url, init) => {
      captured = JSON.parse(String(init!.body));
      return new Response('', { status: 202 });
    });
    __setFetchForTests(fakeFetch);

    await emitSessionRevoked({
      verifyUserId: 'abc123',
      email: 'clinician@example.com',
      reason: 'unit test reason',
    });

    const body = captured as Record<string, any>;
    expect(body.sub_id).toEqual({
      format: 'email',
      verifyUserId: 'abc123',
      email: 'clinician@example.com',
    });
  });

  it('event payload uses initiatingEntity=policy, reasonAdmin/User wrappers, and event_timestamp in SECONDS', async () => {
    let captured: any;
    const fakeFetch = vi.fn<FetchFn>(async (_url, init) => {
      captured = JSON.parse(String(init!.body));
      return new Response('', { status: 202 });
    });
    __setFetchForTests(fakeFetch);

    await emitSessionRevoked({
      verifyUserId: 'u1',
      email: 'a@b.com',
      reason: 'three strikes',
    });

    const evt = captured.events[SESSION_REVOKED_URI];
    expect(evt.initiatingEntity).toBe('policy');
    expect(evt.reasonAdmin).toEqual({ en: 'three strikes' });
    expect(evt.reasonUser).toEqual({ en: 'three strikes' });
    expect(typeof evt.event_timestamp).toBe('number');
    // Seconds, not milliseconds — canonical SSF/CAEP gotcha. A current-day ms
    // timestamp would be ~1.78e12; we want < 2e9 (i.e. seconds).
    expect(evt.event_timestamp).toBeLessThan(2_000_000_000);
  });

  it('omits sub_id.email and uses format=opaque when email is undefined', async () => {
    let captured: any;
    const fakeFetch = vi.fn<FetchFn>(async (_url, init) => {
      captured = JSON.parse(String(init!.body));
      return new Response('', { status: 202 });
    });
    __setFetchForTests(fakeFetch);

    await emitSessionRevoked({ verifyUserId: 'abc123', reason: 'opaque case' });

    expect(captured.sub_id.format).toBe('opaque');
    expect(captured.sub_id.email).toBeUndefined();
    expect(captured.sub_id.verifyUserId).toBe('abc123');
  });

  it('returns {ok:false, status, body} when fetch returns non-2xx', async () => {
    const fakeFetch = vi.fn<FetchFn>(async () =>
      new Response('source not found', { status: 404 }),
    );
    __setFetchForTests(fakeFetch);

    const result = await emitSessionRevoked({
      verifyUserId: 'abc123',
      reason: 'check non-2xx',
    });

    expect(result.ok).toBe(false);
    expect(result.status).toBe(404);
    expect(result.body).toBe('source not found');
  });

  it('returns {ok:false, status:0, body:<msg>} when fetch throws', async () => {
    const fakeFetch = vi.fn<FetchFn>(async () => {
      throw new Error('self-signed certificate');
    });
    __setFetchForTests(fakeFetch);

    const result = await emitSessionRevoked({
      verifyUserId: 'abc123',
      reason: 'check throw',
    });

    expect(result.ok).toBe(false);
    expect(result.status).toBe(0);
    expect(result.body).toMatch(/self-signed/);
  });
});
