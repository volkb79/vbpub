#!/usr/bin/env python3
"""Publish CIU wheel to GitHub Releases using the REST API.

Required environment:
- CIU_RELEASE_TOKEN or GITHUB_TOKEN
- CIU_RELEASE_REPO or GITHUB_REPOSITORY (owner/repo)

Optional environment:
- CIU_RELEASE_TAG (default: ciu-v<version>)
- CIU_RELEASE_TITLE
- CIU_RELEASE_NOTES
- CIU_LATEST_TAG (default: ciu-latest)
- CIU_LATEST_ASSET_NAME (default: ciu-latest-py3-none-any.whl)
- CIU_LATEST_TITLE
- CIU_LATEST_NOTES
- CIU_DEBUG_API=1 for verbose API logging
- CIU_ENV_FILE to override env file location (defaults to repo-root/.env)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.error import HTTPError
from urllib.request import Request, urlopen


@dataclass
class ApiResponse:
    status: int
    body: str


def log_debug(message: str) -> None:
    if os.getenv("CIU_DEBUG_API") == "1":
        print(f"[DEBUG] {message}")


def fail(message: str, status: Optional[int] = None, body: str | None = None) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)
    if status is not None:
        print(f"[ERROR] HTTP status: {status}", file=sys.stderr)
    if body:
        print(f"[ERROR] Response body: {body}", file=sys.stderr)
    raise SystemExit(1)


def load_env_file(env_path: Path) -> None:
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ[key] = value


def api_request(method: str, url: str, token: str, data: bytes | None = None, content_type: str | None = None) -> ApiResponse:
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    }
    if content_type:
        headers["Content-Type"] = content_type

    req = Request(url, method=method, headers=headers, data=data)
    try:
        with urlopen(req) as resp:
            body = resp.read().decode("utf-8")
            log_debug(f"{method} {url} -> {resp.status}")
            return ApiResponse(resp.status, body)
    except HTTPError as exc:
        body = exc.read().decode("utf-8") if exc.fp else ""
        log_debug(f"{method} {url} -> {exc.code}")
        return ApiResponse(exc.code, body)


def parse_json(body: str, context: str) -> Dict[str, Any]:
    if not body.strip():
        fail(f"Empty JSON input for {context}")
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        fail(f"Invalid JSON input for {context}: {exc}")
    return {}


def build_wheel(project_root: Path) -> Path:
    dist_dir = project_root / "dist"
    if dist_dir.exists():
        shutil.rmtree(dist_dir)
    dist_dir.mkdir(parents=True, exist_ok=True)

    subprocess.run(
        [sys.executable, "-m", "pip", "wheel", ".", "-w", str(dist_dir)],
        check=True,
        cwd=str(project_root),
    )
    wheels = sorted(dist_dir.glob("ciu-*.whl"))
    if not wheels:
        fail("CIU wheel not found in dist/")
    return wheels[0]


def get_release_by_tag(api_base: str, owner: str, repo: str, tag: str, token: str) -> Optional[Dict[str, Any]]:
    resp = api_request("GET", f"{api_base}/repos/{owner}/{repo}/releases/tags/{tag}", token)
    if resp.status == 404:
        return None
    if resp.status >= 400:
        fail(f"Failed to fetch release tag {tag}", resp.status, resp.body)
    return parse_json(resp.body, f"release tag {tag}")


def create_release(api_base: str, owner: str, repo: str, tag: str, title: str, notes: str, token: str) -> Dict[str, Any]:
    payload = json.dumps({"tag_name": tag, "name": title, "body": notes}).encode("utf-8")
    resp = api_request("POST", f"{api_base}/repos/{owner}/{repo}/releases", token, data=payload, content_type="application/json")
    if resp.status >= 400:
        fail(f"Failed to create release {tag}", resp.status, resp.body)
    return parse_json(resp.body, f"create release {tag}")


def list_assets(api_base: str, owner: str, repo: str, release_id: int, token: str) -> list[Dict[str, Any]]:
    resp = api_request("GET", f"{api_base}/repos/{owner}/{repo}/releases/{release_id}/assets", token)
    if resp.status >= 400:
        fail(f"Failed to list assets for release {release_id}", resp.status, resp.body)
    return parse_json(resp.body, f"list assets {release_id}")


def delete_asset(api_base: str, owner: str, repo: str, asset_id: int, token: str) -> None:
    resp = api_request("DELETE", f"{api_base}/repos/{owner}/{repo}/releases/assets/{asset_id}", token)
    if resp.status >= 400:
        fail(f"Failed to delete existing asset {asset_id}", resp.status, resp.body)


def upload_asset(upload_url: str, asset_path: Path, asset_name: str, token: str) -> None:
    upload_url = upload_url.split("{", 1)[0]
    data = asset_path.read_bytes()
    resp = api_request(
        "POST",
        f"{upload_url}?name={asset_name}",
        token,
        data=data,
        content_type="application/octet-stream",
    )
    if resp.status >= 400:
        fail(f"Failed to upload asset {asset_name}", resp.status, resp.body)


def publish_release_asset(api_base: str, owner: str, repo: str, tag: str, title: str, notes: str, asset_path: Path, asset_name: str, token: str) -> None:
    release = get_release_by_tag(api_base, owner, repo, tag, token)
    if release is None:
        release = create_release(api_base, owner, repo, tag, title, notes, token)

    release_id = release.get("id")
    upload_url = release.get("upload_url")
    if not release_id or not upload_url:
        fail(f"Release response missing id/upload_url for tag {tag}")

    assets = list_assets(api_base, owner, repo, int(release_id), token)
    for asset in assets:
        if asset.get("name") == asset_name and asset.get("id"):
            delete_asset(api_base, owner, repo, int(asset["id"]), token)
            break

    upload_asset(str(upload_url), asset_path, asset_name, token)


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    repo_root = project_root.parent

    env_file = Path(os.getenv("CIU_ENV_FILE", repo_root / ".env"))
    if env_file.exists():
        load_env_file(env_file)
    else:
        fallback_env = project_root / ".env"
        if fallback_env.exists():
            load_env_file(fallback_env)

    import tomllib

    data = tomllib.loads((project_root / "pyproject.toml").read_text(encoding="utf-8"))
    version = data.get("project", {}).get("version")
    if not version:
        fail("Unable to read project.version from pyproject.toml")

    token = os.getenv("CIU_RELEASE_TOKEN") or os.getenv("GITHUB_TOKEN")
    if not token:
        fail("CIU_RELEASE_TOKEN or GITHUB_TOKEN is required")

    release_repo = os.getenv("CIU_RELEASE_REPO") or os.getenv("GITHUB_REPOSITORY")
    if not release_repo or "/" not in release_repo:
        fail("CIU_RELEASE_REPO or GITHUB_REPOSITORY is required (format: owner/repo)")

    owner, repo = release_repo.split("/", 1)
    api_base = "https://api.github.com"

    tag = os.getenv("CIU_RELEASE_TAG", f"ciu-v{version}")
    release_title = os.getenv("CIU_RELEASE_TITLE", f"CIU {version}")
    release_notes = os.getenv("CIU_RELEASE_NOTES", f"CIU wheel {version}")

    wheel_path = build_wheel(project_root)
    wheel_hash = sha256(wheel_path.read_bytes()).hexdigest()

    publish_release_asset(api_base, owner, repo, tag, release_title, release_notes, wheel_path, wheel_path.name, token)

    latest_tag = os.getenv("CIU_LATEST_TAG", "ciu-latest")
    latest_asset_name = os.getenv("CIU_LATEST_ASSET_NAME", "ciu-latest-py3-none-any.whl")
    latest_title = os.getenv("CIU_LATEST_TITLE", "CIU latest")
    latest_notes = os.getenv("CIU_LATEST_NOTES", f"CIU latest wheel (points to {version})")

    latest_wheel_path = wheel_path.with_name(latest_asset_name)
    shutil.copyfile(wheel_path, latest_wheel_path)
    try:
        publish_release_asset(api_base, owner, repo, latest_tag, latest_title, latest_notes, latest_wheel_path, latest_asset_name, token)
    finally:
        if latest_wheel_path.exists():
            latest_wheel_path.unlink()

    wheel_url = f"https://github.com/{release_repo}/releases/download/{tag}/{wheel_path.name}"
    latest_wheel_url = f"https://github.com/{release_repo}/releases/download/{latest_tag}/{latest_asset_name}"

    print("[INFO] Published CIU wheel")
    print(f"[INFO] CIU_WHEEL_URL={wheel_url}")
    print(f"[INFO] CIU_WHEEL_SHA256={wheel_hash}")
    print(f"[INFO] CIU_WHEEL_LATEST_URL={latest_wheel_url}")
    print(f"[INFO] CIU_WHEEL_LATEST_SHA256={wheel_hash}")


if __name__ == "__main__":
    main()
