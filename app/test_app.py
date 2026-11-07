import json
import os
import unittest

import app


class AppTest(unittest.TestCase):
    def tearDown(self):
        for key in ("READY", "MESSAGE", "API_TOKEN", "DATABASE_URL"):
            os.environ.pop(key, None)

    def test_ready_means_can_serve(self):
        os.environ["READY"] = "true"
        code, body = app.ready_body()
        self.assertEqual(code, 200)
        self.assertEqual(body["status"], "ready")

    def test_failed_readiness_keeps_process_defined(self):
        os.environ["READY"] = "false"
        code, body = app.ready_body()
        self.assertEqual(code, 503)
        self.assertEqual(body["status"], "not-ready")

    def test_secret_is_not_in_the_payload(self):
        os.environ["API_TOKEN"] = "super-secret-value"
        os.environ["MESSAGE"] = "dev"
        body = app.announcements()
        encoded = json.dumps(body)
        self.assertTrue(body["token_set"])
        self.assertNotIn("super-secret-value", encoded)
        self.assertEqual(body["message"], "dev")
        self.assertEqual(body["database"], "not-configured")

    def test_database_url_marks_external_mode(self):
        os.environ["DATABASE_URL"] = "postgresql://db.internal:5432/campus"
        self.assertEqual(app.database_mode(), "external")
        encoded = json.dumps(app.announcements())
        self.assertNotIn("postgresql://", encoded)
