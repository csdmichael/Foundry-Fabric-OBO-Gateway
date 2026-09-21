import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { BrokerConfig } from '../src/config.js';
import { actualCostRequest, buildActualCostSnapshot, createActualCostQuery, type CostManagementPort } from '../src/cost-management.js';

const scope = '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourceGroups/costops';
const modelId = `${scope}/providers/Microsoft.CognitiveServices/accounts/foundry-costops`;
const apimId = `${scope}/providers/Microsoft.ApiManagement/service/apim-costops`;
const config = {
  managedIdentityClientId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  tokenomicsCurrency: 'USD',
  actualCostEnabled: true,
  actualCostScope: scope,
  actualCostQueryApiVersion: '2023-11-01',
  actualCostBillingLagHours: 24,
  actualCostTrackedResources: [
    { category: 'model', resourceId: modelId, shared: false },
    { category: 'gateway', resourceId: apimId, shared: true },
  ],
} as BrokerConfig;

test('classifies Azure ActualCost rows without relabeling estimates', () => {
  const snapshot = buildActualCostSnapshot([{
    properties: {
      columns: [
        { name: 'Cost', type: 'Number' },
        { name: 'UsageDate', type: 'Number' },
        { name: 'ResourceId', type: 'String' },
        { name: 'ServiceName', type: 'String' },
        { name: 'Currency', type: 'String' },
      ],
      rows: [
        [12.5, 20260915, modelId.toUpperCase(), 'Azure AI services', 'USD'],
        [3, 20260916, apimId, 'API Management', 'USD'],
        [4.5, 20260916, `${scope}/providers/Microsoft.Fabric/capacities/shared`, 'Microsoft Fabric', 'USD'],
      ],
    },
  }], config, new Date('2026-09-17T00:00:00Z'));
  assert.equal(snapshot.status, 'available');
  assert.equal(snapshot.scopeCost, 20);
  assert.equal(snapshot.trackedCost, 15.5);
  assert.equal(snapshot.dedicatedModelCost, 12.5);
  assert.equal(snapshot.sharedPlatformCost, 3);
  assert.equal(snapshot.untrackedCost, 4.5);
  assert.equal(snapshot.billedThrough, '2026-09-16');
  assert.deepEqual(snapshot.trend.at(-1), { date: '2026-09-16', scopeCost: 7.5, trackedCost: 3, dedicatedModelCost: 0 });
});

test('uses ActualCost with a bounded custom daily query', () => {
  const request = actualCostRequest(7, new Date('2026-09-17T00:00:00Z'));
  assert.equal(request.type, 'ActualCost');
  assert.equal(request.timeframe, 'Custom');
  assert.deepEqual((request.dataset as { grouping: unknown[] }).grouping, [
    { type: 'Dimension', name: 'ResourceId' },
    { type: 'Dimension', name: 'ServiceName' },
  ]);
});

test('reports unavailable billing separately from telemetry', async () => {
  const port: CostManagementPort = { query: async () => { throw new Error('429'); } };
  const snapshot = await createActualCostQuery(config, port)(30);
  assert.equal(snapshot.status, 'unavailable');
  assert.equal(snapshot.dedicatedModelCost, null);
});