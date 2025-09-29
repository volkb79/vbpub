#!/usr/bin/env python3
"""
checkout_subtree.py: Clone only a specific subtree from a GitHub repo using a Personal Access Token (PAT).

Default variables (can be overridden by environment):
    OWNER: GitHub repo owner (default: volkb79)
    REPO:  GitHub repo name (default: DST-DNS)
    GITHUB_PAT: Optional, for private repos
    SUBTREE: Path to subtree (optional, interactive selection if not set)

Example:
    OWNER=volkb79 REPO=DST-DNS GITHUB_PAT=ghp_xxx SUBTREE=projects/controller python3 checkout_subtree.py

    ilI 0O 5S 
"""
# ----------------- USER DEFINED VARIABLES -----------------

# === User options ===
DEFAULT_OWNER = "volkb79"
DEFAULT_REPO = "DST-DNS"
DEFAULT_PAT = ""
DEFAULT_SUBTREE = ""
# Toggle: 'download' or 'sparse_checkout'
CHECKOUT_MODE = "download"  # options: "download", "sparse_checkout"

# --------------------- Script Start -----------------------
import os
import sys
import subprocess

def info(msg):
    print(f"[INFO] {msg}")

def error(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)

def step(msg):
    print(f"==> {msg}")


def get_env(var, default=None):
    val = os.environ.get(var, default)
    return val if val is not None else default

def run(cmd, env=None):
    info(f"Running: {' '.join(cmd)}")
    try:
        result = subprocess.run(cmd, env=env, check=True, text=True, capture_output=True)
        info(result.stdout.strip())
        if result.stderr:
            info(f"stderr: {result.stderr.strip()}")
        return result
    except subprocess.CalledProcessError as e:
        error(f"Command failed: {e}")
        if e.stdout:
            error(f"stdout: {e.stdout.strip()}")
        if e.stderr:
            error(f"stderr: {e.stderr.strip()}")
        sys.exit(e.returncode)

import requests
import json

def list_repo_folders(owner, repo, pat=None):
    url = f"https://api.github.com/repos/{owner}/{repo}/contents/"
    headers = {"Accept": "application/vnd.github.v3+json"}
    if pat:
        headers["Authorization"] = f"token {pat}"
    resp = requests.get(url, headers=headers)
    if not resp.ok:
        error(f"Failed to list repo contents: {resp.status_code} {resp.text}")
        sys.exit(1)
    folders = []
    for item in resp.json():
        if item["type"] == "dir":
            folders.append(item["name"])
    folder_tree = {}
    for folder in folders:
        sub_url = f"https://api.github.com/repos/{owner}/{repo}/contents/{folder}"
        sub_resp = requests.get(sub_url, headers=headers)
        if sub_resp.ok:
            subfolders = [i["name"] for i in sub_resp.json() if i["type"] == "dir"]
            folder_tree[folder] = subfolders
    return folder_tree

def prompt_subtree(folder_tree):
    info("Available folders (depth 2):")
    idx_map = {}
    idx = 1
    for folder, subfolders in folder_tree.items():
        print(f"{idx}. {folder}/")
        idx_map[str(idx)] = folder
        idx += 1
        for sub in subfolders:
            print(f"  {idx}. {folder}/{sub}/")
            idx_map[str(idx)] = f"{folder}/{sub}"
            idx += 1
    choice = input("Select folder to checkout (number): ").strip()
    subtree = idx_map.get(choice)
    if not subtree:
        error("Invalid choice.")
        sys.exit(1)
    with open(".subtree_choice.json", "w") as f:
        json.dump({"subtree": subtree}, f)
    return subtree


def download_subtree(owner, repo, pat, subtree, target_dir):
    import requests
    import os
    def download_recursive(path, rel_path):
        if path:
            url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}"
        else:
            url = f"https://api.github.com/repos/{owner}/{repo}/contents/"
        headers = {"Accept": "application/vnd.github.v3+json"}
        if pat:
            headers["Authorization"] = f"token {pat}"
        resp = requests.get(url, headers=headers)
        if not resp.ok:
            error(f"Failed to list contents: {resp.status_code} {resp.text}")
            sys.exit(1)
        for item in resp.json():
            if item["type"] == "file":
                file_url = item["download_url"]
                local_path = os.path.join(target_dir, rel_path, item["name"])
                os.makedirs(os.path.dirname(local_path), exist_ok=True)
                info(f"Downloading {file_url} -> {local_path}")
                r = requests.get(file_url, headers=headers)
                if r.ok:
                    with open(local_path, "wb") as f:
                        f.write(r.content)
                else:
                    error(f"Failed to download {file_url}: {r.status_code}")
            elif item["type"] == "dir":
                download_recursive(item["path"], os.path.join(rel_path, item["name"]))

    info(f"Downloading subtree '{subtree}' from repo '{owner}/{repo}' into '{target_dir}'")
    os.makedirs(target_dir, exist_ok=True)
    download_recursive(subtree, "")
    info(f"Subtree '{subtree}' downloaded successfully in {target_dir}")
    step("Done")

def sparse_checkout_subtree(owner, repo, pat, subtree, target_dir):
    repo_url = f"https://github.com/{owner}/{repo}.git"
    if pat:
        url_parts = repo_url.split('https://', 1)
        auth_repo_url = f"https://{pat}@{url_parts[1]}"
    else:
        auth_repo_url = repo_url
    step(f"Cloning repo into {target_dir}")
    run(['git', 'clone', '--filter=blob:none', '--no-checkout', auth_repo_url, target_dir])
    os.chdir(target_dir)
    step(f"Enabling sparse checkout for subtree: {subtree}")
    run(['git', 'sparse-checkout', 'init', '--cone'])
    run(['git', 'sparse-checkout', 'set', subtree])
    run(['git', 'checkout'])
    info(f"Subtree '{subtree}' checked out successfully in {target_dir}")
    step("Done")

def main():
    step("Starting subtree checkout script")
    owner = get_env('OWNER', DEFAULT_OWNER)
    repo = get_env('REPO', DEFAULT_REPO)
    pat = get_env('GITHUB_PAT', DEFAULT_PAT)
    subtree = get_env('SUBTREE', DEFAULT_SUBTREE)

    if not subtree:
        step("No subtree specified, listing repo folders...")
        folder_tree = list_repo_folders(owner, repo, pat if pat else None)
        subtree = prompt_subtree(folder_tree)
        info(f"Selected subtree: {subtree}")

    folder_parts = subtree.replace('/', '-').strip('-')
    target_dir = f"{repo}-{folder_parts}"

    if CHECKOUT_MODE == "download":
        download_subtree(owner, repo, pat, subtree, target_dir)
    elif CHECKOUT_MODE == "sparse_checkout":
        sparse_checkout_subtree(owner, repo, pat, subtree, target_dir)
    else:
        error(f"Unknown CHECKOUT_MODE: {CHECKOUT_MODE}")
        sys.exit(1)

if __name__ == '__main__':
    main()
