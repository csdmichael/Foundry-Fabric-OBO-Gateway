import json
from pathlib import Path
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


def load_private_mcp_connections(
    metadata_path: Path,
    foundry_config: dict[str, Any],
    gateway_url: str,
) -> dict[str, dict[str, str]]:
    document = json.loads(metadata_path.read_text(encoding="utf-8-sig"))
    if document.get("schemaVersion") != 1 or document.get("status") != "ready":
        raise ValueError("Foundry private MCP connection checkpoint is not ready.")

    connections = document.get("connections")
    if not isinstance(connections, list):
        raise ValueError("Foundry private MCP connection checkpoint has no connection list.")

    expected_kinds = {"lakehouse", "dataAgent"}
    by_kind: dict[str, dict[str, str]] = {}
    for connection in connections:
        kind = connection.get("kind")
        if kind not in expected_kinds or kind in by_kind:
            raise ValueError("Foundry private MCP connections must contain each agent kind exactly once.")
        config = foundry_config["mcpConnections"][kind]
        expected_target = f"{gateway_url.rstrip('/')}/{config['apiPath'].lstrip('/')}"
        if (
            connection.get("name") != config["name"]
            or connection.get("target") != expected_target
            or not connection.get("id")
        ):
            raise ValueError(f"Foundry private MCP connection '{kind}' does not match deployment config.")
        by_kind[kind] = connection

    if set(by_kind) != expected_kinds:
        raise ValueError("Foundry private MCP connections must contain lakehouse and dataAgent.")
    return by_kind


def build_private_mcp_tool(
    connection: dict[str, str],
    server_label: str,
    allowed_tools: list[str],
) -> MCPTool:
    if not allowed_tools:
        raise ValueError("Private MCP tool allowlist cannot be empty.")
    return MCPTool(
        server_label=server_label,
        server_url=connection["target"],
        project_connection_id=connection["id"],
        allowed_tools=allowed_tools,
        require_approval="never",
    )


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