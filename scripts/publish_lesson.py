#!/usr/bin/env python3
"""Publish a dance lesson package to Supabase Storage and Postgres.

Spec: docs/specs/2026-10-31-course-platform-design.md §2.2, §2.3.
Order: WO-1D backend.

Validates the lesson package directory using groove_eval.lesson_package,
verifies file sha256 checksums, checks that the package version does not
already exist, uploads all assets to Supabase Storage under
{course}/{lesson}/v{n}/ with upsert-on-retry enabled, performs post-upload
remote sha256 verification, cleans up on failure, and inserts a row into
`public.lesson_versions`.

Stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

# Re-use contract validator from groove_eval
from groove_eval.lesson_package import LessonPackageError, load_manifest, validate_manifest


def compute_file_sha256(path: Path) -> str:
    """Compute sha256 hex digest of a file in chunks."""
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest().lower()


def verify_package_files(package_dir: Path, manifest: Dict[str, Any]) -> List[Tuple[str, Path, str]]:
    """Verify that all files in manifest['files'] exist and match their declared sha256.

    Returns a list of tuples: (filename, path, sha256).
    """
    verified = []
    files_map = manifest.get("files", {})
    if not files_map:
        raise LessonPackageError(f"manifest.files is empty in {package_dir}")

    for filename, expected_hash in files_map.items():
        file_path = package_dir / filename
        if not file_path.is_file():
            raise FileNotFoundError(f"Package file missing: {file_path}")
        computed_hash = compute_file_sha256(file_path)
        if computed_hash != expected_hash.lower():
            raise ValueError(
                f"SHA-256 mismatch for {filename}: computed {computed_hash} != manifest {expected_hash}"
            )
        verified.append((filename, file_path, computed_hash))

    return verified


def make_request(
    url: str,
    method: str = "GET",
    data: Optional[bytes] = None,
    headers: Optional[Dict[str, str]] = None,
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> Tuple[int, bytes]:
    """Execute an HTTP request using urllib.request."""
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    send = opener.open if opener is not None else urllib.request.urlopen
    try:
        with send(req) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code} for {method} {url}: {body}") from e


def check_version_exists(
    supabase_url: str,
    service_key: str,
    lesson_id: str,
    package_version: int,
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> bool:
    """Query PostgREST to check if lesson_versions already has (lesson_id, package_version)."""
    base_url = supabase_url.rstrip("/")
    params = urllib.parse.urlencode({
        "lesson_id": f"eq.{lesson_id}",
        "package_version": f"eq.{package_version}",
        "select": "id",
    })
    url = f"{base_url}/rest/v1/lesson_versions?{params}"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Accept": "application/json",
    }
    status, body = make_request(url, method="GET", headers=headers, opener=opener)
    records = json.loads(body.decode("utf-8"))
    return len(records) > 0


def upload_storage_object(
    supabase_url: str,
    service_key: str,
    bucket: str,
    object_path: str,
    data: bytes,
    content_type: str = "application/octet-stream",
    upsert: bool = True,
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> None:
    """Upload an object to Supabase Storage. Upsert defaults to True to allow retrying failed uploads."""
    base_url = supabase_url.rstrip("/")
    encoded_path = "/".join(urllib.parse.quote(seg, safe="") for seg in object_path.strip("/").split("/"))
    url = f"{base_url}/storage/v1/object/{bucket}/{encoded_path}"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": content_type,
        "x-upsert": "true" if upsert else "false",
    }
    make_request(url, method="POST", data=data, headers=headers, opener=opener)


def download_storage_object(
    supabase_url: str,
    service_key: str,
    bucket: str,
    object_path: str,
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> bytes:
    """Download an object from Supabase Storage for post-upload verification."""
    base_url = supabase_url.rstrip("/")
    encoded_path = "/".join(urllib.parse.quote(seg, safe="") for seg in object_path.strip("/").split("/"))
    url = f"{base_url}/storage/v1/object/{bucket}/{encoded_path}"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }
    status, body = make_request(url, method="GET", headers=headers, opener=opener)
    return body


def verify_uploaded_object(
    supabase_url: str,
    service_key: str,
    bucket: str,
    object_path: str,
    expected_sha256: str,
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> None:
    """Verify that an uploaded object in Supabase Storage matches the expected sha256."""
    remote_bytes = download_storage_object(supabase_url, service_key, bucket, object_path, opener=opener)
    remote_sha256 = hashlib.sha256(remote_bytes).hexdigest().lower()
    if remote_sha256 != expected_sha256.lower():
        raise ValueError(
            f"Remote sha256 mismatch for {object_path}: got {remote_sha256}, expected {expected_sha256}"
        )


def delete_storage_object(
    supabase_url: str,
    service_key: str,
    bucket: str,
    object_path: str,
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> None:
    """Delete an object from Supabase Storage (used during cleanup on failure)."""
    base_url = supabase_url.rstrip("/")
    encoded_path = "/".join(urllib.parse.quote(seg, safe="") for seg in object_path.strip("/").split("/"))
    url = f"{base_url}/storage/v1/object/{bucket}/{encoded_path}"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }
    make_request(url, method="DELETE", headers=headers, opener=opener)


def cleanup_uploaded_objects(
    supabase_url: str,
    service_key: str,
    bucket: str,
    object_paths: List[str],
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> None:
    """Attempt to delete partially uploaded objects after a failure."""
    for path in object_paths:
        try:
            delete_storage_object(supabase_url, service_key, bucket, path, opener=opener)
            print(f"Cleaned up {bucket}/{path}")
        except Exception as e:
            print(f"Warning: failed to clean up {bucket}/{path}: {e}", file=sys.stderr)


def insert_lesson_version(
    supabase_url: str,
    service_key: str,
    payload: Dict[str, Any],
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> Dict[str, Any]:
    """Insert a new lesson_versions row via PostgREST."""
    base_url = supabase_url.rstrip("/")
    url = f"{base_url}/rest/v1/lesson_versions"
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }
    data = json.dumps(payload).encode("utf-8")
    status, body = make_request(url, method="POST", data=data, headers=headers, opener=opener)
    res = json.loads(body.decode("utf-8"))
    return res[0] if isinstance(res, list) and res else res


def publish_package(
    package_dir: Path,
    supabase_url: Optional[str] = None,
    service_key: Optional[str] = None,
    bucket: str = "lesson-packages",
    dry_run: bool = False,
    opener: Optional[urllib.request.OpenerDirector] = None,
) -> Dict[str, Any]:
    """Validate and publish a lesson package to Supabase."""
    package_dir = Path(package_dir).resolve()
    manifest_path = package_dir / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"manifest.json not found in {package_dir}")

    # 1. Load and validate manifest with groove_eval.lesson_package
    manifest = load_manifest(manifest_path, validate=True)

    # 2. Verify sha256 checksums of all declared files
    verified_files = verify_package_files(package_dir, manifest)

    course_slug = manifest["course_slug"]
    lesson_slug = manifest["lesson_slug"]
    package_version = manifest["package_version"]
    lesson_id = manifest["lesson_id"]
    pose_model_sha256 = manifest["extractor"]["pose_model_sha256"]
    storage_prefix = f"{course_slug}/{lesson_slug}/v{package_version}/"

    version_record = {
        "lesson_id": lesson_id,
        "package_version": package_version,
        "storage_prefix": storage_prefix,
        "manifest": manifest,
        "pose_model_sha256": pose_model_sha256,
        "status": "published",
    }

    if dry_run:
        print(f"[DRY-RUN] Manifest validated for {course_slug}/{lesson_slug} (lesson_id: {lesson_id})")
        print(f"[DRY-RUN] Target storage prefix: {bucket}/{storage_prefix}")
        print(f"[DRY-RUN] Verified files ({len(verified_files)}):")
        for fn, p, h in verified_files:
            size_kb = p.stat().st_size / 1024.0
            print(f"  - {fn} ({size_kb:.1f} KB, sha256: {h[:12]}...)")
        print(f"[DRY-RUN] manifest.json ({manifest_path.stat().st_size / 1024.0:.1f} KB)")
        print(f"[DRY-RUN] Target row: lesson_versions(lesson_id={lesson_id}, package_version={package_version}, storage_prefix={storage_prefix})")
        print("[DRY-RUN] Dry run complete. No network changes made.")
        return {
            "dry_run": True,
            "course_slug": course_slug,
            "lesson_slug": lesson_slug,
            "package_version": package_version,
            "storage_prefix": storage_prefix,
            "verified_files": [fn for fn, _, _ in verified_files],
            "record": version_record,
        }

    # Resolve Supabase URL and service key
    url = supabase_url or os.environ.get("SUPABASE_URL") or "http://127.0.0.1:54321"
    key = service_key or os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_SERVICE_KEY")
    if not key:
        raise ValueError(
            "Service key is required to publish. Set SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_SERVICE_KEY) "
            "or pass --service-key."
        )

    # 3. Refuse existing version
    print(f"Checking if version {package_version} already exists for lesson {lesson_id}...")
    if check_version_exists(url, key, lesson_id, package_version, opener=opener):
        raise ValueError(
            f"Version {package_version} already exists for lesson {lesson_id}. "
            "Increment package_version in manifest.json before publishing."
        )

    uploaded_paths: List[str] = []
    try:
        # 4. Upload assets to Storage under {course}/{lesson}/v{n}/
        # Upload manifest.json first
        manifest_remote_path = f"{storage_prefix}manifest.json"
        print(f"Uploading manifest.json to {bucket}/{manifest_remote_path}...")
        manifest_bytes = manifest_path.read_bytes()
        manifest_sha256 = compute_file_sha256(manifest_path)
        upload_storage_object(
            url,
            key,
            bucket,
            manifest_remote_path,
            manifest_bytes,
            content_type="application/json",
            upsert=True,
            opener=opener,
        )
        uploaded_paths.append(manifest_remote_path)

        # Upload package media & pose files
        for filename, filepath, _ in verified_files:
            file_remote_path = f"{storage_prefix}{filename}"
            print(f"Uploading {filename} to {bucket}/{file_remote_path}...")
            mime_type, _ = mimetypes.guess_type(filepath.name)
            file_bytes = filepath.read_bytes()
            upload_storage_object(
                url,
                key,
                bucket,
                file_remote_path,
                file_bytes,
                content_type=mime_type or "application/octet-stream",
                upsert=True,
                opener=opener,
            )
            uploaded_paths.append(file_remote_path)

        # 5. Post-upload verification: download each object and check sha256
        print("Verifying uploaded objects against local sha256 checksums...")
        print(f"Verifying {manifest_remote_path}...")
        verify_uploaded_object(url, key, bucket, manifest_remote_path, manifest_sha256, opener=opener)

        for filename, _, expected_hash in verified_files:
            file_remote_path = f"{storage_prefix}{filename}"
            print(f"Verifying {file_remote_path}...")
            verify_uploaded_object(url, key, bucket, file_remote_path, expected_hash, opener=opener)
        print("Post-upload sha256 verification succeeded for all objects.")

        # 6. Insert lesson_versions row
        print(f"Inserting lesson_versions row for lesson {lesson_id} v{package_version}...")
        created_row = insert_lesson_version(url, key, version_record, opener=opener)
        print("Publishing complete!")
        return {
            "dry_run": False,
            "course_slug": course_slug,
            "lesson_slug": lesson_slug,
            "package_version": package_version,
            "storage_prefix": storage_prefix,
            "created_row": created_row,
        }

    except Exception:
        if uploaded_paths:
            print(
                f"Publishing failed. Cleaning up {len(uploaded_paths)} uploaded objects from storage...",
                file=sys.stderr,
            )
            cleanup_uploaded_objects(url, key, bucket, uploaded_paths, opener=opener)
        raise


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Publish a lesson package to Supabase.")
    parser.add_argument("package_dir", type=Path, help="Directory containing manifest.json and assets")
    parser.add_argument("--dry-run", action="store_true", help="Validate package without uploading or writing to DB")
    parser.add_argument("--supabase-url", default=None, help="Supabase API URL (or SUPABASE_URL env)")
    parser.add_argument("--service-key", default=None, help="Supabase service role key (or SUPABASE_SERVICE_ROLE_KEY)")
    parser.add_argument("--bucket", default="lesson-packages", help="Storage bucket name (default: lesson-packages)")

    args = parser.parse_args(argv)

    try:
        publish_package(
            package_dir=args.package_dir,
            supabase_url=args.supabase_url,
            service_key=args.service_key,
            bucket=args.bucket,
            dry_run=args.dry_run,
        )
        return 0
    except Exception as e:
        print(f"Error publishing lesson package: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
