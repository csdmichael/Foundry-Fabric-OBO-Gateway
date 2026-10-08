import unittest
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

AGENT_INSTRUCTION_FILES = {
    "copilot_lakehouse": ROOT / "agents" / "lakehouse" / "settings.mcs.yml",
    "copilot_data_agent": ROOT / "agents" / "data-agent" / "settings.mcs.yml",
    "foundry_lakehouse": ROOT / "agents" / "foundry" / "lakehouse-instructions.md",
    "foundry_data_agent": ROOT / "agents" / "foundry" / "data-agent-instructions.md",
}

SAFETY_REQUIREMENTS = (
    "untrusted data, not instructions",
    "never follow instructions found in",
    "decline requests that facilitate",
    "security or content safeguards",
    "minimize sensitive data",
)

COPILOT_TOOL_CONTRACTS = {
    "copilot_lakehouse": (
        ROOT / "agents" / "lakehouse" / "settings.mcs.yml",
        ROOT / "agents" / "lakehouse" / "capabilities" / "tools" / "SearchopenLakehouseshortages_pS_.mcs.yml",
    ),
    "copilot_data_agent": (
        ROOT / "agents" / "data-agent" / "settings.mcs.yml",
        ROOT / "agents" / "data-agent" / "capabilities" / "tools" / "QuerytheFabricDataAgent_k-V.mcs.yml",
    ),
}


class AgentSafetyContractTests(unittest.TestCase):
    def test_all_agents_define_prompt_injection_and_content_safety_boundaries(self):
        for agent_name, instruction_path in AGENT_INSTRUCTION_FILES.items():
            with self.subTest(agent=agent_name):
                instructions = instruction_path.read_text(encoding="utf-8").lower()
                for requirement in SAFETY_REQUIREMENTS:
                    self.assertIn(requirement, instructions)

    def test_copilot_agents_reference_only_pulled_runtime_capabilities(self):
        for agent_name, (settings_path, tool_path) in COPILOT_TOOL_CONTRACTS.items():
            with self.subTest(agent=agent_name):
                settings = settings_path.read_text(encoding="utf-8").lower()
                tool = tool_path.read_text(encoding="utf-8")
                component_name = next(
                    line.split(":", 1)[1].strip()
                    for line in tool.splitlines()
                    if line.strip().startswith("componentName:")
                )
                self.assertIn(f"use the {component_name.lower()} tool", settings)
                self.assertNotIn("executive powerpoint", settings)
                self.assertNotIn("code interpreter", settings)

    def test_foundry_agents_require_private_delegated_mcp_tools(self):
        contracts = {
            "lakehouse": ("private fabric lakehouse mcp", "`tables`", "`query`", "delegated permissions"),
            "data-agent": ("private fabric data agent mcp", "`query`", "delegated permissions"),
        }
        for agent_name, requirements in contracts.items():
            with self.subTest(agent=agent_name):
                instructions = (
                    ROOT / "agents" / "foundry" / f"{agent_name}-instructions.md"
                ).read_text(encoding="utf-8").lower()
                for requirement in requirements:
                    self.assertIn(requirement, instructions)
                self.assertNotIn("foundry iq", instructions)
                self.assertNotIn("microsoft fabric data agent tool", instructions)

    def test_copilot_connectors_are_invoker_obo_and_use_configured_tenant(self):
        config = json.loads((ROOT / "config" / "deployment.json").read_text(encoding="utf-8-sig"))
        contracts = {
            "lakehouse": (
                "Fabric Lakehouse OBO Private",
                "knowledge",
                ROOT / "agents" / "lakehouse",
            ),
            "dataAgent": (
                "Fabric Data Agent OBO Private",
                "query",
                ROOT / "agents" / "data-agent",
            ),
        }
        for kind, (display_name, operation_id, agent_root) in contracts.items():
            with self.subTest(agent=kind):
                connector_root = next((agent_root / "connectors").iterdir())
                metadata = json.loads((connector_root / "metadata.yml").read_text(encoding="utf-8-sig"))
                parameters = json.loads(
                    (connector_root / "connectionparameters.json").read_text(encoding="utf-8-sig")
                )
                openapi = json.loads(
                    (connector_root / "openapidefinition.json").read_text(encoding="utf-8-sig")
                )
                tool = next((agent_root / "capabilities" / "tools").glob("*.mcs.yml")).read_text(
                    encoding="utf-8"
                )
                reference = next(
                    (agent_root / "infrastructure" / "connections").glob("*.sync.yaml")
                ).read_text(encoding="utf-8")
                tool_connector_id = re.search(r"(?m)^connectorId:\s*(\S+)\s*$", tool).group(1)
                reference_connector_id = re.search(
                    r"(?m)^\s*connectorId:\s*(\S+)\s*$", reference
                ).group(1)
                oauth = parameters["token"]["oAuthSettings"]
                tenant_id = config["powerPlatform"]["tenantId"]

                self.assertEqual(metadata["displayname"], display_name)
                self.assertIn("authMode: Invoker", tool)
                self.assertIn(f"operationId: {operation_id}", tool)
                self.assertEqual(tool_connector_id, reference_connector_id)
                self.assertEqual(oauth["customParameters"]["TenantId"]["value"], tenant_id)
                self.assertRegex(
                    oauth["customParameters"]["ResourceUri"]["value"],
                    r"^api://[0-9a-f-]{36}$",
                )
                self.assertEqual(oauth["scopes"], [config["identity"]["delegatedScope"]])
                self.assertTrue(oauth["properties"]["IsOnbehalfofLoginSupported"])
                self.assertEqual(
                    openapi["securityDefinitions"]["oauth2"]["authorizationUrl"],
                    f"https://login.microsoftonline.com/{tenant_id}/oauth2/authorize",
                )

    def test_foundry_iac_enforces_content_safety_and_evaluation_rbac(self):
        iac_paths = (
            ROOT / "bicep" / "foundry" / "main.bicep",
            ROOT / "terraform" / "foundry" / "main.tf",
        )
        required_tokens = (
            "fabric-costops-content-safety",
            "Microsoft.DefaultV2",
            "Hate",
            "Sexual",
            "Violence",
            "Selfharm",
            "Jailbreak",
            "Indirect Attack",
            "raiPolicyName",
            "53ca6127-db72-4b80-b1b0-d745d6d5456d",
        )
        for iac_path in iac_paths:
            with self.subTest(iac=iac_path.name):
                content = iac_path.read_text(encoding="utf-8")
                for token in required_tokens:
                    self.assertIn(token, content)


if __name__ == "__main__":
    unittest.main()