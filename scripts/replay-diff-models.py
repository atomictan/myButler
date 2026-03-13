#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


DELETION_KEYWORDS = [
    "remove",
    "delete",
    "cancel",
    "drop",
    "clear",
    "discard",
    "删除",
    "取消",
    "移除",
    "删掉",
    "去掉",
    "不要了",
    "撤销",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Replay a fixed voice-session diff prompt against multiple Doubao models.")
    parser.add_argument("--monitor", required=True, help="Path to a voice-monitor-*.json file")
    parser.add_argument("--items", required=True, help="Path to a voice-items-before-diff-*.json file")
    parser.add_argument("--models", nargs="+", required=True, help="One or more Doubao model ids")
    parser.add_argument("--repeat", type=int, default=3, help="Requests per model")
    parser.add_argument("--token-env", default="DOUBAO_API_TOKEN", help="Environment variable holding the API token")
    parser.add_argument("--endpoint", default="https://ark.cn-beijing.volces.com/api/v3/chat/completions")
    parser.add_argument("--max-tokens", type=int, default=900)
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--reference-time", default=None, help="Override reference timestamp, e.g. 2026-03-08T18:43:49+08:00")
    return parser.parse_args()


def load_json(path: str):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def build_transcript(monitor_payload: dict) -> str:
    lines = []
    for event in monitor_payload.get("events", []):
        speaker = event.get("speaker")
        text = (event.get("text") or "").strip()
        if not text:
            continue
        if speaker == "assistant":
            lines.append(f"Assistant: {text}")
        elif speaker == "user":
            lines.append(f"You: {text}")
        elif speaker == "system":
            lines.append(f"System: {text}")
    return "\n".join(lines).strip()


def append_deletion_hints(summary: str, transcript: str) -> str:
    hints = []
    for line in transcript.splitlines():
        trimmed = line.strip()
        if not trimmed:
            continue
        lowered = trimmed.lower()
        if any(keyword.lower() in lowered or keyword in trimmed for keyword in DELETION_KEYWORDS):
            hints.append(trimmed)
    if not hints:
        return summary
    return f"{summary.strip()}\n\nDeletion hints from transcript (treat as explicit user removals unless contradicted):\n" + "\n".join(hints)


def normalize_items(items_payload: list[dict]) -> list[dict]:
    normalized = []
    for item in items_payload:
        normalized.append(
            {
                "id": item.get("id"),
                "type": item.get("type"),
                "title": item.get("title", ""),
                "dueDate": item.get("dueDate"),
                "priority": "normal",
                "project": item.get("project"),
                "tags": item.get("tags", []),
            }
        )
    return normalized


def reference_timestamp(override: str | None) -> str:
    if override:
        return override
    now = datetime.now().astimezone()
    return now.isoformat(timespec="seconds")


def build_prompt(summary: str, items: list[dict], reference_time: str) -> str:
    timezone_name = datetime.now().astimezone().tzname() or "local"
    items_json = json.dumps(items, ensure_ascii=False, indent=2, sort_keys=True)
    trimmed_summary = summary.strip()
    return f"""You are an assistant that produces a diff for updating a personal inbox.
Use the existing items and the conversation summary to propose changes.
Output JSON only, following this schema exactly. Do not include markdown.

Rules:
- Today is {reference_time} (timezone: {timezone_name}). Resolve relative dates against this reference.
- If the user mentions any date or time (e.g., \"next Monday\", \"Wednesday after next week\", \"tomorrow 6pm\"), always set \"dueDate\".
- Use ISO-8601. If time is provided, use \"YYYY-MM-DDTHH:mm\". If only a date is known, use \"YYYY-MM-DD\".
- Do not delete items unless the user explicitly asked to remove or cancel them.
- Use updates when modifying existing items; reference the exact id.
- For duplicates, create a merge entry that references a create tempId and the targetId.
- If the user confirms a merge, delete any existing duplicate items (besides the target) and explain why in the delete reason.
- If a new item is very similar to an existing one, do not create a separate item; add a merge entry and explain the duplication.
- Follow the user’s decisions in the transcript (e.g., if they said \"merge\" or \"keep as new\").
- Every create must include a unique tempId.
- If no changes are needed, return an object with empty arrays.

Existing items (JSON array):
{items_json}

Conversation summary:
{trimmed_summary}

JSON schema:
{{
  "creates": [
    {{
      "tempId": "new-1",
      "type": "task|idea|note",
      "title": "…",
      "details": "…",
      "dueDate": "YYYY-MM-DDTHH:mm or YYYY-MM-DD or null",
      "priority": "low|normal|high",
      "project": "… or null",
      "tags": ["…"]
    }}
  ],
  "updates": [
    {{
      "id": "existing-item-id",
      "changes": {{
        "title": "…",
        "details": "…",
        "dueDate": "YYYY-MM-DDTHH:mm or YYYY-MM-DD or null",
        "priority": "low|normal|high",
        "project": "… or null",
        "tags": ["…"]
      }}
    }}
  ],
  "merges": [
    {{
      "sourceTempId": "new-2",
      "targetId": "existing-item-id",
      "mergeSummary": "Reason"
    }}
  ],
  "deletes": [
    {{
      "id": "existing-item-id",
      "reason": "Reason"
    }}
  ]
}}"""


def run_curl(endpoint: str, token: str, body: dict) -> tuple[dict, str]:
    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as body_file:
        json.dump(body, body_file, ensure_ascii=False)
        body_path = body_file.name
    with tempfile.NamedTemporaryFile("w+b", delete=False) as response_file:
        response_path = response_file.name
    try:
        command = [
            "curl",
            "-sS",
            "-X",
            "POST",
            endpoint,
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            f"@{body_path}",
            "-o",
            response_path,
            "-w",
            json.dumps(
                {
                    "http_code": "%{http_code}",
                    "time_namelookup": "%{time_namelookup}",
                    "time_connect": "%{time_connect}",
                    "time_appconnect": "%{time_appconnect}",
                    "time_pretransfer": "%{time_pretransfer}",
                    "time_starttransfer": "%{time_starttransfer}",
                    "time_total": "%{time_total}",
                    "size_upload": "%{size_upload}",
                    "size_download": "%{size_download}",
                    "http_version": "%{http_version}",
                    "proxy_used": "%{proxy_used}"
                }
            ),
        ]
        proc = subprocess.run(command, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or "curl failed")
        with open(response_path, "r", encoding="utf-8") as handle:
            response_text = handle.read()
        return json.loads(proc.stdout), response_text
    finally:
        Path(body_path).unlink(missing_ok=True)
        Path(response_path).unlink(missing_ok=True)


def parse_response_content(response_text: str) -> str:
    payload = json.loads(response_text)
    choices = payload.get("choices") or []
    if not choices:
        return ""
    message = choices[0].get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        pieces = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                pieces.append(part.get("text", ""))
        return "".join(pieces).strip()
    if isinstance(content, str):
        return content.strip()
    return choices[0].get("resolvedContent", "") or ""


def as_float(metrics: dict, key: str) -> float:
    try:
        return float(metrics.get(key, "0") or 0)
    except ValueError:
        return 0.0


def main() -> int:
    args = parse_args()
    token = os.environ.get(args.token_env, "").strip()
    if not token:
        print(f"Missing API token in ${args.token_env}", file=sys.stderr)
        return 2

    monitor = load_json(args.monitor)
    items_payload = load_json(args.items)
    transcript = build_transcript(monitor)
    if not transcript:
        print("No transcript reconstructed from monitor log", file=sys.stderr)
        return 2

    summary = append_deletion_hints(transcript, transcript)
    items = normalize_items(items_payload)
    reference_time = reference_timestamp(args.reference_time)
    prompt = build_prompt(summary=summary, items=items, reference_time=reference_time)

    print(f"Transcript chars: {len(transcript)}")
    print(f"Summary chars: {len(summary)}")
    print(f"Prompt chars: {len(prompt)}")
    print(f"Items: {len(items)}")
    print()

    for model in args.models:
        print(f"== {model} ==")
        totals = []
        ttfbs = []
        for attempt in range(1, args.repeat + 1):
            body = {
                "model": model,
                "messages": [
                    {"role": "system", "content": "Return JSON only."},
                    {"role": "user", "content": prompt},
                ],
                "temperature": args.temperature,
                "max_tokens": args.max_tokens,
            }
            metrics, response_text = run_curl(args.endpoint, token, body)
            total = as_float(metrics, "time_total")
            starttransfer = as_float(metrics, "time_starttransfer")
            pretransfer = as_float(metrics, "time_pretransfer")
            ttfb = max(starttransfer - pretransfer, 0.0)
            totals.append(total)
            ttfbs.append(ttfb)
            content = parse_response_content(response_text)
            print(
                f"run {attempt}: http={metrics.get('http_code')} total={total:.2f}s "
                f"ttfb={ttfb:.2f}s connect={as_float(metrics, 'time_connect'):.2f}s "
                f"tls={max(as_float(metrics, 'time_appconnect') - as_float(metrics, 'time_connect'), 0.0):.2f}s "
                f"starttransfer={starttransfer:.2f}s download={max(total - starttransfer, 0.0):.2f}s "
                f"size={metrics.get('size_download')}B proxy={metrics.get('proxy_used')}"
            )
            preview = content.replace("\n", " ")[:140]
            if preview:
                print(f"  preview: {preview}")
        avg_total = sum(totals) / len(totals)
        avg_ttfb = sum(ttfbs) / len(ttfbs)
        print(f"avg: total={avg_total:.2f}s ttfb={avg_ttfb:.2f}s")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
