import { createRemoteJWKSet, jwtVerify, type JWTPayload, type JWTVerifyGetKey } from 'jose';
import type { BrokerConfig } from './config.js';
import { BrokerError } from './errors.js';

export interface VerifiedIdentity {
  objectId: string;
  applicationId: string;
  expiresAt: number;
}

export interface SigningKeys {
  caller: JWTVerifyGetKey;
  user: JWTVerifyGetKey;
}

function bearer(value: string): string {
  if (!value.startsWith('Bearer ')) throw new BrokerError(401, 'invalid_token');
  const token = value.slice(7);
  if (!token || token.length > 32768 || /[\r\n]/.test(token)) throw new BrokerError(401, 'invalid_token');
  return token;
}

function claimList(payload: JWTPayload, name: string): string[] {
  const value = payload[name];
  if (Array.isArray(value)) return value.filter((item): item is string => typeof item === 'string');
  return typeof value === 'string' ? value.split(' ').filter(Boolean) : [];
}

function stringClaim(payload: JWTPayload, name: string): string {
  const value = payload[name];
  return typeof value === 'string' ? value : '';
}

export function createSigningKeys(config: BrokerConfig): SigningKeys {
  const options = { timeoutDuration: config.jwkFetchTimeoutMs };
  return {
    caller: createRemoteJWKSet(new URL(`https://login.microsoftonline.com/${config.callerTenantId}/discovery/v2.0/keys`), options),
    user: createRemoteJWKSet(new URL(`https://login.microsoftonline.com/${config.resourceTenantId}/discovery/v2.0/keys`), options),
  };
}

export function createTokenVerifier(config: BrokerConfig, keys = createSigningKeys(config)) {
  return async (authorization: string, userAssertion: string): Promise<VerifiedIdentity> => {
    try {
      const callerToken = bearer(authorization);
      const caller = (await jwtVerify(callerToken, keys.caller, {
        issuer: [`https://sts.windows.net/${config.callerTenantId}/`, `https://login.microsoftonline.com/${config.callerTenantId}/v2.0`],
        audience: [config.brokerAudience, `api://${config.brokerAudience}`],
        algorithms: ['RS256'],
        requiredClaims: ['exp', 'iat', 'nbf', 'tid', 'oid'],
      })).payload;
        if (stringClaim(caller, 'tid').toLowerCase() !== config.callerTenantId
          || stringClaim(caller, 'oid').toLowerCase() !== config.apimPrincipalId
          || caller.scp || !claimList(caller, 'roles').includes(config.brokerRole)) {
        throw new Error('Invalid APIM caller');
      }

      const userToken = bearer(`Bearer ${userAssertion}`);
      const user = (await jwtVerify(userToken, keys.user, {
        issuer: `https://login.microsoftonline.com/${config.resourceTenantId}/v2.0`,
        audience: [config.apiClientId, `api://${config.apiClientId}`],
        algorithms: ['RS256'],
        requiredClaims: ['exp', 'iat', 'nbf', 'tid', 'oid', 'azp', 'scp'],
      })).payload;
      const objectId = stringClaim(user, 'oid').toLowerCase();
      const applicationId = stringClaim(user, 'azp').toLowerCase();
      if (stringClaim(user, 'tid').toLowerCase() !== config.resourceTenantId || user.idtyp === 'app'
          || !applicationId || !config.connectorClientIds.includes(applicationId)
          || !claimList(user, 'scp').includes(config.delegatedScope)
          || !config.allowedUserObjectIds.includes(objectId)) {
        throw new Error('Invalid delegated user');
      }
      return { objectId, applicationId, expiresAt: user.exp! };
    } catch (error) {
      if (error instanceof BrokerError) throw error;
      throw new BrokerError(401, 'invalid_token');
    }
  };
}