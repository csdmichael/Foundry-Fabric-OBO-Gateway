import sys
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from foundry_knowledge import (
    build_fabric_data_agent_tool,
    build_foundry_iq_capabilities,
    ensure_fabric_data_agent_connection,
    ensure_foundry_iq_connection,
    build_private_mcp_tool,
    load_private_mcp_connections,
)


class FakeCredential:
    def get_token(self, scope):
        if scope != "https://management.azure.com/.default":
            raise AssertionError(f"Unexpected token scope: {scope}")
        return SimpleNamespace(token="management-token")


class FakeResponse:
    def raise_for_status(self):
        return None

    def json(self):
        return {
            "id": "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/account/projects/project/connections/parts-shortages-kb",
            "name": "parts-shortages-kb",
        }


class FakeHttpClient:
    def __init__(self):
        self.requests = []

    def put(self, url, *, headers, json, timeout):
        self.requests.append({
            "url": url,
            "headers": headers,
            "json": json,
            "timeout": timeout,
        })
        return FakeResponse()


class FoundryKnowledgeTests(unittest.TestCase):
    def test_loads_only_ready_private_mcp_connections_matching_config(self):
        foundry_config = {
            "mcpConnections": {
                "lakehouse": {
                    "name": "lakehouse-mcp-oauth",
                    "apiPath": "fabric-lakehouse-mcp/mcp",
                },
                "dataAgent": {
                    "name": "data-agent-mcp-oauth",
                    "apiPath": "fabric-data-agent-mcp/mcp",
                },
            },
        }
        checkpoint = {
            "schemaVersion": 1,
            "status": "ready",
            "connections": [
                {
                    "kind": "lakehouse",
                    "id": "/projects/p/connections/lakehouse-mcp-oauth",
                    "name": "lakehouse-mcp-oauth",
                    "target": "https://gateway.azure-api.net/fabric-lakehouse-mcp/mcp",
                },
                {
                    "kind": "dataAgent",
                    "id": "/projects/p/connections/data-agent-mcp-oauth",
                    "name": "data-agent-mcp-oauth",
                    "target": "https://gateway.azure-api.net/fabric-data-agent-mcp/mcp",
                },
            ],
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "connections.json"
            path.write_text(json.dumps(checkpoint), encoding="utf-8")
            connections = load_private_mcp_connections(
                path,
                foundry_config,
                "https://gateway.azure-api.net",
            )

        self.assertEqual(set(connections), {"lakehouse", "dataAgent"})
        self.assertEqual(connections["dataAgent"]["name"], "data-agent-mcp-oauth")

    def test_rejects_private_mcp_connection_for_wrong_tenant_target(self):
        foundry_config = {
            "mcpConnections": {
                "lakehouse": {"name": "lakehouse", "apiPath": "lakehouse/mcp"},
                "dataAgent": {"name": "data-agent", "apiPath": "data-agent/mcp"},
            },
        }
        checkpoint = {
            "schemaVersion": 1,
            "status": "ready",
            "connections": [
                {"kind": "lakehouse", "id": "one", "name": "lakehouse", "target": "https://wrong.example/mcp"},
                {"kind": "dataAgent", "id": "two", "name": "data-agent", "target": "https://gateway.azure-api.net/data-agent/mcp"},
            ],
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "connections.json"
            path.write_text(json.dumps(checkpoint), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "does not match deployment config"):
                load_private_mcp_connections(path, foundry_config, "https://gateway.azure-api.net")

    def test_builds_private_oauth_mcp_tool_with_least_privilege_allowlist(self):
        tool = build_private_mcp_tool(
            {
                "id": "/projects/p/connections/lakehouse",
                "target": "https://gateway.azure-api.net/lakehouse/mcp",
            },
            "fabric-lakehouse",
            ["tables", "query"],
        )

        self.assertEqual(tool.type, "mcp")
        self.assertEqual(tool.project_connection_id, "/projects/p/connections/lakehouse")
        self.assertEqual(tool.server_url, "https://gateway.azure-api.net/lakehouse/mcp")
        self.assertEqual(tool.allowed_tools, ["tables", "query"])
        self.assertEqual(tool.require_approval, "never")

    def test_creates_native_fabric_data_agent_connection(self):
        client = FakeHttpClient()

        connection = ensure_fabric_data_agent_connection(
            credential=FakeCredential(),
            project_resource_id="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/account/projects/project",
            connection_name="parts-shortages-data-agent",
            workspace_id="53829079-597d-4c27-9897-6a2042473761",
            artifact_id="25696ea2-a91e-4b18-9846-5d045c6a082e",
            http_client=client,
        )

        self.assertEqual(connection["name"], "parts-shortages-kb")
        request = client.requests[0]
        self.assertEqual(request["json"]["properties"]["category"], "CustomKeys")
        self.assertEqual(request["json"]["properties"]["authType"], "CustomKeys")
        self.assertEqual(request["json"]["properties"]["target"], "_")
        self.assertEqual(request["json"]["properties"]["metadata"], {"type": "fabric_dataagent"})
        self.assertEqual(request["json"]["properties"]["credentials"]["keys"], {
            "workspace-id": "53829079-597d-4c27-9897-6a2042473761",
            "artifact-id": "25696ea2-a91e-4b18-9846-5d045c6a082e",
        })

    def test_builds_portal_recognized_fabric_data_agent_tool(self):
        tool = build_fabric_data_agent_tool("/projects/project/connections/parts-shortages-data-agent")

        self.assertEqual(tool.type, "fabric_dataagent_preview")
        self.assertEqual(
            tool.fabric_dataagent_preview.project_connections[0].project_connection_id,
            "/projects/project/connections/parts-shortages-data-agent",
        )
        self.assertNotIn("additional_properties", tool.as_dict())

    def test_creates_project_managed_identity_knowledge_connection(self):
        client = FakeHttpClient()

        connection = ensure_foundry_iq_connection(
            credential=FakeCredential(),
            project_resource_id="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/account/projects/project",
            connection_name="parts-shortages-kb",
            search_endpoint="https://search.search.windows.net/",
            knowledge_base_name="parts-shortages-lakehouse-kb",
            http_client=client,
        )

        self.assertEqual(connection["name"], "parts-shortages-kb")
        self.assertEqual(len(client.requests), 1)
        request = client.requests[0]
        self.assertEqual(
            request["url"],
            "https://management.azure.com/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/account/projects/project/connections/parts-shortages-kb?api-version=2025-10-01-preview",
        )
        self.assertEqual(request["headers"]["Authorization"], "Bearer management-token")
        self.assertEqual(request["json"]["properties"]["category"], "RemoteTool")
        self.assertEqual(request["json"]["properties"]["authType"], "ProjectManagedIdentity")
        self.assertEqual(request["json"]["properties"]["audience"], "https://search.azure.com/")
        self.assertEqual(
            request["json"]["properties"]["target"],
            "https://search.search.windows.net/knowledgebases/parts-shortages-lakehouse-kb/mcp?api-version=2026-08-01-preview",
        )

    def test_capabilities_use_only_native_knowledge_retrieval_and_code_interpreter(self):
        tools, metadata = build_foundry_iq_capabilities(
            connection_id="parts-shortages-kb",
            search_endpoint="https://search.search.windows.net",
            knowledge_base_name="parts-shortages-lakehouse-kb",
        )

        self.assertEqual([tool.type for tool in tools], ["mcp", "code_interpreter"])
        self.assertEqual(tools[0].server_label, "parts-shortages-knowledge")
        self.assertEqual(tools[0].allowed_tools, ["knowledge_base_retrieve"])
        self.assertEqual(tools[0].project_connection_id, "parts-shortages-kb")
        self.assertEqual(
            tools[0].server_url,
            "https://search.search.windows.net/knowledgebases/parts-shortages-lakehouse-kb/mcp?api-version=2026-08-01-preview",
        )
        self.assertNotIn("file_search", [tool.type for tool in tools])
        self.assertEqual(metadata["type"], "foundry_iq")
        self.assertEqual(metadata["knowledgeBaseName"], "parts-shortages-lakehouse-kb")


if __name__ == "__main__":
    unittest.main()