import assert from 'node:assert/strict';
import { test } from 'node:test';
import { dataAgentMcpUrl, downstreamScope, loadConfig } from '../src/config.js';

const environment = {
  RESOURCE_TENANT_ID: '11111111-1111-4111-8111-111111111111',
  CALLER_TENANT_ID: '22222222-2222-4222-8222-222222222222',
  ENTRA_API_CLIENT_ID: '33333333-3333-4333-8333-333333333333',
  OBO_CLIENT_SECRET: 'test',
  BROKER_AUDIENCE: '44444444-4444-4444-8444-444444444444',
  BROKER_APPLICATION_ROLE: 'Fabric.Broker.Invoke',
  APIM_PRINCIPAL_ID: '55555555-5555-4555-8555-555555555555',
  ALLOWED_CONNECTOR_CLIENT_IDS: '66666666-6666-4666-8666-666666666666',
  ALLOWED_USER_OBJECT_IDS: '77777777-7777-4777-8777-777777777777',
  DELEGATED_SCOPE: 'Fabric.Access',
  FABRIC_API_SCOPE: 'https://api.fabric.microsoft.com/.default',
  POWER_BI_API_SCOPE: 'https://analysis.windows.net/powerbi/api/.default',
  FABRIC_WORKSPACE_ID: '88888888-8888-4888-8888-888888888888',
  FABRIC_LAKEHOUSE_NAME: 'lakehouse',
  FABRIC_SQL_ENDPOINT_HOST: 'example.datawarehouse.fabric.microsoft.com',
  FABRIC_DATA_AGENT_ID: '99999999-9999-4999-8999-999999999999',
  JWK_FETCH_TIMEOUT_MS: '5000', TOKEN_EXCHANGE_TIMEOUT_MS: '15000',
  SQL_CONNECT_TIMEOUT_MS: '30000', SQL_REQUEST_TIMEOUT_MS: '120000',
  MAX_ROWS: '1000', MAX_STATEMENT_LENGTH: '10000',
  MANAGED_IDENTITY_CLIENT_ID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  LOG_ANALYTICS_WORKSPACE_ID: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  TOKENOMICS_APIM_API_IDS: 'fabric-lakehouse-obo,fabric-data-agent-obo',
  TOKENOMICS_API_ATTRIBUTION_JSON: '{"fabric-data-agent-obo":"fabric-data-agent-costops"}',
  TOKENOMICS_PROJECT_ID: 'fabric-parts-shortages',
  TOKENOMICS_TEAM_ID: 'unassigned',
  TOKENOMICS_COST_CENTER: 'unassigned',
  TOKENOMICS_CURRENCY: 'USD',
  TOKENOMICS_RATE_CARD_JSON: '[]',
  ACTUAL_COST_ENABLED: 'true',
  ACTUAL_COST_SCOPE: '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourceGroups/costops',
  ACTUAL_COST_QUERY_API_VERSION: '2023-11-01',
  ACTUAL_COST_BILLING_LAG_HOURS: '24',
  ACTUAL_COST_TRACKED_RESOURCES_JSON: '[{"category":"model","resourceId":"/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourceGroups/costops/providers/Microsoft.CognitiveServices/accounts/foundry-costops","shared":false}]',
};

test('loads only the approved Fabric endpoints and scopes', () => {
  const config = loadConfig(environment);
  assert.equal(downstreamScope(config, 'fabric'), environment.FABRIC_API_SCOPE);
  assert.equal(downstreamScope(config, 'powerbi'), environment.POWER_BI_API_SCOPE);
  assert.equal(dataAgentMcpUrl(config), `https://api.fabric.microsoft.com/v1/mcp/workspaces/${environment.FABRIC_WORKSPACE_ID}/dataagents/${environment.FABRIC_DATA_AGENT_ID}/agent`);
  assert.throws(() => loadConfig({ ...environment, FABRIC_SQL_ENDPOINT_HOST: 'evil.example' }));
  assert.throws(() => loadConfig({ ...environment, FABRIC_API_SCOPE: 'https://graph.microsoft.com/.default' }));
  assert.throws(() => loadConfig({ ...environment, ALLOWED_USER_OBJECT_IDS: '' }));
  assert.throws(() => loadConfig({ ...environment, ACTUAL_COST_SCOPE: '/subscriptions/invalid' }));
  assert.throws(() => loadConfig({ ...environment, ACTUAL_COST_TRACKED_RESOURCES_JSON: '[]' }));
});