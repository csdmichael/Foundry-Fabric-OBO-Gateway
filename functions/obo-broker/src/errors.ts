export class BrokerError extends Error {
  constructor(public readonly status: number, public readonly code: string) {
    super(code);
  }
}

export function safeError(error: unknown): BrokerError {
  return error instanceof BrokerError ? error : new BrokerError(503, 'broker_unavailable');
}