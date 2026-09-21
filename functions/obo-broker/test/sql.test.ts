import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { BrokerConfig } from '../src/config.js';
import { BrokerError } from '../src/errors.js';
import { assertReadOnlyStatement, formatKnowledgeResults, knowledgeSearchTerms, tableListStatement } from '../src/sql.js';

test('accepts one read-only T-SQL select including a CTE', () => {
  assert.equal(assertReadOnlyStatement('SELECT TOP 10 * FROM scm.parts;', 1000), 'SELECT TOP 10 * FROM scm.parts');
  assert.match(assertReadOnlyStatement('WITH ranked AS (SELECT id FROM scm.parts) SELECT * FROM ranked', 1000), /^WITH/);
  assert.match(tableListStatement(), /^SELECT/);
});

test('rejects writes, multiple statements, open rowsets and oversized input', () => {
  const invalid = [
    'DELETE FROM scm.parts',
    'SELECT 1; SELECT 2',
    "SELECT * INTO copied FROM scm.parts",
    "SELECT * FROM OPENROWSET('provider', 'secret', 'query')",
    '',
  ];
  for (const statement of invalid) {
    assert.throws(() => assertReadOnlyStatement(statement, 1000), (error: unknown) => error instanceof BrokerError && error.status === 400);
  }
  assert.throws(() => assertReadOnlyStatement('SELECT 1', 3));
});

test('builds bounded citation-ready knowledge results without treating user input as SQL', () => {
  assert.deepEqual(knowledgeSearchTerms('List open shortages for supplier ACME ACME'), ['supplier', 'acme']);
  assert.deepEqual(knowledgeSearchTerms("'; DROP TABLE secrets; --"), ['drop', 'table', 'secrets']);
  const result = formatKnowledgeResults({ workspaceId: 'workspace-id' } as BrokerConfig, 'open shortages', [{
    shortage_id: 'S-1', matnr: 'P-100', material_text: 'Controller', plant: 'US01', supplier_name: 'Contoso',
    severity_band: 'Critical', qty_short: 42, need_date: new Date('2026-09-20T00:00:00Z'),
    expected_delivery_date: null, status: 'OPEN',
  }]);
  assert.equal(result.results.length, 1);
  assert.match(result.results[0].snippet, /shortage quantity 42/);
  assert.equal(result.results[0].url, 'https://app.fabric.microsoft.com/groups/workspace-id/list');
});