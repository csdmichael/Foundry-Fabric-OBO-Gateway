import argparse
import json
import time
from pathlib import Path

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import AzureCliCredential

from foundry_evaluations import load_evaluation_cases, run_managed_evaluation
from foundry_knowledge import (
    build_fabric_data_agent_tool,
    build_foundry_iq_capabilities,
    ensure_fabric_data_agent_connection,
    ensure_foundry_iq_connection,
)


def retryable(error: Exception) -> bool:
    status = getattr(error, "status_code", None)
    return status in {404, 408, 409, 424, 429, 500, 502, 503, 504} or any(
        marker in str(error).lower() for marker in ("404", "not found", "not ready", "temporarily unavailable")
    )


def create_agent(project: AIProjectClient, name: str, definition: PromptAgentDefinition):
    for attempt in range(6):
        try:
            return project.agents.create_version(agent_name=name, definition=definition)
        except Exception as error:
            if attempt == 5 or not retryable(error):
                raise
            time.sleep(5)
    raise RuntimeError("agent_create_retry_exhausted")


def smoke_test(project: AIProjectClient, agent_name: str) -> None:
    for attempt in range(6):
        try:
            with project.get_openai_client(agent_name=agent_name) as openai:
                conversation = openai.conversations.create()
                response = openai.responses.create(
                    conversation=conversation.id,
                    input="Reply with exactly READY. Do not call tools.",
                )
                if response.output_text.strip().upper() != "READY":
                    raise RuntimeError("unexpected_smoke_response")
                return
        except Exception as error:
            if attempt == 5 or not retryable(error):
                raise
            time.sleep(5)
    raise RuntimeError("agent_smoke_retry_exhausted")


def write_checkpoint(
    output_path: Path,
    project_endpoint: str,
    foundry: dict,
    agents: list[dict],
    status: str,
) -> None:
    output = {
        "schemaVersion": 1,
        "status": status,
        "projectEndpoint": project_endpoint,
        "accountName": foundry["accountName"],
        "projectName": foundry["projectName"],
        "agents": agents,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--connections", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--skip-smoke-test", action="store_true")
    parser.add_argument("--skip-evaluations", action="store_true")
    parser.add_argument("--evaluation-dataset")
    args = parser.parse_args()

    config_path = Path(args.config).resolve()
    root = config_path.parent.parent
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    foundry = config["foundry"]
    project_endpoint = f"https://{foundry['accountName']}.services.ai.azure.com/api/projects/{foundry['projectName']}"
    project_resource_id = (
        f"/subscriptions/{config['azure']['subscriptionId']}"
        f"/resourceGroups/{config['azure']['resourceGroup']}"
        f"/providers/Microsoft.CognitiveServices/accounts/{foundry['accountName']}"
        f"/projects/{foundry['projectName']}"
    )
    output_path = Path(args.output).resolve()
    evaluation_dataset_path = (
        Path(args.evaluation_dataset).resolve()
        if args.evaluation_dataset
        else root / "agents" / "foundry" / "evaluations" / "safety-quality-v1.jsonl"
    )
    evaluation_output_directory = output_path.parent / "foundry-evaluations"

    definitions = [
        {
            "kind": "lakehouse",
            "name": foundry["agents"]["lakehouse"],
            "model": f"{foundry['modelConnections']['lakehouse']}/{foundry['model']['name']}",
            "instructions": root / "agents" / "foundry" / "lakehouse-instructions.md",
        },
        {
            "kind": "dataAgent",
            "name": foundry["agents"]["dataAgent"],
            "model": f"{foundry['modelConnections']['dataAgent']}/{foundry['model']['name']}",
            "instructions": root / "agents" / "foundry" / "data-agent-instructions.md",
        },
    ]

    results = []
    write_checkpoint(output_path, project_endpoint, foundry, results, "in-progress")
    with AzureCliCredential(tenant_id=config["azure"]["tenantId"]) as credential, AIProjectClient(
        endpoint=project_endpoint,
        credential=credential,
    ) as project:
        with project.get_openai_client() as evaluation_openai:
            for item in definitions:
                if item["kind"] == "lakehouse":
                    knowledge_config = foundry["knowledgeBases"]["lakehouse"]
                    connection = ensure_foundry_iq_connection(
                        credential=credential,
                        project_resource_id=project_resource_id,
                        connection_name=knowledge_config["connectionName"],
                        search_endpoint=knowledge_config["searchEndpoint"],
                        knowledge_base_name=knowledge_config["knowledgeBaseName"],
                    )
                    tools, knowledge_source = build_foundry_iq_capabilities(
                        connection_id=connection["id"],
                        search_endpoint=knowledge_config["searchEndpoint"],
                        knowledge_base_name=knowledge_config["knowledgeBaseName"],
                        server_label=knowledge_config["serverLabel"],
                    )
                    tool_names = ["foundry_iq_knowledge", "code_interpreter"]
                else:
                    data_agent_config = foundry["fabricDataAgent"]
                    connection = ensure_fabric_data_agent_connection(
                        credential=credential,
                        project_resource_id=project_resource_id,
                        connection_name=data_agent_config["connectionName"],
                        workspace_id=config["fabric"]["workspaceId"],
                        artifact_id=config["fabric"]["dataAgentId"],
                    )
                    tools = [build_fabric_data_agent_tool(connection["id"])]
                    knowledge_source = None
                    tool_names = ["fabric_dataagent_preview"]
                agent = create_agent(
                    project,
                    item["name"],
                    PromptAgentDefinition(
                        model=item["model"],
                        instructions=item["instructions"].read_text(encoding="utf-8"),
                        tools=tools,
                    ),
                )
                result = {
                    "kind": item["kind"],
                    "id": agent.id,
                    "name": agent.name,
                    "version": agent.version,
                    "model": item["model"],
                    "tools": tool_names,
                    "knowledgeSource": knowledge_source,
                    "smokeTest": "pending",
                    "evaluation": {
                        "dataset": evaluation_dataset_path.name,
                        "status": "pending",
                    },
                }
                if knowledge_source:
                    result["knowledgeConnectionId"] = connection["id"]
                else:
                    result["fabricConnectionId"] = connection["id"]
                results.append(result)
                write_checkpoint(output_path, project_endpoint, foundry, results, "in-progress")
                if not args.skip_smoke_test:
                    smoke_test(project, agent.name)
                result["smokeTest"] = "skipped" if args.skip_smoke_test else "passed"
                if not isinstance(agent.version, (str, int)) or not str(agent.version).strip():
                    raise RuntimeError(f"unexpected_agent_version_type:{type(agent.version).__name__}")
                agent_version = str(agent.version)
                if args.skip_evaluations:
                    result["evaluation"]["status"] = "skipped"
                else:
                    try:
                        evaluation = run_managed_evaluation(
                            evaluation_openai,
                            agent_name=agent.name,
                            agent_version=agent_version,
                            model_deployment_name=foundry["model"]["name"],
                            cases=load_evaluation_cases(evaluation_dataset_path, item["kind"]),
                            output_directory=evaluation_output_directory,
                        )
                        result["evaluation"].update(evaluation)
                    except Exception as error:
                        result["evaluation"].update({"status": "failed", "error": str(error)})
                        write_checkpoint(output_path, project_endpoint, foundry, results, "incomplete")
                        raise
                write_checkpoint(output_path, project_endpoint, foundry, results, "in-progress")

    write_checkpoint(output_path, project_endpoint, foundry, results, "ready")


if __name__ == "__main__":
    main()