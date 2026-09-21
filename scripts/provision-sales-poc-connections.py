import urllib.request
import json
import subprocess

cmd = ['az.cmd', 'account', 'get-access-token', '--resource', 'https://management.azure.com/', '--query', 'accessToken', '-o', 'tsv']
token = subprocess.check_output(cmd, text=True, shell=True).strip()

base_url = 'https://management.azure.com/subscriptions/cf824570-a8ba-497a-a184-0a52f1830aa9/resourceGroups/m365-myaacoub/providers/Microsoft.CognitiveServices/accounts/foundry-myaacoub-private/projects/sales-poc/connections'
api_version = '2025-04-01-preview'
sub_key = '3a2a67b71452425f98f2828b3ef49f45'

connections = [
    {
        'name': 'fabric-lakehouse-mcp-conn',
        'target': 'https://caldova-apim-westus.azure-api.net/fabric-lakehouse-mcp/mcp',
    },
    {
        'name': 'fabric-data-agent-mcp-conn',
        'target': 'https://caldova-apim-westus.azure-api.net/fabric-data-agent-mcp/mcp',
    }
]

created_ids = {}

for conn in connections:
    name = conn['name']
    url = f"{base_url}/{name}?api-version={api_version}"
    body = {
        'properties': {
            'category': 'RemoteTool',
            'authType': 'CustomKeys',
            'target': conn['target'],
            'isSharedToAll': False,
            'metadata': {
                'type': 'custom_MCP'
            },
            'credentials': {
                'keys': {
                    'Ocp-Apim-Subscription-Key': sub_key
                }
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
            print(f"Successfully created connection: {name} -> ID: {res['id']}")
            created_ids[name] = res['id']
    except urllib.error.HTTPError as e:
        print(f"Failed to create {name}: HTTP {e.code} - {e.read().decode('utf-8')}")

with open('.generated/sales-poc-connections.json', 'w', encoding='utf-8') as f:
    json.dump(created_ids, f, indent=2)
