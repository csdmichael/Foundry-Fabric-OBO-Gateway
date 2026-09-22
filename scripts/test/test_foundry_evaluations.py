import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from foundry_evaluations import (
    assert_evaluation_passed,
    build_agent_data_source,
    build_testing_criteria,
    load_evaluation_cases,
    run_managed_evaluation,
)


ROOT = Path(__file__).resolve().parents[2]
DATASET_PATH = ROOT / "agents" / "foundry" / "evaluations" / "safety-quality-v1.jsonl"


class FoundryEvaluationTests(unittest.TestCase):
    def test_versioned_dataset_covers_both_agents(self):
        lakehouse_cases = load_evaluation_cases(DATASET_PATH, "lakehouse")
        data_agent_cases = load_evaluation_cases(DATASET_PATH, "dataAgent")

        self.assertGreaterEqual(len(lakehouse_cases), 5)
        self.assertGreaterEqual(len(data_agent_cases), 5)
        self.assertEqual(len({case["scenario"] for case in lakehouse_cases}), len(lakehouse_cases))
        self.assertEqual(len({case["scenario"] for case in data_agent_cases}), len(data_agent_cases))
        self.assertTrue(all(case["evaluation_query"] for case in lakehouse_cases + data_agent_cases))

    def test_rejects_incomplete_dataset_rows(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            dataset_path = Path(temporary_directory) / "invalid.jsonl"
            dataset_path.write_text(json.dumps({"agent_kind": "lakehouse"}) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "Missing fields"):
                load_evaluation_cases(dataset_path, "lakehouse")

    def test_rejects_non_string_dataset_fields(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            dataset_path = Path(temporary_directory) / "invalid.jsonl"
            dataset_path.write_text(
                json.dumps({
                    "agent_kind": "lakehouse",
                    "scenario": "invalid-query",
                    "query": {"not": "a string"},
                    "expected_behavior": "Reject invalid rows",
                })
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "must be a non-empty string"):
                load_evaluation_cases(dataset_path, "lakehouse")

    def test_criteria_cover_adherence_injection_and_content_safety(self):
        criteria = build_testing_criteria("judge-model")

        self.assertEqual(
            [criterion["name"] for criterion in criteria],
            [
                "task_adherence",
                "indirect_attack",
                "violence",
                "sexual",
                "self_harm",
                "hate_unfairness",
            ],
        )
        self.assertEqual(criteria[0]["initialization_parameters"], {"model": "judge-model"})
        self.assertEqual(criteria[0]["data_mapping"]["response"], "{{sample.output_items}}")

    def test_agent_target_uses_exact_version_and_inline_cases(self):
        cases = load_evaluation_cases(DATASET_PATH, "lakehouse")

        data_source = build_agent_data_source("lakehouse-agent", "7", cases)

        self.assertEqual(data_source["target"]["name"], "lakehouse-agent")
        self.assertEqual(data_source["target"]["version"], "7")
        self.assertEqual(len(data_source["source"]["content"]), len(cases))
        self.assertEqual(
            data_source["input_messages"]["template"][0]["content"]["text"],
            "{{item.query}}",
        )

    def test_release_gate_requires_every_criterion_to_pass(self):
        passing_run = SimpleNamespace(
            status="completed",
            result_counts=SimpleNamespace(total=12, passed=12, failed=0, errored=0),
        )
        failing_run = SimpleNamespace(
            status="completed",
            result_counts=SimpleNamespace(total=12, passed=11, failed=1, errored=0),
        )

        self.assertEqual(
            assert_evaluation_passed(passing_run),
            {"total": 12, "passed": 12, "failed": 0, "errored": 0},
        )
        with self.assertRaisesRegex(RuntimeError, "release gate failed"):
            assert_evaluation_passed(failing_run)

    def test_full_managed_run_persists_results_and_passes(self):
        evaluation = SimpleNamespace(id="eval-123")
        run = SimpleNamespace(
            id="run-456",
            status="completed",
            result_counts=SimpleNamespace(total=12, passed=12, failed=0, errored=0),
        )
        openai_client = MagicMock()
        openai_client.evals.create.return_value = evaluation
        openai_client.evals.runs.create.return_value = run
        openai_client.evals.runs.output_items.list.return_value = [
            {"id": "output-1", "status": "pass"}
        ]

        with tempfile.TemporaryDirectory() as temporary_directory:
            result = run_managed_evaluation(
                openai_client,
                agent_name="test-agent",
                agent_version="7",
                model_deployment_name="judge-model",
                cases=load_evaluation_cases(DATASET_PATH, "lakehouse"),
                output_directory=Path(temporary_directory),
                poll_interval_seconds=1,
            )
            result_document = json.loads(Path(result["resultPath"]).read_text(encoding="utf-8"))

        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["resultCounts"], {"total": 12, "passed": 12, "failed": 0, "errored": 0})
        self.assertEqual(result_document["evaluationId"], "eval-123")
        self.assertEqual(result_document["outputItems"][0]["id"], "output-1")
        openai_client.evals.create.assert_called_once()
        openai_client.evals.runs.create.assert_called_once()


if __name__ == "__main__":
    unittest.main()