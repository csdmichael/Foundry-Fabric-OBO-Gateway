import assert from 'node:assert/strict';
import { test } from 'node:test';
import { generateKeyPair, SignJWT, type JWTPayload } from 'jose';
import { createTokenVerifier } from '../src/auth.js';
import type { BrokerConfig } from '../src/config.js';
import { BrokerError } from '../src/errors.js';

const config = {
  resourceTenantId: '11111111-1111-4111-8111-111111111111',
  callerTenantId: '22222222-2222-4222-8222-222222222222',
  apiClientId: '33333333-3333-4333-8333-333333333333',
  brokerAudience: '44444444-4444-4444-8444-444444444444',
  brokerRole: 'Fabric.Broker.Invoke',
  apimPrincipalId: '55555555-5555-4555-8555-555555555555',
  connectorClientIds: ['66666666-6666-4666-8666-666666666666'],
  allowedUserObjectIds: ['77777777-7777-4777-8777-777777777777'],
  delegatedScope: 'Fabric.Access',
  jwkFetchTimeoutMs: 5000,
} as BrokerConfig;

const callerKeys = await generateKeyPair('RS256');
const userKeys = await generateKeyPair('RS256');

function sign(payload: JWTPayload, tenantId: string, audience: string, privateKey: CryptoKey) {
  return new SignJWT({ tid: tenantId, ...payload }).setProtectedHeader({ alg: 'RS256' })
    .setIssuer(`https://login.microsoftonline.com/${tenantId}/v2.0`).setAudience(audience)
    .setIssuedAt().setNotBefore('0s').setExpirationTime('5m').sign(privateKey);
}

test('accepts only the configured Caldova APIM role and Fabric delegated user', async () => {
  const caller = await sign({ oid: config.apimPrincipalId, roles: [config.brokerRole] }, config.callerTenantId, `api://${config.brokerAudience}`, callerKeys.privateKey);
  const user = await sign({ oid: config.allowedUserObjectIds[0], azp: config.connectorClientIds[0], scp: config.delegatedScope }, config.resourceTenantId, config.apiClientId, userKeys.privateKey);
  const verify = createTokenVerifier(config, { caller: async () => callerKeys.publicKey, user: async () => userKeys.publicKey });
  const identity = await verify(`Bearer ${caller}`, user);
  assert.equal(identity.objectId, config.allowedUserObjectIds[0]);
});

test('rejects the wrong APIM, role, connector, user, scope, or tenant', async () => {
  const verify = createTokenVerifier(config, { caller: async () => callerKeys.publicKey, user: async () => userKeys.publicKey });
  const validCaller = { oid: config.apimPrincipalId, roles: [config.brokerRole] };
  const validUser = { oid: config.allowedUserObjectIds[0], azp: config.connectorClientIds[0], scp: config.delegatedScope };
  const cases = [
    [await sign({ ...validCaller, oid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, config.callerTenantId, config.brokerAudience, callerKeys.privateKey), await sign(validUser, config.resourceTenantId, config.apiClientId, userKeys.privateKey)],
    [await sign({ ...validCaller, roles: ['Other.Role'] }, config.callerTenantId, config.brokerAudience, callerKeys.privateKey), await sign(validUser, config.resourceTenantId, config.apiClientId, userKeys.privateKey)],
    [await sign(validCaller, config.callerTenantId, config.brokerAudience, callerKeys.privateKey), await sign({ ...validUser, azp: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, config.resourceTenantId, config.apiClientId, userKeys.privateKey)],
    [await sign(validCaller, config.callerTenantId, config.brokerAudience, callerKeys.privateKey), await sign({ ...validUser, oid: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, config.resourceTenantId, config.apiClientId, userKeys.privateKey)],
    [await sign(validCaller, config.callerTenantId, config.brokerAudience, callerKeys.privateKey), await sign({ ...validUser, scp: 'Other.Scope' }, config.resourceTenantId, config.apiClientId, userKeys.privateKey)],
    [await sign(validCaller, config.callerTenantId, config.brokerAudience, callerKeys.privateKey), await sign(validUser, config.callerTenantId, config.apiClientId, userKeys.privateKey)],
  ];
  for (const [caller, user] of cases) {
    await assert.rejects(verify(`Bearer ${caller}`, user), (error: unknown) => error instanceof BrokerError && error.status === 401);
  }
});