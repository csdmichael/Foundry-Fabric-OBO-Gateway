import sql from 'mssql';
import sqlParser from 'node-sql-parser';
import type { BrokerConfig } from './config.js';
import { BrokerError } from './errors.js';

export interface QueryResult {
  columns: Array<{ name: string; type: string }>;
  rows: Record<string, unknown>[];
  rowCount: number;
  truncated: boolean;
}

export interface KnowledgeResult {
  query: string;
  results: Array<{ snippet: string; title: string; url: string }>;
}

const parser = new sqlParser.Parser();
const forbiddenSelectPattern = /\b(OPENROWSET|OPENQUERY|OPENDATASOURCE|BULK|INTO|EXEC(?:UTE)?|WAITFOR)\b/i;
const searchStopWords = new Set(['a', 'all', 'an', 'and', 'are', 'current', 'currently', 'find', 'for', 'is', 'list', 'of', 'open', 'part', 'parts', 'show', 'shortage', 'shortages', 'the', 'what', 'which']);

export function knowledgeSearchTerms(query: string): string[] {
  const terms = query.toLowerCase().match(/[a-z0-9][a-z0-9._-]{1,63}/g) ?? [];
  return [...new Set(terms.filter(term => !searchStopWords.has(term)))].slice(0, 8);
}

export function assertReadOnlyStatement(statement: string, maxLength: number): string {
  const normalized = statement.trim().replace(/;+\s*$/, '');
  if (!normalized || normalized.length > maxLength || /[\0\r]/.test(normalized)
      || forbiddenSelectPattern.test(normalized)) {
    throw new BrokerError(400, 'invalid_statement');
  }
  try {
    const ast = parser.astify(normalized, { database: 'TransactSQL' });
    const statements = Array.isArray(ast) ? ast : [ast];
    if (statements.length !== 1 || statements[0]?.type !== 'select') throw new Error('Not a single SELECT');
  } catch {
    throw new BrokerError(400, 'invalid_statement');
  }
  return normalized;
}

function typeName(column: { type?: unknown }): string {
  const type = column.type as { declaration?: string; name?: string } | undefined;
  return type?.declaration ?? type?.name ?? 'unknown';
}

function createPool(config: BrokerConfig, token: string): sql.ConnectionPool {
  return new sql.ConnectionPool({
    server: config.sqlEndpointHost,
    database: config.lakehouseName,
    port: 1433,
    connectionTimeout: config.sqlConnectTimeoutMs,
    requestTimeout: config.sqlRequestTimeoutMs,
    options: { encrypt: true, trustServerCertificate: false, enableArithAbort: true },
    authentication: { type: 'azure-active-directory-access-token', options: { token } },
    pool: { min: 0, max: 2, idleTimeoutMillis: 10000 },
  });
}

export async function executeQuery(config: BrokerConfig, token: string, statement: string): Promise<QueryResult> {
  const pool = createPool(config, token);
  try {
    await pool.connect();
    const request = pool.request();
    const result = await request.query(`SET ROWCOUNT ${config.maxRows + 1};\n${statement}`);
    const recordset = result.recordset ?? [];
    const rows = recordset.slice(0, config.maxRows) as Record<string, unknown>[];
    const columns = recordset.columns
      ? Object.entries(recordset.columns).map(([name, metadata]) => ({ name, type: typeName(metadata) }))
      : [];
    return { columns, rows, rowCount: rows.length, truncated: recordset.length > config.maxRows };
  } catch (error) {
    if (error instanceof BrokerError) throw error;
    throw new BrokerError(502, 'query_failed');
  } finally {
    await pool.close().catch(() => undefined);
  }
}

function displayValue(value: unknown): string {
  if (value === null || value === undefined) return 'not provided';
  if (value instanceof Date) return value.toISOString();
  return String(value).replace(/[\r\n|]+/g, ' ').trim() || 'not provided';
}

export function formatKnowledgeResults(config: BrokerConfig, query: string, rows: Record<string, unknown>[]): KnowledgeResult {
  const url = `https://app.fabric.microsoft.com/groups/${config.workspaceId}/list`;
  return {
    query,
    results: rows.slice(0, 15).map(row => ({
      title: `Open shortage ${displayValue(row.shortage_id)} - ${displayValue(row.matnr)}`,
      url,
      snippet: [
        `Part ${displayValue(row.matnr)} (${displayValue(row.material_text)})`,
        `plant ${displayValue(row.plant)}`,
        `supplier ${displayValue(row.supplier_name)}`,
        `severity ${displayValue(row.severity_band)}`,
        `shortage quantity ${displayValue(row.qty_short)}`,
        `need date ${displayValue(row.need_date)}`,
        `expected delivery ${displayValue(row.expected_delivery_date)}`,
        `status ${displayValue(row.status)}`,
      ].join('; '),
    })),
  };
}

export async function searchLakehouseKnowledge(config: BrokerConfig, token: string, query: string): Promise<KnowledgeResult> {
  const terms = knowledgeSearchTerms(query);
  const searchText = "CONCAT(COALESCE(shortage_id, ''), ' ', COALESCE(matnr, ''), ' ', COALESCE(material_text, ''), ' ', COALESCE(plant, ''), ' ', COALESCE(supplier_code, ''), ' ', COALESCE(supplier_name, ''), ' ', COALESCE(severity_band, ''), ' ', COALESCE(status, ''), ' ', COALESCE(ml_risk_band, ''), ' ', COALESCE(ml_recommended_path, ''))";
  const termFilter = terms.length > 0
    ? `AND (${terms.map((_term, index) => `${searchText} LIKE @term${index}`).join(' OR ')})`
    : '';
  const statement = `
SELECT TOP (15) shortage_id, matnr, material_text, plant, supplier_name, severity_band,
       qty_short, need_date, expected_delivery_date, status
FROM bv.vw_part_shortage_360
WHERE UPPER(LTRIM(RTRIM(status))) = 'OPEN'
${termFilter}
ORDER BY CASE UPPER(severity_band) WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END,
         need_date, matnr, shortage_id`;
  const pool = createPool(config, token);
  try {
    await pool.connect();
    const request = pool.request();
    terms.forEach((term, index) => request.input(`term${index}`, sql.NVarChar(130), `%${term}%`));
    const result = await request.query(statement);
    return formatKnowledgeResults(config, query, (result.recordset ?? []) as Record<string, unknown>[]);
  } catch (error) {
    if (error instanceof BrokerError) throw error;
    throw new BrokerError(502, 'knowledge_query_failed');
  } finally {
    await pool.close().catch(() => undefined);
  }
}

export function tableListStatement(): string {
  return "SELECT TABLE_SCHEMA AS [schema], TABLE_NAME AS [name], TABLE_TYPE AS [type] FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA NOT IN ('sys', 'INFORMATION_SCHEMA') ORDER BY TABLE_SCHEMA, TABLE_NAME";
}