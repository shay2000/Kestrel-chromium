import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("publisher", ROOT / "scripts/publish-chromium-preview.py")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


class PublicationGuards(unittest.TestCase):
    def setUp(self):
        self.request = json.loads((ROOT / ".github/releases/chromium-preview.json").read_text())
        self.run = {"id": self.request["run_id"], "head_sha": self.request["source"],
                    "status": "completed", "conclusion": "success", "path": publisher.WORKFLOW,
                    "head_repository": {"full_name": publisher.REPOSITORY}}
        self.artifact = {"id": self.request["artifact_id"], "name": publisher.ARTIFACT_NAME,
                         "expired": False, "digest": self.request["artifact_digest"],
                         "workflow_run": {"id": self.request["run_id"], "head_sha": self.request["source"]}}

    def test_accepts_selected_successful_origin(self):
        publisher.validate_request(self.request)
        publisher.validate_origin(self.request, self.run, self.artifact)

    def test_resumes_existing_draft_by_id_without_tag_lookup_or_creation(self):
        draft = {"id": 42, "tag_name": self.request["tag"], "draft": True}
        result = mock.Mock(stdout=json.dumps([[draft]]))
        with mock.patch.object(publisher, "command", return_value=result), mock.patch.object(publisher, "api", return_value=draft) as api:
            self.assertEqual(publisher.find_or_create_release(self.request, "notes"), draft)
        api.assert_called_once_with("releases/42")

    def test_creates_preview_at_tested_source_then_uses_returned_id(self):
        draft = {"id": 43, "tag_name": self.request["tag"], "draft": True}
        result = mock.Mock(stdout="[[]]")
        with mock.patch.object(publisher, "command", return_value=result), mock.patch.object(publisher, "api", return_value=draft) as api:
            self.assertEqual(publisher.find_or_create_release(self.request, "notes"), draft)
        creation = api.call_args_list[0]
        self.assertEqual(creation.args[0], "releases")
        self.assertEqual(creation.args[1]["target_commitish"], self.request["source"])
        self.assertTrue(creation.args[1]["draft"])
        self.assertTrue(creation.args[1]["prerelease"])
        self.assertEqual(api.call_args_list[1], mock.call("releases/43"))

    def test_refuses_failed_or_different_source_build(self):
        for field, value in [("conclusion", "failure"), ("status", "in_progress"), ("head_sha", "b" * 40),
                             ("path", "different.yml"), ("head_repository", {"full_name": "another/repo"})]:
            run = dict(self.run, **{field: value})
            with self.subTest(field=field), self.assertRaises(ValueError):
                publisher.validate_origin(self.request, run, self.artifact)

    def test_refuses_expired_substituted_or_cross_run_artifact(self):
        for field, value in [("expired", True), ("digest", "sha256:" + "0" * 64), ("id", 1),
                             ("name", "different-artifact"), ("workflow_run", {"id": 1, "head_sha": self.request["source"]})]:
            artifact = dict(self.artifact, **{field: value})
            with self.subTest(field=field), self.assertRaises(ValueError):
                publisher.validate_origin(self.request, self.run, artifact)

    def test_refuses_other_repository_stable_tag_and_unsafe_paths(self):
        for field, value in [("repository", "shay2000/Kestrel-Browser"), ("tag", "v1.0.0"),
                             ("source", "main"), ("dmg", "../Kestrel.dmg"), ("notes", "../notes.md")]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                publisher.validate_request(dict(self.request, **{field: value}))

    def check_archive(self, *, content=b"fixture DMG", checksum=None, extra=None, corrupt_zip_digest=False):
        name = self.request["dmg"]
        expected = hashlib.sha256(b"fixture DMG").hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            archive = output / "artifact.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr(name, content)
                bundle.writestr(name + ".sha256", checksum or f"{expected}  {name}\n")
                if extra:
                    bundle.writestr(extra, b"unexpected")
            request = copy.deepcopy(self.request)
            request["artifact_digest"] = "sha256:" + ("0" * 64 if corrupt_zip_digest else publisher.digest(archive))
            return publisher.unpack_verified(request, archive, output)

    def test_verified_bytes_and_exact_sidecar_pass(self):
        self.assertEqual(self.check_archive(), hashlib.sha256(b"fixture DMG").hexdigest())

    def test_refuses_corrupt_zip_or_changed_dmg(self):
        for args in [{"corrupt_zip_digest": True}, {"content": b"tampered"}]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.check_archive(**args)

    def test_refuses_unexpected_members_and_checksum_destinations(self):
        for args in [{"extra": "../escaped"}, {"extra": "other.dmg"},
                     {"checksum": "0" * 64 + "  ../elsewhere.dmg\n"}]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.check_archive(**args)


if __name__ == "__main__":
    unittest.main()
