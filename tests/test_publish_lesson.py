"""Tests for scripts.publish_lesson: package validation, sha256 checks, version refusal, fake HTTP publishing.

Spec: docs/specs/2026-10-31-course-platform-design.md §2.2, §2.3.
Order: WO-1D backend.
CI-safe: uses a fake HTTP layer with zero network access.
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from groove_eval.lesson_package import LessonPackageError
from scripts.publish_lesson import (
    check_version_exists,
    compute_file_sha256,
    main,
    publish_package,
    verify_package_files,
)

EXAMPLE_MANIFEST = ROOT / "fixtures" / "lessons" / "example_manifest.json"


class FakeResponse:
    def __init__(self, status: int, data: bytes, headers: Optional[Dict[str, str]] = None):
        self.status = status
        self.data = data
        self.headers = headers or {}

    def read(self) -> bytes:
        return self.data

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        pass


class FakeOpener:
    """In-memory HTTP transport recorder and mock responder for urllib."""

    def __init__(self):
        self.requests: List[Dict[str, Any]] = []
        self.handlers: Dict[tuple[str, str], Any] = {}
        self.default_response = (200, b"[]")

    def register(self, method: str, path_substr: str, status: int, body: bytes):
        self.handlers[(method.upper(), path_substr)] = (status, body)

    def open(self, req: urllib.request.Request):
        url = req.full_url
        method = req.get_method()
        data = req.data
        headers = dict(req.headers)
        self.requests.append({
            "url": url,
            "method": method,
            "data": data,
            "headers": headers,
        })

        for (m, substr), resp in self.handlers.items():
            if m == method and substr in url:
                if isinstance(resp, Exception):
                    raise resp
                status, body = resp
                if status >= 400:
                    raise urllib.error.HTTPError(url, status, "Error", headers, None)
                return FakeResponse(status, body)

        status, body = self.default_response
        return FakeResponse(status, body)


class TestPublishLesson(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.package_dir = Path(self.temp_dir) / "test_package"
        self.package_dir.mkdir()

        # Load valid base manifest
        with open(EXAMPLE_MANIFEST, "r", encoding="utf-8") as f:
            self.manifest_data = json.load(f)

        # Create dummy assets
        self.video_content = b"fake video mp4 stream"
        self.ref_content = b'{"frames": []}'
        self.poster_content = b"fake jpeg image bytes"

        (self.package_dir / "video.mp4").write_bytes(self.video_content)
        (self.package_dir / "reference_pose.json").write_bytes(self.ref_content)
        (self.package_dir / "poster.jpg").write_bytes(self.poster_content)

        # Update manifest files with true sha256 checksums
        self.manifest_data["files"] = {
            "video.mp4": hashlib.sha256(self.video_content).hexdigest(),
            "reference_pose.json": hashlib.sha256(self.ref_content).hexdigest(),
            "poster.jpg": hashlib.sha256(self.poster_content).hexdigest(),
        }

        self.manifest_path = self.package_dir / "manifest.json"
        self.manifest_path.write_text(json.dumps(self.manifest_data, indent=2), encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_compute_file_sha256(self):
        video_path = self.package_dir / "video.mp4"
        expected = hashlib.sha256(self.video_content).hexdigest()
        self.assertEqual(compute_file_sha256(video_path), expected)

    def test_verify_package_files_success(self):
        verified = verify_package_files(self.package_dir, self.manifest_data)
        filenames = [fn for fn, _, _ in verified]
        self.assertIn("video.mp4", filenames)
        self.assertIn("reference_pose.json", filenames)
        self.assertIn("poster.jpg", filenames)

    def test_verify_package_files_detects_mismatch(self):
        # Corrupt a file
        (self.package_dir / "video.mp4").write_bytes(b"tampered content")
        with self.assertRaises(ValueError) as ctx:
            verify_package_files(self.package_dir, self.manifest_data)
        self.assertIn("SHA-256 mismatch", str(ctx.exception))

    def test_verify_package_files_detects_missing_file(self):
        (self.package_dir / "poster.jpg").unlink()
        with self.assertRaises(FileNotFoundError) as ctx:
            verify_package_files(self.package_dir, self.manifest_data)
        self.assertIn("Package file missing", str(ctx.exception))

    def test_dry_run_mode(self):
        opener = FakeOpener()
        result = publish_package(
            package_dir=self.package_dir,
            supabase_url="http://127.0.0.1:54321",
            service_key="fake-service-key",
            dry_run=True,
            opener=opener,
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["course_slug"], "bollywood-basics")
        self.assertEqual(result["lesson_slug"], "img4941-routine")
        self.assertEqual(result["package_version"], 1)
        self.assertEqual(result["storage_prefix"], "bollywood-basics/img4941-routine/v1/")
        # Dry run should not make any HTTP calls
        self.assertEqual(len(opener.requests), 0)

    def test_missing_service_key_raises(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError) as ctx:
                publish_package(
                    package_dir=self.package_dir,
                    supabase_url="http://127.0.0.1:54321",
                    service_key=None,
                    dry_run=False,
                )
            self.assertIn("Service key is required", str(ctx.exception))

    def test_refuses_existing_version(self):
        opener = FakeOpener()
        # When querying existing lesson_versions, simulate that row already exists
        opener.register(
            "GET",
            "/rest/v1/lesson_versions",
            200,
            json.dumps([{"id": "existing-uuid"}]).encode("utf-8"),
        )

        with self.assertRaises(ValueError) as ctx:
            publish_package(
                package_dir=self.package_dir,
                supabase_url="http://127.0.0.1:54321",
                service_key="fake-service-key",
                dry_run=False,
                opener=opener,
            )
        self.assertIn("already exists", str(ctx.exception))
        # No storage uploads or inserts should have happened
        upload_calls = [r for r in opener.requests if "/storage/v1/object" in r["url"]]
        self.assertEqual(len(upload_calls), 0)

    def test_successful_publish(self):
        opener = FakeOpener()
        # 1. Version check returns empty array -> version does not exist
        opener.register(
            "GET",
            "/rest/v1/lesson_versions",
            200,
            json.dumps([]).encode("utf-8"),
        )
        # 2. Storage uploads return 200
        opener.register("POST", "/storage/v1/object/lesson-packages", 200, b'{"Key": "uploaded"}')
        # 3. DB insert returns created row
        inserted_row = {
            "id": "new-version-uuid",
            "lesson_id": self.manifest_data["lesson_id"],
            "package_version": 1,
            "status": "published",
        }
        opener.register("POST", "/rest/v1/lesson_versions", 201, json.dumps([inserted_row]).encode("utf-8"))

        res = publish_package(
            package_dir=self.package_dir,
            supabase_url="http://127.0.0.1:54321",
            service_key="fake-service-key",
            bucket="lesson-packages",
            dry_run=False,
            opener=opener,
        )

        self.assertFalse(res["dry_run"])
        self.assertEqual(res["created_row"]["id"], "new-version-uuid")

        # Verify requests made
        req_urls = [r["url"] for r in opener.requests]
        req_methods = [r["method"] for r in opener.requests]

        # 1st request was GET checking version
        self.assertEqual(req_methods[0], "GET")
        self.assertIn("/rest/v1/lesson_versions", req_urls[0])

        # Storage upload requests for manifest, video, reference_pose, poster
        storage_uploads = [r for r in opener.requests if "/storage/v1/object" in r["url"]]
        self.assertEqual(len(storage_uploads), 4)

        expected_prefix = "bollywood-basics/img4941-routine/v1/"
        uploaded_paths = [r["url"].split("/storage/v1/object/lesson-packages/")[-1] for r in storage_uploads]
        self.assertIn(f"{expected_prefix}manifest.json", uploaded_paths)
        self.assertIn(f"{expected_prefix}video.mp4", uploaded_paths)
        self.assertIn(f"{expected_prefix}reference_pose.json", uploaded_paths)
        self.assertIn(f"{expected_prefix}poster.jpg", uploaded_paths)

        # Check headers on storage uploads
        for r in storage_uploads:
            self.assertEqual(r["headers"].get("Apikey"), "fake-service-key")
            self.assertEqual(r["headers"].get("Authorization"), "Bearer fake-service-key")

        # Final request was POST inserting lesson_versions row
        db_insert = opener.requests[-1]
        self.assertEqual(db_insert["method"], "POST")
        self.assertIn("/rest/v1/lesson_versions", db_insert["url"])
        insert_payload = json.loads(db_insert["data"].decode("utf-8"))
        self.assertEqual(insert_payload["lesson_id"], self.manifest_data["lesson_id"])
        self.assertEqual(insert_payload["package_version"], 1)
        self.assertEqual(insert_payload["storage_prefix"], expected_prefix)
        self.assertEqual(insert_payload["status"], "published")
        self.assertEqual(insert_payload["pose_model_sha256"], self.manifest_data["extractor"]["pose_model_sha256"])

    def test_manifest_validation_error_aborts(self):
        # Mutate manifest to violate schema (e.g. invalid package_version)
        self.manifest_data["package_version"] = -5
        self.manifest_path.write_text(json.dumps(self.manifest_data), encoding="utf-8")

        with self.assertRaises(LessonPackageError):
            publish_package(
                package_dir=self.package_dir,
                supabase_url="http://127.0.0.1:54321",
                service_key="fake-service-key",
                dry_run=True,
            )

    def test_cli_main_dry_run(self):
        ret = main([str(self.package_dir), "--dry-run"])
        self.assertEqual(ret, 0)


if __name__ == "__main__":
    unittest.main()
