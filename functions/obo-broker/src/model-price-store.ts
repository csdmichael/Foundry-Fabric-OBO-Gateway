import { CosmosClient, type Container, type SqlQuerySpec } from '@azure/cosmos';
import { ManagedIdentityCredential } from '@azure/identity';
import { createHash, randomUUID } from 'node:crypto';
import type { ModelPriceProvider, ModelPriceRecord } from './model-pricing.js';

export interface ModelPriceStoreSettings {
  cosmosEndpoint: string;
  cosmosDatabaseId: string;
  cosmosContainerId: string;
  managedIdentityClientId: string;
}

export interface ModelPriceFilters {
  snapshotDate?: string;
  provider?: ModelPriceProvider;
  modelFamily?: string;
  model?: string;
}

export interface ModelPriceSnapshot {
  snapshotDate: string | null;
  capturedAt: string | null;
  providers: ModelPriceProvider[];
  modelFamilies: string[];
  records: ModelPriceRecord[];
}

export interface ModelPriceStorePort {
  replaceSnapshot(snapshotDate: string, capturedAt: string, records: ModelPriceRecord[]): Promise<void>;
  query(filters?: ModelPriceFilters): Promise<ModelPriceSnapshot>;
}

interface SnapshotManifest {
  id: string;
  kind: 'snapshot';
  snapshotDate: string;
  capturedAt: string;
  activeIngestionId: string;
  providers: ModelPriceProvider[];
  recordCount: number;
}

interface StoredModelPriceRecord extends ModelPriceRecord {
  kind: 'price';
  ingestionId: string;
  sourceRecordId: string;
}

function ingestionDocumentId(sourceRecordId: string, ingestionId: string): string {
  return createHash('sha256').update(`${sourceRecordId}|${ingestionId}`).digest('hex');
}

function querySpec(filters: ModelPriceFilters, ingestionId: string, snapshotDate: string): SqlQuerySpec {
  const conditions = [
    "c.kind = 'price'",
    'c.snapshotDate = @snapshotDate',
    'c.ingestionId = @ingestionId',
  ];
  const parameters: Array<{ name: string; value: string }> = [
    { name: '@snapshotDate', value: snapshotDate },
    { name: '@ingestionId', value: ingestionId },
  ];
  if (filters.provider) {
    conditions.push('c.provider = @provider');
    parameters.push({ name: '@provider', value: filters.provider });
  }
  if (filters.modelFamily) {
    conditions.push('c.modelFamily = @modelFamily');
    parameters.push({ name: '@modelFamily', value: filters.modelFamily });
  }
  if (filters.model) {
    conditions.push('CONTAINS(LOWER(c.model), @model)');
    parameters.push({ name: '@model', value: filters.model.toLowerCase() });
  }
  return {
    query: `SELECT * FROM c WHERE ${conditions.join(' AND ')} ORDER BY c.provider, c.modelFamily, c.model`,
    parameters,
  };
}

export class CosmosModelPriceStore implements ModelPriceStorePort {
  constructor(private readonly container: Container) {}

  async replaceSnapshot(snapshotDate: string, capturedAt: string, records: ModelPriceRecord[]): Promise<void> {
    const ingestionId = randomUUID();
    const existing = await this.container.items.query<{ id: string }>({
      query: "SELECT c.id FROM c WHERE c.snapshotDate = @snapshotDate AND c.kind = 'price'",
      parameters: [{ name: '@snapshotDate', value: snapshotDate }],
    }, { partitionKey: snapshotDate }).fetchAll();
    const newIds = new Set<string>();
    for (let index = 0; index < records.length; index += 25) {
      const batch = records.slice(index, index + 25).map(record => {
        const id = ingestionDocumentId(record.id, ingestionId);
        newIds.add(id);
        const stored: StoredModelPriceRecord = {
          ...record,
          id,
          kind: 'price',
          ingestionId,
          sourceRecordId: record.id,
        };
        return this.container.items.upsert(stored);
      });
      await Promise.all(batch);
    }
    const providers = [...new Set(records.map(record => record.provider))].sort() as ModelPriceProvider[];
    const manifest: SnapshotManifest = {
      id: `snapshot:${snapshotDate}`,
      kind: 'snapshot',
      snapshotDate,
      capturedAt,
      activeIngestionId: ingestionId,
      providers,
      recordCount: records.length,
    };
    await this.container.items.upsert(manifest);
    const staleIds = existing.resources.map(item => item.id).filter(id => !newIds.has(id));
    for (let index = 0; index < staleIds.length; index += 25) {
      await Promise.all(staleIds.slice(index, index + 25).map(id => this.container.item(id, snapshotDate).delete()));
    }
  }

  async query(filters: ModelPriceFilters = {}): Promise<ModelPriceSnapshot> {
    const manifestQuery: SqlQuerySpec = filters.snapshotDate
      ? {
          query: "SELECT TOP 1 * FROM c WHERE c.kind = 'snapshot' AND c.snapshotDate = @snapshotDate",
          parameters: [{ name: '@snapshotDate', value: filters.snapshotDate }],
        }
      : { query: "SELECT TOP 1 * FROM c WHERE c.kind = 'snapshot' ORDER BY c.snapshotDate DESC" };
    const manifests = await this.container.items.query<SnapshotManifest>(manifestQuery, {
      partitionKey: filters.snapshotDate,
      maxItemCount: 1,
    }).fetchAll();
    const manifest = manifests.resources[0];
    if (!manifest) return { snapshotDate: null, capturedAt: null, providers: [], modelFamilies: [], records: [] };
    const result = await this.container.items.query<StoredModelPriceRecord>(
      querySpec(filters, manifest.activeIngestionId, manifest.snapshotDate),
      { partitionKey: manifest.snapshotDate },
    ).fetchAll();
    const records = result.resources.map(({ kind: _, ingestionId: __, sourceRecordId: ___, ...record }) => record);
    return {
      snapshotDate: manifest.snapshotDate,
      capturedAt: manifest.capturedAt,
      providers: [...new Set(records.map(record => record.provider))].sort() as ModelPriceProvider[],
      modelFamilies: [...new Set(records.map(record => record.modelFamily))].sort(),
      records,
    };
  }
}

export function createModelPriceStore(settings: ModelPriceStoreSettings): ModelPriceStorePort {
  const client = new CosmosClient({
    endpoint: settings.cosmosEndpoint,
    aadCredentials: new ManagedIdentityCredential(settings.managedIdentityClientId),
  });
  return new CosmosModelPriceStore(client.database(settings.cosmosDatabaseId).container(settings.cosmosContainerId));
}

export { querySpec as modelPriceQuerySpec };