import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { BrokerConfig } from '../src/config.js';
import { createDataAgentClient } from '../src/mcp.js';

const config = {
  workspaceId: '88888888-8888-4888-8888-888888888888',
  dataAgentId: '99999999-9999-4999-8999-999999999999',
  sqlRequestTimeoutMs: 1000,
} as BrokerConfig;

test('initializes MCP, discovers its tool and calls the discovered question argument', async () => {
  const methods: string[] = [];
  const request: typeof fetch = async (_url, options) => {
    const body = JSON.parse(String(options?.body)) as { method: string; params?: Record<string, unknown> };
    methods.push(body.method);
    const headers = new Headers({ 'Content-Type': 'application/json' });
    if (body.method === 'initialize') headers.set('Mcp-Session-Id', 'session-1');
    if (body.method === 'notifications/initialized') return new Response('', { status: 202, headers });
    if (body.method === 'tools/list') return Response.json({ jsonrpc: '2.0', id: 2, result: { tools: [{ name: 'ask_data_agent', inputSchema: { properties: { question: { type: 'string' } } } }] } }, { headers });
    if (body.method === 'tools/call') {
      assert.deepEqual(body.params, { name: 'ask_data_agent', arguments: { question: 'Which parts are short?' } });
      return Response.json({ jsonrpc: '2.0', id: 3, result: { content: [{ type: 'text', text: 'Part A' }] } }, { headers });
    }
    return Response.json({ jsonrpc: '2.0', id: 1, result: { protocolVersion: '2025-06-18' } }, { headers });
  };
  const result = await createDataAgentClient(config, request)('fabric-token', 'Which parts are short?');
  assert.deepEqual(methods, ['initialize', 'notifications/initialized', 'tools/list', 'tools/call']);
  assert.deepEqual(result.content, [{ type: 'text', text: 'Part A' }]);
});