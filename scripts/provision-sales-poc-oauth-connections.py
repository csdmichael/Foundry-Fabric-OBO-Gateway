import urllib.request
import json
import subprocess

cmd = ['az.cmd', 'account', 'get-access-token', '--resource', 'https://management.azure.com/', '--query', 'accessToken', '-o', 'tsv']
token = subprocess.check_output(cmd, text=True, shell=True).strip()

base_url = 'https://management.azure.com/subscriptions/cf824570-a8ba-497a-a184-0a52f1830aa9/resourceGroups/m365-myaacoub/providers/Microsoft.CognitiveServices/accounts/foundry-myaacoub-private/projects/sales-poc/connections'
api_version = '2025-04-01-preview'

tenant_id = '12a4b86b-e64c-43f9-af05-d9130a72dfd2'
resource_client_id = '3a9e9b7d-7354-4efd-b724-d9f566c67fd1'
auth_url = f'https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/authorize'
token_url = f'https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token'
scopes = [f'api://{resource_client_id}/Fabric.Access', 'offline_access']

# Also add the APIM subscription key
sub_key = '3a2a67b71452425f98f2828b3ef49f45'

# Resolve secrets dynamically at runtime from existing connection stores or CLI parameters
def get_secret(connection_name):
    cmd_secret = ['az.cmd', 'rest', '--method', 'post', '--uri',
                  f'https://management.azure.com/subscriptions/cf824570-a8ba-497a-a184-0a52f1830aa9/resourceGroups/m365-myaacoub/providers/Microsoft.CognitiveServices/accounts/foundry-fabric-costops/projects/fabric-costops/connections/{connection_name}/listSecrets?api-version=2025-04-01-preview',
                  '--query', 'properties.credentials.clientSecret', '-o', 'tsv']
    return subprocess.check_output(cmd_secret, text=True, shell=True).strip()

connections = [
    {
        'name': 'fabric-lakehouse-mcp-oauth',
        'target': 'https://caldova-apim-westus.azure-api.net/fabric-lakehouse-mcp/mcp',
        'client_id': '891ecc94-92de-410d-b5ef-240e39e2d0d2',
        'source_conn': 'lakehouse-mcp-oauth'
    },
    {
        'name': 'fabric-data-agent-mcp-oauth',
        'target': 'https://caldova-apim-westus.azure-api.net/fabric-data-agent-mcp/mcp',
        'client_id': 'ba167cf4-9cb5-4ecf-93ed-d22dd987a466',
        'source_conn': 'data-agent-mcp-oauth'
    }
]

created = {}
for conn in connections:
    name = conn['name']
    client_secret = get_secret(conn['source_conn'])
    url = f"{base_url}/{name}?api-version={api_version}"
    body = {
        'properties': {
            'category': 'RemoteTool',
            'authType': 'OAuth2',
            'target': conn['target'],
            'isSharedToAll': True,
            'metadata': {
                'type': 'custom_MCP',
                'customHeaders': json.dumps({'Ocp-Apim-Subscription-Key': sub_key})
            },
            'authorizationUrl': auth_url,
            'tokenUrl': token_url,
            'refreshUrl': token_url,
            'scopes': scopes,
            'credentials': {
                'clientId': conn['client_id'],
                'clientSecret': client_secret
            }
        }
    }
    data = json.dumps(body).encode('utf-8')
    req = urllib.request.Request(url, data=data, method='PUT')
    req.add_header('Authorization', f'Bearer {token}')
    req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req) as resp:
            res = json.loads(resp.read().decode('utf-8'))
            conn_id = res['id']
            redirect_url = res.get('properties', {}).get('redirectUrl')
            print(f"Successfully created OAuth connection: {name} -> {conn_id} (redirectUrl: {redirect_url})")
            created[name] = {
                'id': conn_id,
                'redirectUrl': redirect_url
            }
    except urllib.error.HTTPError as e:
        print(f"Failed {name}: HTTP {e.code} - {e.read().decode('utf-8')}")

with open('.generated/sales-poc-oauth-connections.json', 'w', encoding='utf-8') as f:
    json.dump(created, f, indent=2)
