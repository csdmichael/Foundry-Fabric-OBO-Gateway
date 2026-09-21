import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { LogsTable } from '@azure/monitor-query-logs';
import type { BrokerConfig } from '../src/config.js';
import { BrokerError } from '../src/errors.js';
import { buildTokenomicsDashboard, reconcileActualCost, rowsFromTables, tokenomicsDashboardQuery, tokenomicsWindow } from '../src/tokenomics.js';

const config = {
  tokenomicsCurrency: 'USD',
  tokenomicsRateCard: [{
    model: 'gpt-4o-mini',
    effectiveFrom: '2025-01-01T00:00:00Z',
    marketInputUsdPerMillion: 1,
    marketOutputUsdPerMillion: 4,
    negotiatedInputUsdPerMillion: 0.8,
    negotiatedOutputUsdPerMillion: 3.2,
  }],
} as BrokerConfig;

test('maps Azure Monitor columns and prices complete model usage', () => {
  const table = {
    name: 'PrimaryResult',
    columnDescriptors: [
      { name: 'Section', type: 'string' },
      { name: 'Requests', type: 'long' },
      { name: 'Successes', type: 'long' },
      { name: 'Errors', type: 'long' },
      { name: 'TokenizedRequests', type: 'long' },
      { name: 'PromptTokens', type: 'long' },
      { name: 'CompletionTokens', type: 'long' },
      { name: 'TotalTokens', type: 'long' },
      { name: 'P95LatencyMs', type: 'real' },
      { name: 'Model', type: 'string' },
      { name: 'TimeBucket', type: 'string' },
      { name: 'ApplicationId', type: 'string' },
    ],
    rows: [
      ['summary', 10, 9, 1, 8, 1_000_000, 250_000, 1_250_000, 420, '', '', ''],
      ['model', 8, 0, 0, 8, 1_000_000, 250_000, 1_250_000, 0, 'gpt-4o-mini', '2026-09-01', ''],
      ['allocation', 10, 9, 1, 8, 1_000_000, 250_000, 1_250_000, 420, 'gpt-4o-mini', '2026-09-01', 'client-a'],
    ],
  } as LogsTable;
  const dashboard = buildTokenomicsDashboard(rowsFromTables([table]), config, 30, 'complete');
  assert.equal(dashboard.summary.marketCost, 2);
  assert.equal(dashboard.summary.negotiatedCost, 1.6);
  assert.equal(dashboard.summary.savings, 0.4);
  assert.equal(dashboard.summary.tokenCoveragePct, 80);
  assert.equal(dashboard.dataQuality.pricing, 'negotiated');
  assert.equal(dashboard.dataQuality.allocation, 'attributed');
});

test('rejects arbitrary dashboard windows', () => {
  assert.equal(tokenomicsWindow(null), 30);
  assert.equal(tokenomicsWindow('7'), 7);
  assert.throws(() => tokenomicsWindow('365'), (error: unknown) => error instanceof BrokerError && error.code === 'invalid_window');
});

test('correlates token rows only to configured gateway requests', () => {
  const query = tokenomicsDashboardQuery({
    tokenomicsApiIds: ['fabric-lakehouse-obo', 'fabric-data-agent-obo'],
    tokenomicsApiAttribution: { 'fabric-data-agent-obo': 'fabric-data-agent-costops' },
    tokenomicsProjectId: 'parts',
    tokenomicsTeamId: 'planning',
    tokenomicsCostCenter: 'cc-205',
  } as unknown as BrokerConfig);
  assert.match(query, /let ApiIds = dynamic\(\["fabric-lakehouse-obo","fabric-data-agent-obo"\]\)/);
  assert.match(query, /let ApiAttribution = dynamic\(\{"fabric-data-agent-obo":"fabric-data-agent-costops"\}\)/);
  assert.match(query, /Tokens\s+\| join kind=inner \(Requests/);
  assert.doesNotMatch(query, /Tokens\s+\| join kind=leftouter \(Requests/);
  assert.match(query, /by TimeBucket=format_datetime\(bin\(TimeGenerated, 1d\), 'yyyy-MM-dd'\), Model, IsStream/);
  assert.match(query, /Section='allocationDaily'/);
});

test('allocates billed model cost by observed token share', () => {
  const dashboard = buildTokenomicsDashboard([
    { Section: 'summary', Requests: 2, TotalTokens: 100 },
    { Section: 'allocation', ApplicationId: 'agent-a', Requests: 1, TotalTokens: 75 },
    { Section: 'allocation', ApplicationId: 'agent-b', Requests: 1, TotalTokens: 25 },
    { Section: 'allocationDaily', TimeBucket: '2026-09-16', ApplicationId: 'agent-a', TotalTokens: 75 },
    { Section: 'allocationDaily', TimeBucket: '2026-09-16', ApplicationId: 'agent-b', TotalTokens: 25 },
    { Section: 'trend', TimeBucket: '2026-09-16', TotalTokens: 100 },
  ], { tokenomicsCurrency: 'USD', tokenomicsRateCard: [] } as unknown as BrokerConfig, 30, 'complete');
  const reconciled = reconcileActualCost(dashboard, {
    source: 'AzureCostManagement', queryType: 'ActualCost', status: 'available', scope: '/scope', currency: 'USD',
    generatedAt: '2026-09-17T00:00:00Z', billedThrough: '2026-09-16', expectedBillingLagHours: 24,
    scopeCost: 15, trackedCost: 12, dedicatedModelCost: 10, sharedPlatformCost: 2, untrackedCost: 3,
    byService: [], byResource: [], trend: [{ date: '2026-09-16', scopeCost: 15, trackedCost: 12, dedicatedModelCost: 10 }],
  });
  assert.deepEqual(reconciled.allocations.map(row => row.ActualCost), [7.5, 2.5]);
  assert.equal(reconciled.actualCost?.allocationMethod, 'observed-token-share');
  assert.equal(reconciled.dataQuality.billing, 'actual');
});

test('does not allocate billed cost using tokens observed after the billed-through date', () => {
  const dashboard = buildTokenomicsDashboard([
    { Section: 'summary', Requests: 2, TotalTokens: 200 },
    { Section: 'allocation', ApplicationId: 'agent-a', Model: 'gpt', Requests: 1, TotalTokens: 100 },
    { Section: 'allocation', ApplicationId: 'agent-b', Model: 'gpt', Requests: 1, TotalTokens: 100 },
    { Section: 'allocationDaily', TimeBucket: '2026-09-16', ApplicationId: 'agent-a', Model: 'gpt', TotalTokens: 100 },
    { Section: 'allocationDaily', TimeBucket: '2026-09-17', ApplicationId: 'agent-b', Model: 'gpt', TotalTokens: 100 },
    { Section: 'model', Model: 'gpt', IsStream: false, TotalTokens: 200 },
    { Section: 'trend', TimeBucket: '2026-09-16', Model: 'gpt', IsStream: false, TotalTokens: 100 },
    { Section: 'trend', TimeBucket: '2026-09-17', Model: 'gpt', IsStream: false, TotalTokens: 100 },
  ], { tokenomicsCurrency: 'USD', tokenomicsRateCard: [] } as unknown as BrokerConfig, 30, 'complete');
  const reconciled = reconcileActualCost(dashboard, {
    source: 'AzureCostManagement', queryType: 'ActualCost', status: 'available', scope: '/scope', currency: 'USD',
    generatedAt: '2026-09-17T12:00:00Z', billedThrough: '2026-09-16', expectedBillingLagHours: 24,
    scopeCost: 10, trackedCost: 10, dedicatedModelCost: 10, sharedPlatformCost: 0, untrackedCost: 0,
    byService: [], byResource: [], trend: [{ date: '2026-09-16', scopeCost: 10, trackedCost: 10, dedicatedModelCost: 10 }],
  });
  assert.deepEqual(reconciled.allocations.map(row => row.ActualCost), [10, 0]);
  assert.deepEqual(reconciled.models.map(row => row.ActualCost), [10]);
  assert.deepEqual(reconciled.trend.map(row => row.ActualCost), [10, 0]);
  assert.equal(reconciled.actualCost?.allocatedModelCost, 10);
  assert.equal('billingAllocations' in reconciled, false);
});