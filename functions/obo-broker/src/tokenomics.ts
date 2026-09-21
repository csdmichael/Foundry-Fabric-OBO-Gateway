import { ManagedIdentityCredential } from '@azure/identity';
import {
  LogsQueryClient,
  LogsQueryResultStatus,
  type LogsQueryResult,
  type LogsTable,
} from '@azure/monitor-query-logs';
import type { BrokerConfig, TokenRate } from './config.js';
import type { ActualCostSnapshot } from './cost-management.js';
import { BrokerError } from './errors.js';

export const tokenomicsWindows = [1, 7, 30, 90] as const;
export type TokenomicsWindow = typeof tokenomicsWindows[number];

type QueryRow = Record<string, unknown>;

export interface TokenomicsDashboard {
  generatedAt: string;
  windowDays: TokenomicsWindow;
  currency: string;
  queryStatus: 'complete' | 'partial';
  actualCost?: ActualCostSnapshot & {
    allocatedModelCost: number | null;
    allocationMethod: 'observed-token-share' | 'none';
  };
  summary: {
    requests: number;
    successfulRequests: number;
    failedRequests: number;
    tokenizedRequests: number;
    tokenCoveragePct: number;
    inputTokens: number;
    outputTokens: number;
    totalTokens: number;
    p95LatencyMs: number;
    marketCost: number | null;
    negotiatedCost: number | null;
    savings: number | null;
    pricingCoveragePct: number;
  };
  trend: QueryRow[];
  allocations: QueryRow[];
  models: QueryRow[];
  operations: QueryRow[];
  recentRequests: QueryRow[];
  dataQuality: {
    requestTelemetry: 'available' | 'empty';
    tokenTelemetry: 'available' | 'not-observed';
    pricing: 'negotiated' | 'market-only' | 'unconfigured' | 'partial';
    allocation: 'attributed' | 'partial' | 'unattributed';
    billing?: 'actual' | 'empty' | 'unavailable' | 'disabled';
  };
}

export interface TokenomicsUsageDashboard extends TokenomicsDashboard {
  billingAllocations: QueryRow[];
}

export interface LogsQueryPort {
  queryWorkspace(workspaceId: string, query: string, timespan: { duration: string }, options?: { serverTimeoutInSeconds?: number }): Promise<LogsQueryResult>;
}

function text(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function numberValue(value: unknown): number {
  const number = Number(value ?? 0);
  return Number.isFinite(number) ? number : 0;
}

export function rowsFromTables(tables: LogsTable[]): QueryRow[] {
  return tables.flatMap(table => table.rows.map(row => Object.fromEntries(
    table.columnDescriptors.map((column, index) => [column.name, row[index]]),
  )));
}

export function tokenomicsWindow(value: string | null): TokenomicsWindow {
  const days = Number(value ?? 30);
  if (!tokenomicsWindows.includes(days as TokenomicsWindow)) throw new BrokerError(400, 'invalid_window');
  return days as TokenomicsWindow;
}

function rateFor(rateCard: TokenRate[], model: string, at: string): TokenRate | undefined {
  const timestamp = Date.parse(at);
  return rateCard
    .filter(rate => rate.model.toLowerCase() === model.toLowerCase()
      && Date.parse(rate.effectiveFrom) <= timestamp
      && (rate.effectiveTo === undefined || timestamp < Date.parse(rate.effectiveTo)))
    .sort((left, right) => Date.parse(right.effectiveFrom) - Date.parse(left.effectiveFrom))[0];
}

function priceRows(rows: QueryRow[], rateCard: TokenRate[]): QueryRow[] {
  return rows.map(row => {
    const inputTokens = numberValue(row.PromptTokens);
    const outputTokens = numberValue(row.CompletionTokens);
    const totalTokens = inputTokens + outputTokens;
    const rate = rateFor(rateCard, text(row.Model), text(row.TimeBucket) || new Date().toISOString());
    if (!rate || totalTokens === 0) return { ...row, MarketCost: null, NegotiatedCost: null, PricedTokens: 0 };
    const marketCost = inputTokens / 1_000_000 * rate.marketInputUsdPerMillion
      + outputTokens / 1_000_000 * rate.marketOutputUsdPerMillion;
    const hasNegotiatedRate = rate.negotiatedInputUsdPerMillion !== undefined && rate.negotiatedOutputUsdPerMillion !== undefined;
    const negotiatedCost = hasNegotiatedRate
      ? inputTokens / 1_000_000 * rate.negotiatedInputUsdPerMillion!
        + outputTokens / 1_000_000 * rate.negotiatedOutputUsdPerMillion!
      : null;
    return { ...row, MarketCost: marketCost, NegotiatedCost: negotiatedCost, PricedTokens: totalTokens };
  });
}

function round(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

export function buildTokenomicsDashboard(rows: QueryRow[], config: BrokerConfig, days: TokenomicsWindow, queryStatus: 'complete' | 'partial'): TokenomicsUsageDashboard {
  const summaryRow = rows.find(row => row.Section === 'summary') ?? {};
  const modelRows = priceRows(rows.filter(row => row.Section === 'model'), config.tokenomicsRateCard);
  const trend = priceRows(rows.filter(row => row.Section === 'trend'), config.tokenomicsRateCard);
  const allocations = priceRows(rows.filter(row => row.Section === 'allocation'), config.tokenomicsRateCard);
  const totalTokens = numberValue(summaryRow.TotalTokens);
  const tokenizedRequests = numberValue(summaryRow.TokenizedRequests);
  const requests = numberValue(summaryRow.Requests);
  const marketCoverageTokens = modelRows.reduce((total, row) => total + numberValue(row.PricedTokens), 0);
  const negotiatedCoverageTokens = modelRows.reduce((total, row) => total + (row.NegotiatedCost === null ? 0 : numberValue(row.PricedTokens)), 0);
  const marketCostValue = modelRows.reduce((total, row) => total + numberValue(row.MarketCost), 0);
  const negotiatedCostValue = modelRows.reduce((total, row) => total + numberValue(row.NegotiatedCost), 0);
  const fullyMarketPriced = totalTokens > 0 && marketCoverageTokens === totalTokens;
  const fullyNegotiated = totalTokens > 0 && negotiatedCoverageTokens === totalTokens;
  const marketCost = fullyMarketPriced ? round(marketCostValue) : null;
  const negotiatedCost = fullyNegotiated ? round(negotiatedCostValue) : null;
  const attributedRequests = allocations
    .filter(row => text(row.ApplicationId) !== 'unattributed')
    .reduce((total, row) => total + numberValue(row.Requests), 0);
  const pricing = config.tokenomicsRateCard.length === 0 ? 'unconfigured'
    : fullyNegotiated ? 'negotiated'
      : fullyMarketPriced ? 'market-only' : 'partial';
  const allocation = requests === 0 || attributedRequests === 0 ? 'unattributed'
    : attributedRequests === requests ? 'attributed' : 'partial';

  return {
    generatedAt: new Date().toISOString(),
    windowDays: days,
    currency: config.tokenomicsCurrency,
    queryStatus,
    summary: {
      requests,
      successfulRequests: numberValue(summaryRow.Successes),
      failedRequests: numberValue(summaryRow.Errors),
      tokenizedRequests,
      tokenCoveragePct: requests === 0 ? 0 : round(tokenizedRequests / requests * 100),
      inputTokens: numberValue(summaryRow.PromptTokens),
      outputTokens: numberValue(summaryRow.CompletionTokens),
      totalTokens,
      p95LatencyMs: numberValue(summaryRow.P95LatencyMs),
      marketCost,
      negotiatedCost,
      savings: marketCost !== null && negotiatedCost !== null ? round(marketCost - negotiatedCost) : null,
      pricingCoveragePct: totalTokens === 0 ? 0 : round(marketCoverageTokens / totalTokens * 100),
    },
    trend,
    allocations,
    models: modelRows,
    billingAllocations: rows.filter(row => row.Section === 'allocationDaily'),
    operations: rows.filter(row => row.Section === 'operation'),
    recentRequests: rows.filter(row => row.Section === 'recent'),
    dataQuality: {
      requestTelemetry: requests > 0 ? 'available' : 'empty',
      tokenTelemetry: tokenizedRequests > 0 ? 'available' : 'not-observed',
      pricing,
      allocation,
    },
  };
}

function allocateModelCost(rows: QueryRow[], cost: number | null): QueryRow[] {
  if (cost === null) return rows.map(row => ({ ...row, ActualCost: null }));
  const totalTokens = rows.reduce((total, row) => total + numberValue(row.TotalTokens), 0);
  if (totalTokens === 0) return rows.map(row => ({ ...row, ActualCost: null }));
  return rows.map(row => ({ ...row, ActualCost: round(cost * numberValue(row.TotalTokens) / totalTokens) }));
}

function allocationKey(row: QueryRow, fields: string[]): string {
  return fields.map(field => text(row[field])).join('\u001f');
}

function aggregateActualCost(summaryRows: QueryRow[], dailyRows: QueryRow[], fields: string[], costKnown: boolean): QueryRow[] {
  if (!costKnown) return summaryRows.map(row => ({ ...row, ActualCost: null }));
  const totals = new Map<string, number>();
  for (const row of dailyRows) {
    if (row.ActualCost === null || row.ActualCost === undefined) continue;
    const key = allocationKey(row, fields);
    totals.set(key, (totals.get(key) ?? 0) + numberValue(row.ActualCost));
  }
  return summaryRows.map(row => {
    const key = allocationKey(row, fields);
    return { ...row, ActualCost: totals.has(key) ? round(totals.get(key)!) : null };
  });
}

function allocateDailyCost(rows: QueryRow[], dailyCost: Map<string, number>, costKnown: boolean): QueryRow[] {
  const rowsByDate = new Map<string, QueryRow[]>();
  for (const row of rows) {
    const date = text(row.TimeBucket).slice(0, 10);
    rowsByDate.set(date, [...(rowsByDate.get(date) ?? []), row]);
  }
  return [...rowsByDate.entries()]
    .flatMap(([date, dailyRows]) => allocateModelCost(dailyRows, costKnown ? dailyCost.get(date) ?? 0 : null));
}

export function reconcileActualCost(dashboard: TokenomicsUsageDashboard, actualCost: ActualCostSnapshot): TokenomicsDashboard {
  const costKnown = actualCost.status === 'available' || actualCost.status === 'empty';
  const dailyCost = new Map(actualCost.trend.map(row => [row.date, row.dedicatedModelCost]));
  const trend = allocateDailyCost(dashboard.trend, dailyCost, costKnown);
  const dailyAllocations = allocateDailyCost(dashboard.billingAllocations, dailyCost, costKnown);
  const allocations = aggregateActualCost(
    dashboard.allocations,
    dailyAllocations,
    ['ApplicationId', 'ProjectId', 'TeamId', 'CostCenter', 'Model'],
    costKnown,
  );
  const models = aggregateActualCost(dashboard.models, trend, ['Model', 'IsStream'], costKnown);
  const allocatedModelCost = allocations.some(row => row.ActualCost !== null)
    ? round(allocations.reduce((total, row) => total + numberValue(row.ActualCost), 0))
    : null;
  const { billingAllocations: _, ...publicDashboard } = dashboard;
  return {
    ...publicDashboard,
    actualCost: {
      ...actualCost,
      allocatedModelCost,
      allocationMethod: allocatedModelCost === null ? 'none' : 'observed-token-share',
    },
    allocations,
    models,
    trend,
    dataQuality: {
      ...dashboard.dataQuality,
      billing: actualCost.status === 'available' ? 'actual' : actualCost.status,
    },
  };
}

export function tokenomicsDashboardQuery(config: BrokerConfig): string {
  const apiIds = JSON.stringify(config.tokenomicsApiIds);
  const apiAttribution = JSON.stringify(config.tokenomicsApiAttribution);
  const projectId = config.tokenomicsProjectId;
  const teamId = config.tokenomicsTeamId;
  const costCenter = config.tokenomicsCostCenter;
  return `
let ApiIds = dynamic(${apiIds});
let ApiAttribution = dynamic(${apiAttribution});
let Gateway = materialize(
  union isfuzzy=true
    (datatable(TimeGenerated:datetime, CorrelationId:string, ApiId:string, OperationId:string, ResponseCode:int, TotalTime:real)[]),
    (ApiManagementGatewayLogs
      | where set_has_element(ApiIds, tostring(ApiId))
      | project TimeGenerated, CorrelationId=tostring(CorrelationId), ApiId=tostring(ApiId),
          OperationId=tostring(OperationId), ResponseCode=toint(ResponseCode), TotalTime=toreal(TotalTime))
);
let Audits = materialize(
  union isfuzzy=true
    (datatable(TimeGenerated:datetime, CorrelationId:string, UserIdHash:string, ApplicationId:string, ProjectId:string, TeamId:string, CostCenter:string)[]),
    (AppTraces
      | extend Audit=parse_json(Message)
      | where tostring(Audit.event) == 'fabric_obo_request'
      | project TimeGenerated, CorrelationId=tostring(Audit.correlationId), UserIdHash=tostring(Audit.userIdHash),
          ApplicationId=tostring(Audit.applicationId), ProjectId=tostring(Audit.projectId),
          TeamId=tostring(Audit.teamId), CostCenter=tostring(Audit.costCenter)
      | summarize arg_max(TimeGenerated, *) by CorrelationId)
);
let Requests = materialize(
  Gateway
  | join kind=leftouter Audits on CorrelationId
    | extend ConfiguredApplicationId=tostring(ApiAttribution[ApiId])
    | extend UserIdHash=iff(isempty(UserIdHash), 'unattributed', UserIdHash),
      ApplicationId=iff(isempty(ApplicationId), iff(isempty(ConfiguredApplicationId), 'unattributed', ConfiguredApplicationId), ApplicationId),
      ProjectId=iff(isempty(ProjectId), '${projectId}', ProjectId),
      TeamId=iff(isempty(TeamId), '${teamId}', TeamId),
      CostCenter=iff(isempty(CostCenter), '${costCenter}', CostCenter)
    | project-away ConfiguredApplicationId
);
let Tokens = materialize(
  union isfuzzy=true
    (datatable(TimeGenerated:datetime, CorrelationId:string, PromptTokens:long, CompletionTokens:long, TotalTokens:long, Model:string, IsStream:bool)[]),
    (ApiManagementGatewayLlmLog
      | where TotalTokens > 0
      | project TimeGenerated, CorrelationId=tostring(CorrelationId), PromptTokens=tolong(PromptTokens),
          CompletionTokens=tolong(CompletionTokens), TotalTokens=tolong(TotalTokens),
          Model=replace_regex(tostring(ModelName), @'-\\d{4}-\\d{2}-\\d{2}$', ''), IsStream=tobool(IsStreamCompletion))
);
let TokenContext = materialize(
  Tokens
  | join kind=inner (Requests | project CorrelationId, ApiId, OperationId, UserIdHash, ApplicationId, ProjectId, TeamId, CostCenter) on CorrelationId
  | extend ApiId=coalesce(ApiId, 'unattributed'), OperationId=coalesce(OperationId, 'unattributed'),
      UserIdHash=coalesce(UserIdHash, 'unattributed'), ApplicationId=coalesce(ApplicationId, 'unattributed'),
      ProjectId=coalesce(ProjectId, '${projectId}'), TeamId=coalesce(TeamId, '${teamId}'), CostCenter=coalesce(CostCenter, '${costCenter}')
);
let Activity = materialize(union
  (Requests | project TimeGenerated, CorrelationId, ApiId, OperationId, UserIdHash, ApplicationId, ProjectId, TeamId, CostCenter,
    Model='', IsStream=false, Requests=long(1), Successes=tolong(ResponseCode between (200 .. 299)),
    Errors=tolong(ResponseCode < 200 or ResponseCode >= 300), LatencyMs=TotalTime,
    PromptTokens=long(0), CompletionTokens=long(0), TotalTokens=long(0), HasTokenUsage=long(0)),
  (TokenContext | project TimeGenerated, CorrelationId, ApiId, OperationId, UserIdHash, ApplicationId, ProjectId, TeamId, CostCenter,
    Model, IsStream, Requests=long(0), Successes=long(0), Errors=long(0), LatencyMs=real(null),
    PromptTokens, CompletionTokens, TotalTokens, HasTokenUsage=long(1))
);
union
  (Activity
    | summarize Requests=sum(Requests), Successes=sum(Successes), Errors=sum(Errors),
        TokenizedRequests=dcountif(CorrelationId, HasTokenUsage == 1), PromptTokens=sum(PromptTokens),
        CompletionTokens=sum(CompletionTokens), TotalTokens=sum(TotalTokens), P95LatencyMs=percentile(LatencyMs, 95)
    | extend Section='summary', TimeBucket='', ApplicationId='', ProjectId='', TeamId='', CostCenter='', Model='', ApiId='', OperationId='', StatusCode=0, CorrelationId='', UserIdHash='', IsStream=false),
  (Activity
    | summarize Requests=sum(Requests), Successes=sum(Successes), Errors=sum(Errors),
        TokenizedRequests=dcountif(CorrelationId, HasTokenUsage == 1), PromptTokens=sum(PromptTokens),
        CompletionTokens=sum(CompletionTokens), TotalTokens=sum(TotalTokens), P95LatencyMs=percentile(LatencyMs, 95)
        by TimeBucket=format_datetime(bin(TimeGenerated, 1d), 'yyyy-MM-dd'), Model, IsStream
      | extend Section='trend', ApplicationId='', ProjectId='', TeamId='', CostCenter='', ApiId='', OperationId='', StatusCode=0, CorrelationId='', UserIdHash=''),
  (Activity
    | summarize Requests=sum(Requests), Successes=sum(Successes), Errors=sum(Errors),
        TokenizedRequests=dcountif(CorrelationId, HasTokenUsage == 1), PromptTokens=sum(PromptTokens),
        CompletionTokens=sum(CompletionTokens), TotalTokens=sum(TotalTokens), P95LatencyMs=percentile(LatencyMs, 95)
        by ApplicationId, ProjectId, TeamId, CostCenter, Model
    | extend Section='allocation', TimeBucket='', ApiId='', OperationId='', StatusCode=0, CorrelationId='', UserIdHash='', IsStream=false),
  (Activity
    | summarize Requests=sum(Requests), Successes=sum(Successes), Errors=sum(Errors),
        TokenizedRequests=dcountif(CorrelationId, HasTokenUsage == 1), PromptTokens=sum(PromptTokens),
        CompletionTokens=sum(CompletionTokens), TotalTokens=sum(TotalTokens), P95LatencyMs=percentile(LatencyMs, 95)
        by TimeBucket=format_datetime(bin(TimeGenerated, 1d), 'yyyy-MM-dd'), ApplicationId, ProjectId, TeamId, CostCenter, Model
    | extend Section='allocationDaily', ApiId='', OperationId='', StatusCode=0, CorrelationId='', UserIdHash='', IsStream=false),
  (TokenContext
    | summarize Requests=dcount(CorrelationId), Successes=long(0), Errors=long(0), TokenizedRequests=dcount(CorrelationId),
        PromptTokens=sum(PromptTokens), CompletionTokens=sum(CompletionTokens), TotalTokens=sum(TotalTokens), P95LatencyMs=real(0)
        by Model, IsStream
    | extend Section='model', TimeBucket='', ApplicationId='', ProjectId='', TeamId='', CostCenter='', ApiId='', OperationId='', StatusCode=0, CorrelationId='', UserIdHash=''),
  (Requests
    | summarize Requests=count(), Successes=countif(ResponseCode between (200 .. 299)), Errors=countif(ResponseCode < 200 or ResponseCode >= 300),
        TokenizedRequests=long(0), PromptTokens=long(0), CompletionTokens=long(0), TotalTokens=long(0), P95LatencyMs=percentile(TotalTime, 95)
        by ApiId, OperationId
    | extend Section='operation', TimeBucket='', ApplicationId='', ProjectId='', TeamId='', CostCenter='', Model='', StatusCode=0, CorrelationId='', UserIdHash='', IsStream=false),
  (Requests
    | top 25 by TimeGenerated desc
    | project Section='recent', TimeBucket=format_datetime(TimeGenerated, 'yyyy-MM-ddTHH:mm:ssZ'), ApplicationId, ProjectId, TeamId, CostCenter,
        Model='', ApiId, OperationId, StatusCode=ResponseCode, CorrelationId, UserIdHash, IsStream=false,
        Requests=long(1), Successes=tolong(ResponseCode between (200 .. 299)), Errors=tolong(ResponseCode < 200 or ResponseCode >= 300),
        TokenizedRequests=long(0), PromptTokens=long(0), CompletionTokens=long(0), TotalTokens=long(0), P95LatencyMs=TotalTime)
`;
}

export function createTokenomicsQuery(config: BrokerConfig, client?: LogsQueryPort) {
  const queryClient = client ?? new LogsQueryClient(new ManagedIdentityCredential(config.managedIdentityClientId));
  return async (days: TokenomicsWindow): Promise<TokenomicsUsageDashboard> => {
    const result = await queryClient.queryWorkspace(
      config.logAnalyticsWorkspaceId,
      tokenomicsDashboardQuery(config),
      { duration: `P${days}D` },
      { serverTimeoutInSeconds: 45 },
    );
    const complete = result.status === LogsQueryResultStatus.Success;
    const tables = complete ? result.tables : result.partialTables;
    if (!tables.length) throw new BrokerError(503, 'tokenomics_unavailable');
    return buildTokenomicsDashboard(rowsFromTables(tables), config, days, complete ? 'complete' : 'partial');
  };
}