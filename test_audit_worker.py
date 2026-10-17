import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("audit-worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def http(code):
    return HTTPError("https://example.invalid", code, "simulado", {}, None)


class CommunicationTests(unittest.TestCase):
    def setUp(self):
        self.sleep = patch.object(worker.time, "sleep").start()
        self.addCleanup(patch.stopall)

    def test_401_refreshes_token_and_retries_same_save(self):
        body = {"action": "save", "id": 7, "lease": "private", "result": {}}
        with patch.object(worker, "get_token", side_effect=["old", "new"]) as tokens, patch.object(worker, "request_json", side_effect=[http(401), {"saved": True}]) as request:
            self.assertEqual(worker.call(body), {"saved": True})
            self.assertEqual(tokens.call_count, 2)
            self.assertEqual(request.call_args_list[0].args[0].data, request.call_args_list[1].args[0].data)
            self.assertEqual(request.call_args.args[0].get_header("Authorization"), "Bearer new")

    def test_oidc_503_recovers_before_claim(self):
        with patch.object(worker, "get_token", side_effect=[http(503), "new"]) as tokens, patch.object(worker, "request_json", return_value=None) as request:
            self.assertIsNone(worker.call({"action": "claim"}))
            self.assertEqual(tokens.call_count, 2)
            self.assertEqual(request.call_count, 1)

    def test_save_503_and_connection_error_recover(self):
        with patch.object(worker, "get_token", return_value="token"), patch.object(worker, "request_json", side_effect=[http(503), URLError("lost"), {"saved": True}]) as request:
            self.assertTrue(worker.call({"action": "save"})["saved"])
            self.assertEqual(request.call_count, 3)

    def test_persistent_401_is_bounded(self):
        with patch.object(worker, "get_token", return_value="token"), patch.object(worker, "request_json", side_effect=http(401)) as request:
            with self.assertRaises(HTTPError):
                worker.call({"action": "save"})
            self.assertEqual(request.call_count, 3)

    def test_400_is_not_retried(self):
        with patch.object(worker, "get_token", return_value="token"), patch.object(worker, "request_json", side_effect=http(400)) as request:
            with self.assertRaises(HTTPError):
                worker.call({"action": "save"})
            self.assertEqual(request.call_count, 1)

    def test_ambiguous_claim_is_not_repeated(self):
        for failure in [http(503), URLError("lost"), TimeoutError()]:
            with self.subTest(failure=type(failure).__name__), patch.object(worker, "get_token", return_value="token"), patch.object(worker, "request_json", side_effect=failure) as request:
                with self.assertRaises(type(failure)):
                    worker.call({"action": "claim"})
                self.assertEqual(request.call_count, 1)

    def test_save_false_does_not_count_as_success(self):
        job = {"id": 1, "lease": "private", "texto": "", "cadastro": {}, "categoria": "anexo"}
        with patch.object(worker, "call", return_value={"saved": False}):
            with self.assertRaises(RuntimeError):
                worker.processar(job)


class BatchTests(unittest.TestCase):
    def run_batch(self, claim_results, process):
        with tempfile.TemporaryDirectory() as directory:
            previous = os.getcwd()
            try:
                os.chdir(directory)
                with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(Path(directory) / "step.md")}), patch.object(worker, "call", side_effect=claim_results), patch.object(worker, "processar", side_effect=process):
                    status = worker.main()
                return status, json.loads(Path("audit-report/summary.json").read_text()), Path("step.md").read_text()
            finally:
                os.chdir(previous)

    def test_failed_item_preserves_other_results_and_redacts_secrets(self):
        def process(job):
            if job["id"] == 1:
                raise http(401)
            return "conferente_automatico"
        jobs = [{"id": i, "lease": "secret"} for i in range(1, 5)]
        status, report, summary = self.run_batch(jobs, process)
        self.assertEqual(status, 1)
        self.assertEqual(report["resultados_gravados"], {"conferente_automatico": 3})
        self.assertEqual(report["itens_sem_confirmacao"][0]["id"], 1)
        self.assertNotIn("secret", json.dumps(report))
        self.assertIn("3", summary)

    def test_claim_failure_still_processes_already_reserved_items(self):
        status, report, _ = self.run_batch([{"id": 2}, http(503)], lambda job: "inconclusivo")
        self.assertEqual(status, 1)
        self.assertEqual(report["resultados_gravados"], {"inconclusivo": 1})
        self.assertEqual(report["falha_reserva"]["http_status"], 503)

    def test_empty_queue_is_success(self):
        status, report, _ = self.run_batch([None], lambda job: "unused")
        self.assertEqual(status, 0)
        self.assertEqual(report["itens_sem_confirmacao"], [])


if __name__ == "__main__":
    unittest.main()
