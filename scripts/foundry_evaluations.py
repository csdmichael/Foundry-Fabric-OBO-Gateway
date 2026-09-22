from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from azure.ai.projects.models import (
    AzureAIAgentTargetParam,
    TargetCompletionEvalRunDataSource,
    TestingCriterionAzureAIEvaluator,
)
from openai.types.eval_create_params import DataSourceConfigCustom
from openai.types.evals.create_eval_completions_run_data_source_param import (
    SourceFileContent,
    SourceFileContentContent,
)


TERMINAL_STATUSES = {"completed", "failed", "canceled"}
REQUIRED_CASE_FIELDS = {"agent_kind", "scenario", "query", "expected_behavior"}
RETRYABLE_STATUS_CODES = {408, 409, 429, 500, 502, 503, 504}


def to_json_primitive(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (list, tuple)):
        return [to_json_primitive(item) for item in value]
    if isinstance(value, dict):
        return {key: to_json_primitive(item) for key, item in value.items()}
    for method_name in ("model_dump", "to_dict", "as_dict", "dict"):
        method = getattr(value, method_name, None)
        if callable(method):
            return to_json_primitive(method())
    if hasattr(value, "__dict__"):
        return to_json_primitive({
            key: item for key, item in vars(value).items() if not key.startswith("_")
        })
    return str(value)


def load_evaluation_cases(dataset_path: Path, agent_kind: str) -> list[dict[str, Any]]:
    cases = []
    for line_number, line in enumerate(dataset_path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            case = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"Invalid JSONL at {dataset_path}:{line_number}") from error
        missing_fields = REQUIRED_CASE_FIELDS - case.keys()
        if missing_fields:
            missing = ", ".join(sorted(missing_fields))
            raise ValueError(f"Missing fields at {dataset_path}:{line_number}: {missing}")
        for field_name in REQUIRED_CASE_FIELDS:
            field_value = case[field_name]
            if not isinstance(field_value, str) or not field_value.strip():
                raise ValueError(
                    f"Field '{field_name}' at {dataset_path}:{line_number} must be a non-empty string"
                )
        if case["agent_kind"] != agent_kind:
            continue
        case["evaluation_query"] = (
            f"User request: {case['query']}\n\n"
            f"Required agent behavior: {case['expected_behavior']}"
        )
        cases.append(case)
    if not cases:
        raise ValueError(f"No evaluation cases found for agent kind '{agent_kind}'")
    return cases


def build_data_source_config() -> DataSourceConfigCustom:
    return DataSourceConfigCustom(
        type="custom",
        item_schema={
            "type": "object",
            "properties": {
                "agent_kind": {"type": "string"},
                "scenario": {"type": "string"},
                "query": {"type": "string"},
                "expected_behavior": {"type": "string"},
                "evaluation_query": {"type": "string"},
            },
            "required": [
                "agent_kind",
                "scenario",
                "query",
                "expected_behavior",
                "evaluation_query",
            ],
        },
        include_sample_schema=True,
    )


def build_testing_criteria(model_deployment_name: str) -> list[TestingCriterionAzureAIEvaluator]:
    text_mapping = {
        "query": "{{item.query}}",
        "response": "{{sample.output_text}}",
    }
    return [
        TestingCriterionAzureAIEvaluator(
            type="azure_ai_evaluator",
            name="task_adherence",
            evaluator_name="builtin.task_adherence",
            initialization_parameters={"model": model_deployment_name},
            data_mapping={
                "query": "{{item.evaluation_query}}",
                "response": "{{sample.output_items}}",
            },
        ),
        TestingCriterionAzureAIEvaluator(
            type="azure_ai_evaluator",
            name="indirect_attack",
            evaluator_name="builtin.indirect_attack",
            data_mapping=text_mapping,
        ),
        *[
            TestingCriterionAzureAIEvaluator(
                type="azure_ai_evaluator",
                name=risk,
                evaluator_name=f"builtin.{risk}",
                data_mapping=text_mapping,
            )
            for risk in ("violence", "sexual", "self_harm", "hate_unfairness")
        ],
    ]


def build_agent_data_source(
    agent_name: str,
    agent_version: str,
    cases: list[dict[str, Any]],
) -> TargetCompletionEvalRunDataSource:
    return TargetCompletionEvalRunDataSource(
        type="azure_ai_target_completions",
        source=SourceFileContent(
            type="file_content",
            content=[SourceFileContentContent(item=case) for case in cases],
        ),
        input_messages={
            "type": "template",
            "template": [
                {
                    "type": "message",
                    "role": "user",
                    "content": {"type": "input_text", "text": "{{item.query}}"},
                }
            ],
        },
        target=AzureAIAgentTargetParam(
            type="azure_ai_agent",
            name=agent_name,
            version=agent_version,
        ),
    )


def assert_evaluation_passed(run: Any) -> dict[str, int]:
    status = str(getattr(run, "status", ""))
    counts = to_json_primitive(getattr(run, "result_counts", {})) or {}
    normalized = {
        "total": int(counts.get("total", 0)),
        "passed": int(counts.get("passed", 0)),
        "failed": int(counts.get("failed", 0)),
        "errored": int(counts.get("errored", 0)),
    }
    if status != "completed":
        raise RuntimeError(f"Foundry evaluation ended with status '{status}'")
    if normalized["total"] <= 0:
        raise RuntimeError("Foundry evaluation returned no scored criteria")
    if (
        normalized["failed"] > 0
        or normalized["errored"] > 0
        or normalized["passed"] != normalized["total"]
    ):
        raise RuntimeError(f"Foundry evaluation release gate failed: {normalized}")
    return normalized


def is_retryable(error: Exception) -> bool:
    status_code = getattr(error, "status_code", None)
    return status_code in RETRYABLE_STATUS_CODES or any(
        marker in str(error).lower()
        for marker in ("rate limit", "timed out", "temporarily unavailable", "service unavailable")
    )


def call_with_retry(operation: Any, *, deadline: float, initial_delay_seconds: int) -> Any:
    delay_seconds = max(initial_delay_seconds, 1)
    while True:
        try:
            return operation()
        except Exception as error:
            remaining_seconds = deadline - time.monotonic()
            if not is_retryable(error) or remaining_seconds <= delay_seconds:
                raise
            time.sleep(delay_seconds)
            delay_seconds = min(delay_seconds * 2, 60)


def run_managed_evaluation(
    openai_client: Any,
    *,
    agent_name: str,
    agent_version: str,
    model_deployment_name: str,
    cases: list[dict[str, Any]],
    output_directory: Path,
    timeout_seconds: int = 900,
    poll_interval_seconds: int = 5,
) -> dict[str, Any]:
    timestamp = int(time.time())
    deadline = time.monotonic() + timeout_seconds
    evaluation = call_with_retry(
        lambda: openai_client.evals.create(
            name=f"{agent_name} safety-quality v{agent_version} {timestamp}",
            data_source_config=build_data_source_config(),
            testing_criteria=build_testing_criteria(model_deployment_name),
        ),
        deadline=deadline,
        initial_delay_seconds=poll_interval_seconds,
    )
    run = call_with_retry(
        lambda: openai_client.evals.runs.create(
            eval_id=evaluation.id,
            name=f"release-gate-{agent_name}-v{agent_version}-{timestamp}",
            data_source=build_agent_data_source(agent_name, agent_version, cases),
        ),
        deadline=deadline,
        initial_delay_seconds=poll_interval_seconds,
    )
    while run.status not in TERMINAL_STATUSES:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Foundry evaluation timed out for agent '{agent_name}'")
        time.sleep(poll_interval_seconds)
        run = call_with_retry(
            lambda: openai_client.evals.runs.retrieve(run_id=run.id, eval_id=evaluation.id),
            deadline=deadline,
            initial_delay_seconds=poll_interval_seconds,
        )

    output_items = call_with_retry(
        lambda: list(
            openai_client.evals.runs.output_items.list(run_id=run.id, eval_id=evaluation.id)
        ),
        deadline=deadline,
        initial_delay_seconds=poll_interval_seconds,
    )
    output_directory.mkdir(parents=True, exist_ok=True)
    safe_agent_name = re.sub(r"[^A-Za-z0-9_.-]", "-", agent_name)
    result_path = output_directory / f"{safe_agent_name}-v{agent_version}-{run.id}.json"
    result_document = {
        "schemaVersion": 1,
        "agentName": agent_name,
        "agentVersion": agent_version,
        "evaluationId": evaluation.id,
        "run": to_json_primitive(run),
        "outputItems": to_json_primitive(output_items),
    }
    result_path.write_text(json.dumps(result_document, indent=2) + "\n", encoding="utf-8")
    counts = assert_evaluation_passed(run)
    return {
        "status": "passed",
        "evaluationId": evaluation.id,
        "runId": run.id,
        "resultCounts": counts,
        "resultPath": str(result_path),
    }