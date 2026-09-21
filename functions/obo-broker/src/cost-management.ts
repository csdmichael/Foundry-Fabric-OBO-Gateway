import { ManagedIdentityCredential } from '@azure/identity';
import type { ActualCostResource, BrokerConfig } from './config.js';

interface CostColumn {
  name: string;
  type: string;
}

export interface CostQueryPage {
  properties?: {
    columns?: CostColumn[];
    rows?: unknown[][];
    nextLink?: string | null;
  };
}

export interface CostManagementPort {
  query(scope: string, apiVersion: string, body: Record<string, unknown>): Promise<CostQueryPage[]>;
}

export interface ActualCostBreakdown {
  name: string;
  cost: number;
}

export interface ActualCostTrend {
  date: string;
  scopeCost: number;
  trackedCost: number;
  dedicatedModelCost: number;
}

export interface ActualCostSnapshot {
  source: 'AzureCostManagement';
  queryType: 'ActualCost';
  status: 'available' | 'empty' | 'unavailable' | 'disabled';
  scope: string;
  currency: string;
  generatedAt: string;
  billedThrough: string | null;
  expectedBillingLagHours: number;
  scopeCost: number | null;
  trackedCost: number | null;
  dedicatedModelCost: number | null;
  sharedPlatformCost: number | null;
  untrackedCost: number | null;
  byService: ActualCostBreakdown[];
  byResource: ActualCostBreakdown[];
  trend: ActualCostTrend[];
}

type CostRow = Record<string, unknown>;

function numberValue(value: unknown): number {
  const number = Number(value ?? 0);
  return Number.isFinite(number) ? number : 0;
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : String(value ?? '');
}

function round(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function usageDate(value: unknown): string | null {
  const raw = text(value);
  if (/^\d{8}$/.test(raw)) return `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}`;
  const timestamp = Date.parse(raw);
  return Number.isNaN(timestamp) ? null : new Date(timestamp).toISOString().slice(0, 10);
}

function rowsFromPages(pages: CostQueryPage[]): CostRow[] {
  return pages.flatMap(page => {
    const columns = page.properties?.columns ?? [];
    return (page.properties?.rows ?? []).map(row => Object.fromEntries(columns.map((column, index) => [column.name, row[index]])));
  });
}

function aggregate(items: Array<{ name: string; cost: number }>): ActualCostBreakdown[] {
  const totals = new Map<string, number>();
  for (const item of items) totals.set(item.name || 'Unspecified', (totals.get(item.name || 'Unspecified') ?? 0) + item.cost);
  return [...totals.entries()]
    .map(([name, cost]) => ({ name, cost: round(cost) }))
    .sort((left, right) => right.cost - left.cost);
}

function trackedResource(resources: ActualCostResource[], resourceId: string): ActualCostResource | undefined {
  const normalized = resourceId.toLowerCase();
  return resources.find(resource => resource.resourceId.toLowerCase() === normalized);
}

export function buildActualCostSnapshot(pages: CostQueryPage[], config: BrokerConfig, generatedAt = new Date()): ActualCostSnapshot {
  const rows = rowsFromPages(pages);
  const normalized = rows.map(row => {
    const resourceId = text(row.ResourceId).toLowerCase();
    const tracked = trackedResource(config.actualCostTrackedResources, resourceId);
    return {
      cost: numberValue(row.Cost ?? row.PreTaxCost),
      currency: text(row.Currency) || config.tokenomicsCurrency,
      date: usageDate(row.UsageDate),
      resourceId,
      serviceName: text(row.ServiceName) || 'Unspecified',
      tracked,
    };
  });
  const currencies = [...new Set(normalized.map(row => row.currency).filter(Boolean))];
  const scopeCost = normalized.reduce((total, row) => total + row.cost, 0);
  const trackedRows = normalized.filter(row => row.tracked);
  const trackedCost = trackedRows.reduce((total, row) => total + row.cost, 0);
  const dedicatedModelCost = trackedRows
    .filter(row => row.tracked?.category === 'model' && !row.tracked.shared)
    .reduce((total, row) => total + row.cost, 0);
  const sharedPlatformCost = trackedRows
    .filter(row => row.tracked?.shared)
    .reduce((total, row) => total + row.cost, 0);
  const dates = normalized.map(row => row.date).filter((date): date is string => date !== null);
  const trend = [...new Set(dates)].sort().map(date => {
    const dailyRows = normalized.filter(row => row.date === date);
    return {
      date,
      scopeCost: round(dailyRows.reduce((total, row) => total + row.cost, 0)),
      trackedCost: round(dailyRows.filter(row => row.tracked).reduce((total, row) => total + row.cost, 0)),
      dedicatedModelCost: round(dailyRows
        .filter(row => row.tracked?.category === 'model' && !row.tracked.shared)
        .reduce((total, row) => total + row.cost, 0)),
    };
  });
  const available = rows.length > 0;
  return {
    source: 'AzureCostManagement',
    queryType: 'ActualCost',
    status: available ? 'available' : 'empty',
    scope: config.actualCostScope,
    currency: currencies.length === 1 ? currencies[0] : config.tokenomicsCurrency,
    generatedAt: generatedAt.toISOString(),
    billedThrough: dates.sort().at(-1) ?? null,
    expectedBillingLagHours: config.actualCostBillingLagHours,
    scopeCost: available ? round(scopeCost) : 0,
    trackedCost: available ? round(trackedCost) : 0,
    dedicatedModelCost: available ? round(dedicatedModelCost) : 0,
    sharedPlatformCost: available ? round(sharedPlatformCost) : 0,
    untrackedCost: available ? round(scopeCost - trackedCost) : 0,
    byService: aggregate(normalized.map(row => ({ name: row.serviceName, cost: row.cost }))),
    byResource: aggregate(normalized.map(row => ({ name: row.resourceId || 'Unspecified', cost: row.cost }))),
    trend,
  };
}

function unavailableSnapshot(config: BrokerConfig, status: 'unavailable' | 'disabled'): ActualCostSnapshot {
  return {
    source: 'AzureCostManagement', queryType: 'ActualCost', status,
    scope: config.actualCostScope, currency: config.tokenomicsCurrency,
    generatedAt: new Date().toISOString(), billedThrough: null,
    expectedBillingLagHours: config.actualCostBillingLagHours,
    scopeCost: null, trackedCost: null, dedicatedModelCost: null,
    sharedPlatformCost: null, untrackedCost: null,
    byService: [], byResource: [], trend: [],
  };
}

export function actualCostRequest(days: number, now = new Date()): Record<string, unknown> {
  const from = new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
  return {
    type: 'ActualCost',
    timeframe: 'Custom',
    timePeriod: { from: from.toISOString(), to: now.toISOString() },
    dataset: {
      granularity: 'Daily',
      aggregation: { totalCost: { name: 'Cost', function: 'Sum' } },
      grouping: [
        { type: 'Dimension', name: 'ResourceId' },
        { type: 'Dimension', name: 'ServiceName' },
      ],
    },
  };
}

function retrySeconds(headers: Headers): number {
  const values: number[] = [];
  headers.forEach((value, name) => {
    const normalized = name.toLowerCase();
    if (normalized === 'retry-after' || (normalized.startsWith('x-ms-ratelimit-microsoft.costmanagement-') && normalized.endsWith('-retry-after'))) {
      const seconds = Number(value);
      if (Number.isFinite(seconds) && seconds >= 0) values.push(seconds);
    }
  });
  return Math.max(1, ...values);
}

function createCostManagementPort(config: BrokerConfig): CostManagementPort {
  const credential = new ManagedIdentityCredential(config.managedIdentityClientId);
  return {
    async query(scope, apiVersion, body) {
      const token = await credential.getToken('https://management.azure.com/.default');
      if (!token?.token) throw new Error('cost_management_token_unavailable');
      const pages: CostQueryPage[] = [];
      let url: string | null = `https://management.azure.com${scope}/providers/Microsoft.CostManagement/query?api-version=${encodeURIComponent(apiVersion)}`;
      while (url) {
        let page: CostQueryPage | undefined;
        for (let attempt = 0; attempt < 3; attempt += 1) {
          const response = await fetch(url, {
            method: 'POST',
            headers: { Authorization: `Bearer ${token.token}`, 'Content-Type': 'application/json', ClientType: 'FabricCostOps' },
            body: JSON.stringify(body),
            signal: AbortSignal.timeout(45_000),
          });
          if (response.status === 429 && attempt < 2) {
            await new Promise(resolve => setTimeout(resolve, retrySeconds(response.headers) * 1000));
            continue;
          }
          if (!response.ok) throw new Error(`cost_management_${response.status}`);
          page = await response.json() as CostQueryPage;
          break;
        }
        if (!page) throw new Error('cost_management_retry_exhausted');
        pages.push(page);
        url = page.properties?.nextLink ?? null;
      }
      return pages;
    },
  };
}

export function createActualCostQuery(config: BrokerConfig, client?: CostManagementPort) {
  const queryClient = client ?? createCostManagementPort(config);
  return async (days: number): Promise<ActualCostSnapshot> => {
    if (!config.actualCostEnabled) return unavailableSnapshot(config, 'disabled');
    try {
      const pages = await queryClient.query(config.actualCostScope, config.actualCostQueryApiVersion, actualCostRequest(days));
      return buildActualCostSnapshot(pages, config);
    } catch {
      return unavailableSnapshot(config, 'unavailable');
    }
  };
}