import { createHash } from 'node:crypto';

export type ModelPriceProvider = 'anthropic' | 'openai' | 'azure';

export interface ModelPriceRecord {
  id: string;
  snapshotDate: string;
  capturedAt: string;
  provider: ModelPriceProvider;
  modelFamily: string;
  model: string;
  offering: string;
  modality: string | null;
  region: string | null;
  currency: string;
  unitOfMeasure: string;
  inputPrice: number | null;
  cachedInputPrice: number | null;
  cacheWritePrice: number | null;
  cacheWriteOneHourPrice: number | null;
  outputPrice: number | null;
  longContextInputPrice: number | null;
  longContextCachedInputPrice: number | null;
  longContextOutputPrice: number | null;
  retailPrice: number | null;
  skuName: string | null;
  meterName: string | null;
  priceType: string | null;
  sourceUrl: string;
  sourceEffectiveDate: string | null;
  sourceFields: Record<string, string>;
}

export interface AzureRetailPriceItem {
  currencyCode?: string;
  retailPrice?: number;
  armRegionName?: string;
  location?: string;
  effectiveStartDate?: string;
  meterId?: string;
  meterName?: string;
  productId?: string;
  skuId?: string;
  productName?: string;
  skuName?: string;
  serviceName?: string;
  unitOfMeasure?: string;
  type?: string;
}

function clean(value: string): string {
  return value
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/<[^>]+>/g, '')
    .replace(/[`*_]/g, '')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
}

function markdownCells(line: string): string[] {
  return line.trim().replace(/^\||\|$/g, '').split('|').map(clean);
}

function isSeparator(cells: string[]): boolean {
  return cells.length > 0 && cells.every(cell => /^:?-{3,}:?$/.test(cell));
}

function money(value: string | undefined): number | null {
  if (!value || value === '-') return null;
  if (/^free$/i.test(value.trim())) return 0;
  const match = value.match(/\$\s*([\d,]+(?:\.\d+)?)/);
  if (!match) return null;
  const parsed = Number(match[1].replace(/,/g, ''));
  return Number.isFinite(parsed) ? parsed : null;
}

function valueFor(row: Record<string, string>, candidates: string[]): number | null {
  for (const candidate of candidates) {
    const entry = Object.entries(row).find(([header]) => header.toLowerCase() === candidate);
    if (entry) return money(entry[1]);
  }
  return null;
}

function modelFamily(provider: ModelPriceProvider, model: string, category = ''): string {
  if (category) return clean(category);
  if (provider === 'anthropic') {
    const family = model.match(/\b(Fable|Mythos|Opus|Sonnet|Haiku)\b/i)?.[1];
    return family ? `Claude ${family[0].toUpperCase()}${family.slice(1).toLowerCase()}` : 'Claude';
  }
  const normalized = model.toLowerCase();
  if (normalized.startsWith('gpt-6')) return 'GPT-6';
  if (normalized.startsWith('gpt-5')) return 'GPT-5';
  if (normalized.startsWith('gpt-4')) return 'GPT-4';
  if (normalized.startsWith('gpt-3.5')) return 'GPT-3.5';
  if (/^o\d/.test(normalized)) return 'o-series';
  if (normalized.includes('embedding')) return 'Embeddings';
  if (normalized.includes('image')) return 'Image';
  if (normalized.includes('realtime') || normalized.includes('audio') || normalized.includes('transcribe') || normalized.includes('whisper')) return 'Audio and realtime';
  if (normalized.startsWith('sora')) return 'Video';
  return 'Other';
}

function documentId(record: Omit<ModelPriceRecord, 'id'>): string {
  const identity = [
    record.snapshotDate,
    record.provider,
    record.model,
    record.offering,
    record.modality,
    record.region,
    record.skuName,
    record.meterName,
    JSON.stringify(record.sourceFields),
  ].join('|');
  return createHash('sha256').update(identity).digest('hex');
}

function withId(record: Omit<ModelPriceRecord, 'id'>): ModelPriceRecord {
  return { id: documentId(record), ...record };
}

function unitOfMeasure(headers: string[], row: Record<string, string>): string {
  const values = Object.values(row).join(' ');
  if (/\/\s*(?:1m\s*)?characters?/i.test(values)) return '1M characters';
  if (/\/\s*minute/i.test(values) || headers.some(header => /per minute/i.test(header))) return '1 minute';
  if (/\/\s*hour/i.test(values) || headers.some(header => /per hour/i.test(header))) return '1 hour';
  if (headers.some(header => /per second/i.test(header))) return '1 second';
  return '1M tokens';
}

export function parseProviderPricingMarkdown(
  provider: Extract<ModelPriceProvider, 'anthropic' | 'openai'>,
  markdown: string,
  sourceUrl: string,
  capturedAt = new Date(),
): ModelPriceRecord[] {
  const lines = markdown.replace(/\r/g, '').split('\n');
  const snapshotDate = capturedAt.toISOString().slice(0, 10);
  let offering = 'Standard';
  const records = new Map<string, ModelPriceRecord>();

  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = clean(lines[index]);
    if (/^(Standard|Batch|Flex|Fast mode)$/i.test(trimmed)) offering = trimmed.replace(/ mode$/i, '');
    const heading = trimmed.match(/^#{1,4}\s+(.+)$/)?.[1] ?? '';
    if (/batch/i.test(heading)) offering = 'Batch';
    else if (/fast mode/i.test(heading)) offering = 'Fast';
    else if (/model pricing/i.test(heading)) offering = 'Standard';

    if (!lines[index].trim().startsWith('|') || index + 1 >= lines.length) continue;
    const headers = markdownCells(lines[index]);
    const separator = markdownCells(lines[index + 1]);
    const modelIndex = headers.findIndex(header => header.toLowerCase() === 'model');
    if (modelIndex < 0 || !isSeparator(separator) || separator.length !== headers.length) continue;

    index += 2;
    while (index < lines.length && lines[index].trim().startsWith('|')) {
      const cells = markdownCells(lines[index]);
      const row = Object.fromEntries(headers.map((header, cellIndex) => [header, cells[cellIndex] ?? '']));
      const model = clean(cells[modelIndex] ?? '');
      const monetaryValues = Object.values(row).map(money).filter(value => value !== null);
      if (model && monetaryValues.length > 0) {
        const category = row.Category ?? '';
        const record = withId({
          snapshotDate,
          capturedAt: capturedAt.toISOString(),
          provider,
          modelFamily: modelFamily(provider, model, category),
          model,
          offering,
          modality: row.Modality || row['Use case'] || null,
          region: null,
          currency: 'USD',
          unitOfMeasure: unitOfMeasure(headers, row),
          inputPrice: valueFor(row, ['input', 'base input tokens', 'short context input', 'batch input']),
          cachedInputPrice: valueFor(row, ['cached input', 'short context cached input', 'cache hits and refreshes']),
          cacheWritePrice: valueFor(row, ['cache writes', 'short context cache writes', '5m cache writes']),
          cacheWriteOneHourPrice: valueFor(row, ['1h cache writes']),
          outputPrice: valueFor(row, ['output', 'output / cost', 'output tokens', 'short context output', 'batch output']),
          longContextInputPrice: valueFor(row, ['long context input']),
          longContextCachedInputPrice: valueFor(row, ['long context cached input']),
          longContextOutputPrice: valueFor(row, ['long context output']),
          retailPrice: valueFor(row, ['price per minute', 'price per second', 'estimated cost']),
          skuName: null,
          meterName: null,
          priceType: null,
          sourceUrl,
          sourceEffectiveDate: null,
          sourceFields: row,
        });
        records.set(record.id, record);
      }
      index += 1;
    }
    index -= 1;
  }
  return [...records.values()];
}

export function normalizeAzureRetailPrices(
  items: AzureRetailPriceItem[],
  sourceUrl: string,
  capturedAt = new Date(),
): ModelPriceRecord[] {
  const snapshotDate = capturedAt.toISOString().slice(0, 10);
  const records = new Map<string, ModelPriceRecord>();
  for (const item of items) {
    const model = clean(item.skuName || item.meterName || '');
    const productName = clean(item.productName || 'Azure AI');
    if (!model || !Number.isFinite(item.retailPrice)) continue;
    const family = productName.replace(/^Azure OpenAI\s*/i, '').trim() || 'Azure OpenAI';
    const record = withId({
      snapshotDate,
      capturedAt: capturedAt.toISOString(),
      provider: 'azure',
      modelFamily: family,
      model,
      offering: clean(item.type || 'Consumption'),
      modality: null,
      region: clean(item.armRegionName || item.location || '') || null,
      currency: clean(item.currencyCode || 'USD'),
      unitOfMeasure: clean(item.unitOfMeasure || 'Unit'),
      inputPrice: null,
      cachedInputPrice: null,
      cacheWritePrice: null,
      cacheWriteOneHourPrice: null,
      outputPrice: null,
      longContextInputPrice: null,
      longContextCachedInputPrice: null,
      longContextOutputPrice: null,
      retailPrice: Number(item.retailPrice),
      skuName: clean(item.skuName || '') || null,
      meterName: clean(item.meterName || '') || null,
      priceType: clean(item.type || '') || null,
      sourceUrl,
      sourceEffectiveDate: item.effectiveStartDate ?? null,
      sourceFields: {
        meterId: item.meterId ?? '',
        productId: item.productId ?? '',
        skuId: item.skuId ?? '',
        productName,
        serviceName: item.serviceName ?? '',
      },
    });
    records.set(record.id, record);
  }
  return [...records.values()];
}