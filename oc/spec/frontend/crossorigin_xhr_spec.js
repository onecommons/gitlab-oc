import fs from 'fs';
import path from 'path';
import { XHR_JAIL_URL } from 'oc_vue_shared/storage-keys';

describe('cross-origin XHR relay', () => {
  // Derived from the constant oc-pages actually requests, so moving the file
  // without moving the URL -- or the reverse -- fails here rather than as a
  // 404 in a browser.
  const relayPath = path.join(process.cwd(), 'public', XHR_JAIL_URL);

  const dispatchRelayRequest = (detail) =>
    new Promise((resolve) => {
      document.addEventListener(detail.eventId, (event) => resolve(event.detail), { once: true });
      window.dispatchEvent(new CustomEvent('xhr', { detail }));
    });

  beforeEach(() => {
    const relayHtml = fs.readFileSync(relayPath, 'utf8');
    const script = relayHtml.match(/<script>([\s\S]*?)<\/script>/)[1];

    window.eval(script);
  });

  it('relays a GET JSON response to the parent document with the original event ID', async () => {
    const payload = { deployment: 'ready' };
    global.fetch = jest.fn().mockResolvedValue({
      status: 200,
      headers: { get: () => 'application/json; charset=utf-8' },
      json: () => Promise.resolve(payload),
    });

    const result = await dispatchRelayRequest({
      eventId: 'relay-get-result',
      method: 'GET',
      url: 'https://api.example.test/deployments',
      headers: { Authorization: 'Bearer token' },
    });

    expect(global.fetch).toHaveBeenCalledWith(
      'https://api.example.test/deployments',
      expect.objectContaining({ method: 'GET' }),
    );
    expect(result).toEqual({ status: 200, payload });
  });

  it('relays a POST text response and preserves the request body', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      status: 201,
      headers: { get: () => 'text/plain' },
      text: () => Promise.resolve('created'),
    });

    const result = await dispatchRelayRequest({
      eventId: 'relay-post-result',
      method: 'POST',
      url: 'https://api.example.test/deployments',
      body: '{"name":"demo"}',
      headers: { 'Content-Type': 'application/json' },
    });

    expect(global.fetch).toHaveBeenCalledWith(
      'https://api.example.test/deployments',
      expect.objectContaining({ method: 'POST', body: '{"name":"demo"}' }),
    );
    expect(result).toEqual({ status: 201, payload: 'created' });
  });

  it('reports a failed request to the parent document', async () => {
    const error = new Error('network unavailable');
    jest.spyOn(console, 'error').mockImplementation(() => {});
    global.fetch = jest.fn().mockRejectedValue(error);

    const result = await dispatchRelayRequest({
      eventId: 'relay-error-result',
      method: 'GET',
      url: 'https://api.example.test/deployments',
      headers: {},
    });

    expect(result).toEqual({ status: -1, payload: { error: 'network unavailable' } });
  });
});
