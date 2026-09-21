from typing import Any

import httpx
from azure.ai.projects.models import (
    AutoCodeInterpreterToolParam,
    CodeInterpreterTool,
    FabricDataAgentToolParameters,
    MCPTool,
    MicrosoftFabricPreviewTool,
    ToolProjectConnection,
)


CONNECTION_API_VERSION = "2025-10-01-preview"
FABRIC_CONNECTION_API_VERSION = "2025-04-01-preview"
KNOWLEDGE_BASE_API_VERSION = "2026-08-01-preview"


def knowledge_base_mcp_endpoint(search_endpoint: str, knowledge_base_name: str) -> str:
    return (
        f"{search_endpoint.rstrip('/')}/knowledgebases/{knowledge_base_name}/mcp"
        f"?api-version={KNOWLEDGE_BASE_API_VERSION}"
    )


def ensure_foundry_iq_connection(
    credential: Any,
    project_resource_id: str,
    connection_name: str,
    search_endpoint: str,
    knowledge_base_name: str,
    http_client: Any = httpx,
) -> dict:
    mcp_endpoint = knowledge_base_mcp_endpoint(search_endpoint, knowledge_base_name)
    token = credential.get_token("https://management.azure.com/.default").token
    connection_url = (
        f"https://management.azure.com{project_resource_id.rstrip('/')}"
        f"/connections/{connection_name}?api-version={CONNECTION_API_VERSION}"
    )
    payload = {
        "name": connection_name,
        "type": "Microsoft.MachineLearningServices/workspaces/connections",
        "properties": {
            "authType": "ProjectManagedIdentity",
            "category": "RemoteTool",
            "target": mcp_endpoint,
            "isSharedToAll": True,
            "audience": "https://search.azure.com/",
            "metadata": {"ApiType": "Azure"},
        },
    }
    response = http_client.put(
        connection_url,
        headers={"Authorization": f"Bearer {token}"},
        json=payload,
        timeout=60,
    )
    response.raise_for_status()
    connection = response.json()
    if not connection.get("id"):
        raise RuntimeError(f"Foundry IQ connection '{connection_name}' returned no resource ID.")
    return connection


def ensure_fabric_data_agent_connection(
    credential: Any,
    project_resource_id: str,
    connection_name: str,
    workspace_id: str,
    artifact_id: str,
    http_client: Any = httpx,
) -> dict:
    token = credential.get_token("https://management.azure.com/.default").token
    connection_url = (
        f"https://management.azure.com{project_resource_id.rstrip('/')}"
        f"/connections/{connection_name}?api-version={FABRIC_CONNECTION_API_VERSION}"
    )
    response = http_client.put(
        connection_url,
        headers={"Authorization": f"Bearer {token}"},
        json={
            "properties": {
                "category": "CustomKeys",
                "authType": "CustomKeys",
                "target": "_",
                "isSharedToAll": False,
                "sharedUserList": [],
                "metadata": {
                    "type": "fabric_dataagent",
                },
                "credentials": {
                    "keys": {
                        "workspace-id": workspace_id,
                        "artifact-id": artifact_id,
                    },
                },
            },
        },
        timeout=60,
    )
    response.raise_for_status()
    connection = response.json()
    if not connection.get("id"):
        raise RuntimeError(f"Fabric Data Agent connection '{connection_name}' returned no resource ID.")
    return connection


def build_fabric_data_agent_tool(connection_id: str) -> MicrosoftFabricPreviewTool:
    return MicrosoftFabricPreviewTool(
        fabric_dataagent_preview=FabricDataAgentToolParameters(
            project_connections=[ToolProjectConnection(project_connection_id=connection_id)],
        ),
    )


def build_foundry_iq_capabilities(
    connection_id: str,
    search_endpoint: str,
    knowledge_base_name: str,
    server_label: str = "parts-shortages-knowledge",
) -> tuple[list[Any], dict]:
    mcp_endpoint = knowledge_base_mcp_endpoint(search_endpoint, knowledge_base_name)
    knowledge = MCPTool(
        server_label=server_label,
        server_url=mcp_endpoint,
        project_connection_id=connection_id,
        allowed_tools=["knowledge_base_retrieve"],
        require_approval="never",
    )
    code_interpreter = CodeInterpreterTool(container=AutoCodeInterpreterToolParam(file_ids=[]))
    return [knowledge, code_interpreter], {
        "type": "foundry_iq",
        "knowledgeBaseName": knowledge_base_name,
        "searchEndpoint": search_endpoint.rstrip("/"),
        "mcpEndpoint": mcp_endpoint,
        "projectConnectionId": connection_id,
    }