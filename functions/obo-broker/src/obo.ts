import { ConfidentialClientApplication, type AuthenticationResult } from '@azure/msal-node';
import type { BrokerConfig, DownstreamTarget } from './config.js';
import { downstreamScope } from './config.js';
import { BrokerError } from './errors.js';

export interface ExchangedToken {
  accessToken: string;
  expiresIn: number;
}

export interface OboClient {
  acquireTokenOnBehalfOf(request: { oboAssertion: string; scopes: string[]; skipCache: boolean }): Promise<AuthenticationResult | null>;
}

function diagnosticValue(value: unknown): string {
  return typeof value === 'string' && /^[A-Za-z0-9_.-]{1,128}$/.test(value) ? value : 'unknown';
}

export function createOboClient(config: BrokerConfig): OboClient {
  return new ConfidentialClientApplication({
    auth: {
      clientId: config.apiClientId,
      clientSecret: config.apiClientSecret,
      authority: `https://login.microsoftonline.com/${config.resourceTenantId}`,
    },
    system: { networkClient: undefined },
  });
}

export function createTokenExchanger(config: BrokerConfig, client = createOboClient(config)) {
  return async (userAssertion: string, target: DownstreamTarget, userExpiresAt: number): Promise<ExchangedToken> => {
    let result: AuthenticationResult | null;
    try {
      result = await Promise.race([
        client.acquireTokenOnBehalfOf({
          oboAssertion: userAssertion,
          scopes: [downstreamScope(config, target)],
          skipCache: true,
        }),
        new Promise<never>((_, reject) => setTimeout(() => reject(new Error('OBO timeout')), config.tokenExchangeTimeoutMs)),
      ]);
    } catch (error) {
      const details = error as { errorCode?: unknown; subError?: unknown; correlationId?: unknown };
      console.warn(JSON.stringify({
        event: 'fabric_obo_exchange_rejected',
        errorCode: diagnosticValue(details.errorCode),
        subError: diagnosticValue(details.subError),
        correlationId: diagnosticValue(details.correlationId),
      }));
      throw new BrokerError(403, 'exchange_rejected');
    }
    if (!result?.accessToken || /[\r\n]/.test(result.accessToken) || result.accessToken.length > 32768) {
      throw new BrokerError(502, 'invalid_exchange_response');
    }
    const downstreamExpiry = result.expiresOn ? Math.floor(result.expiresOn.getTime() / 1000) : userExpiresAt;
    const expiresIn = Math.min(downstreamExpiry, userExpiresAt) - Math.ceil(Date.now() / 1000);
    if (expiresIn <= 0) throw new BrokerError(502, 'invalid_exchange_response');
    return { accessToken: result.accessToken, expiresIn };
  };
}