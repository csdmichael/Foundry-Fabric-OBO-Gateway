targetScope = 'resourceGroup'

@minLength(36)
@maxLength(36)
type guidString = string

param entraApiClientId guidString

param brokerAudience guidString

param apimPrincipalId guidString

@minLength(1)
param allowedConnectorClientIds guidString[]

@minLength(1)
param allowedUserObjectIds guidString[]

output generatedIdentityInputsValidated bool = !empty(entraApiClientId) && !empty(brokerAudience) && !empty(apimPrincipalId) && length(allowedConnectorClientIds) > 0 && length(allowedUserObjectIds) > 0
