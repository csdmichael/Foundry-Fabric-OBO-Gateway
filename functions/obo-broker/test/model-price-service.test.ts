import assert from 'node:assert/strict';
import { test } from 'node:test';
import { refreshModelPrices, type ModelPriceSourcePort } from '../src/model-price-service.js';
import type { ModelPriceStorePort } from '../src/model-price-store.js';
import type { ModelPriceRecord } from '../src/model-pricing.js';

const settings = {
  openAiUrl: 'https://developers.openai.com/api/docs/pricing.md',
  anthropicUrl: 'https://platform.claude.com/docs/en/about-claude/pricing.md',
  azureRetailUrl: "https://prices.azure.com/api/retail/prices?currencyCode='USD'",
};

const markdown = (model: string) => `## Model pricing
| Model | Input | Output |
| --- | --- | --- |
| ${model} | $1 | $5 |
`;

test('publishes one complete daily snapshot across all providers', async () => {
  let saved: { date: string; records: ModelPriceRecord[] } | undefined;
  const store: ModelPriceStorePort = {
    async replaceSnapshot(date, _capturedAt, records) { saved = { date, records }; },
    async query() { throw new Error('not used'); },
  };
  const source: ModelPriceSourcePort = {
    async fetchText(url) { return markdown(url.includes('openai') ? 'gpt-5' : 'Claude Sonnet 5'); },
    async fetchAzurePrices() {
      return [{ retailPrice: 2, skuName: 'gpt-5 Inp Gl', productName: 'Azure OpenAI GPT5', armRegionName: 'westus' }];
    },
  };
  const result = await refreshModelPrices(settings, store, source, new Date('2026-09-17T02:15:00Z'));
  assert.equal(result.totalRecords, 3);
  assert.deepEqual(result.providerCounts, { anthropic: 1, openai: 1, azure: 1 });
  assert.equal(saved?.date, '2026-09-17');
  assert.deepEqual(saved?.records.map(record => record.provider).sort(), ['anthropic', 'azure', 'openai']);
});

test('does not publish a partial snapshot when one provider is empty', async () => {
  let writes = 0;
  const store: ModelPriceStorePort = {
    async replaceSnapshot() { writes += 1; },
    async query() { throw new Error('not used'); },
  };
  const source: ModelPriceSourcePort = {
    async fetchText(url) { return url.includes('openai') ? markdown('gpt-5') : '# no table'; },
    async fetchAzurePrices() { return [{ retailPrice: 2, skuName: 'gpt-5', productName: 'Azure OpenAI GPT5' }]; },
  };
  await assert.rejects(() => refreshModelPrices(settings, store, source, new Date('2026-09-17T02:15:00Z')), /pricing_source_empty/);
  assert.equal(writes, 0);
});