import unittest
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