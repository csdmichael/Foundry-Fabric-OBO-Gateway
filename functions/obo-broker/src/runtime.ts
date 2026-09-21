import type { HttpRequest, InvocationContext } from '@azure/functions';
import { createHash } from 'node:crypto';
import { createTokenVerifier } from './auth.js';
import { loadConfig, type BrokerConfig, type DownstreamTarget } from './config.js';
import { createActualCostQuery } from './cost-management.js';
import { BrokerError } from './errors.js';
import { createDataAgentClient } from './mcp.js';
import { createTokenExchanger } from './obo.js';
import { assertReadOnlyStatement, executeQuery, searchLakehouseKnowledge, tableListStatement } from './sql.js';
import { createTokenomicsQuery, reconcileActualCost, type TokenomicsDashboard, type TokenomicsWindow } from './tokenomics.js';

export interface Runtime {
  config: BrokerConfig;
  authorize(request: HttpRequest): Promise<{ assertion: string; objectId: string; applicationId: string; expiresAt: number }>;
  exchange(assertion: string, target: DownstreamTarget, expiresAt: number): Promise<{ accessToken: string; expiresIn: number }>;
  query(token: string, statement: string): ReturnType<typeof executeQuery>;
  searchKnowledge(token: string, query: string): ReturnType<typeof searchLakehouseKnowledge>;
  askDataAgent(token: string, question: string): Promise<Record<string, unknown>>;
  tokenomics(days: TokenomicsWindow): Promise<TokenomicsDashboard>;
}

export function createRuntime(config = loadConfig(process.env)): Runtime {
  const verify = createTokenVerifier(config);
  const exchange = createTokenExchanger(config);
  const askDataAgent = createDataAgentClient(config);
  const tokenomics = createTokenomicsQuery(config);
  const actualCost = createActualCostQuery(config);
  return {
    config,
    async authorize(request) {
      const assertion = request.headers.get('x-user-assertion') ?? '';
      const identity = await verify(request.headers.get('authorization') ?? '', assertion);
      return { assertion, ...identity };
    },
    exchange,
    query: (token, statement) => executeQuery(config, token, assertReadOnlyStatement(statement, config.maxStatementLength)),
    searchKnowledge: (token, query) => searchLakehouseKnowledge(config, token, query),
    askDataAgent,
    async tokenomics(days) {
      const [usage, billing] = await Promise.all([tokenomics(days), actualCost(days)]);
      return reconcileActualCost(usage, billing);
    },
  };
}

let singleton: Runtime | undefined;
export function runtime(): Runtime {
  singleton ??= createRuntime();
  return singleton;
}

export function audit(context: InvocationContext, route: string, status: number, metadata: {
  objectId?: string;
  applicationId?: string;
  correlationId?: string;
  projectId?: string;
  teamId?: string;
  costCenter?: string;
} = {}): void {
  const userIdHash = metadata.objectId
    ? createHash('sha256').update(metadata.objectId.toLowerCase()).digest('hex').slice(0, 24)
    : null;
  context.log(JSON.stringify({
    event: 'fabric_obo_request', route, status,
    invocationId: context.invocationId,
    correlationId: metadata.correlationId ?? context.invocationId,
    userIdHash,
    applicationId: metadata.applicationId ?? null,
    projectId: metadata.projectId ?? 'unassigned',
    teamId: metadata.teamId ?? 'unassigned',
    costCenter: metadata.costCenter ?? 'unassigned',
  }));
}

export function statementFromBody(body: unknown): string {
  if (!body || typeof body !== 'object' || typeof (body as { statement?: unknown }).statement !== 'string') {
    throw new BrokerError(400, 'invalid_request');
  }
  return (body as { statement: string }).statement;
}

export function questionFromBody(body: unknown): string {
  if (!body || typeof body !== 'object' || typeof (body as { question?: unknown }).question !== 'string') {
    throw new BrokerError(400, 'invalid_request');
  }
  const question = (body as { question: string }).question.trim();
  if (!question || question.length > 4000 || /[\0\r]/.test(question)) throw new BrokerError(400, 'invalid_request');
  return question;
}

export function knowledgeQueryFromBody(body: unknown): string {
  if (!body || typeof body !== 'object' || typeof (body as { query?: unknown }).query !== 'string') {
    throw new BrokerError(400, 'invalid_request');
  }
  const query = (body as { query: string }).query.trim();
  if (!query || query.length > 500 || /[\0\r]/.test(query)) throw new BrokerError(400, 'invalid_request');
  return query;
}

export { tableListStatement };