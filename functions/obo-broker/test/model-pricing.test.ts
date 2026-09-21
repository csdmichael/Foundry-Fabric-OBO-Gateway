import assert from 'node:assert/strict';
import { test } from 'node:test';
import { normalizeAzureRetailPrices, parseProviderPricingMarkdown } from '../src/model-pricing.js';

const capturedAt = new Date('2026-09-17T12:00:00Z');

test('parses OpenAI model prices and ignores nonmonetary model tables', () => {
  const markdown = `# Pricing

Standard

### Standard pricing data
| Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context output |
| --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-5.6-sol | $4.00 | $0.40 | $5.00 | $20.00 | $8.00 | $0.80 | $30.00 |

### Tool tokens
| Model | Tool choice | Tool use system prompt token count |
| --- | --- | --- |
| gpt-5.6-sol | auto | 286 tokens |
`;
  const records = parseProviderPricingMarkdown('openai', markdown, 'https://example.test/openai.md', capturedAt);
  assert.equal(records.length, 1);
  assert.deepEqual(records[0], {
    ...records[0],
    snapshotDate: '2026-09-17', provider: 'openai', modelFamily: 'GPT-5', model: 'gpt-5.6-sol',
    offering: 'Standard', unitOfMeasure: '1M tokens', inputPrice: 4, cachedInputPrice: 0.4,
    cacheWritePrice: 5, outputPrice: 20, longContextInputPrice: 8,
    longContextCachedInputPrice: 0.8, longContextOutputPrice: 30,
  });
});

test('parses Anthropic cache and output prices', () => {
  const markdown = `## Model pricing
| Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |
| --- | --- | --- | --- | --- | --- |
| Claude Sonnet 5 | $2 / MTok | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok |
`;
  const [record] = parseProviderPricingMarkdown('anthropic', markdown, 'https://example.test/anthropic.md', capturedAt);
  assert.equal(record.modelFamily, 'Claude Sonnet');
  assert.equal(record.inputPrice, 2);
  assert.equal(record.cachedInputPrice, 0.2);
  assert.equal(record.cacheWritePrice, 2.5);
  assert.equal(record.cacheWriteOneHourPrice, 4);
  assert.equal(record.outputPrice, 10);
});

test('normalizes Azure regional retail meters without losing meter identity', () => {
  const records = normalizeAzureRetailPrices([{
    currencyCode: 'USD', retailPrice: 4.4, armRegionName: 'westus',
    meterName: 'gpt-5.6-sol Inp Gl 1M Tokens', productName: 'Azure OpenAI GPT5',
    skuName: 'gpt-5.6-sol Inp Gl', unitOfMeasure: '1M', type: 'Consumption',
    meterId: 'meter-1', productId: 'product-1', skuId: 'sku-1', effectiveStartDate: '2026-07-09T00:00:00Z',
  }], 'https://prices.azure.com/api/retail/prices', capturedAt);
  assert.equal(records.length, 1);
  assert.equal(records[0].provider, 'azure');
  assert.equal(records[0].modelFamily, 'GPT5');
  assert.equal(records[0].region, 'westus');
  assert.equal(records[0].retailPrice, 4.4);
  assert.equal(records[0].sourceFields.meterId, 'meter-1');
});