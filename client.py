"""Simple client for the Surya OCR API.

Usage:
    python client.py <path-to-image-or-pdf> [--url http://localhost:8040] [--disable-math]
"""
import argparse
import json
import os
import sys

import requests


def run(path: str, url: str, disable_math: bool) -> int:
    if not os.path.isfile(path):
        print(f"error: file not found: {path}", file=sys.stderr)
        return 1

    endpoint = url.rstrip("/") + "/ocr"
    print(f"Uploading {path} -> {endpoint}")

    with open(path, "rb") as f:
        files = {"file": (os.path.basename(path), f)}
        params = {"disable_math": str(disable_math).lower()}
        resp = requests.post(endpoint, files=files, params=params, timeout=600)

    if resp.status_code != 200:
        print(f"error: {resp.status_code} {resp.text}", file=sys.stderr)
        return 2

    data = resp.json()
    print(f"\n=== {data['filename']} ===")
    print(f"Pages: {len(data['pages'])}")
    for page in data["pages"]:
        print(f"\n--- page {page['page']} ({len(page['text_lines'])} lines) ---")
        print(page["text"])

    out_json = os.path.splitext(path)[0] + ".ocr.json"
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"\nFull response saved to: {out_json}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Surya OCR API client")
    p.add_argument("path", help="Path to image or PDF to OCR")
    p.add_argument("--url", default="http://localhost:8040", help="API base URL")
    p.add_argument("--disable-math", action="store_true", help="Disable math mode")
    args = p.parse_args()
    return run(args.path, args.url, args.disable_math)


if __name__ == "__main__":
    sys.exit(main())
