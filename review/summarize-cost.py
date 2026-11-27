"""Aggregates cost and timing across Claude and Gemini review runs.

Reads Claude's execution file (JSON array of stream events), Gemini's headless JSON output
(`--output-format json`), and per-provider metadata files (`claude-meta.json`, `gemini-meta.json`).
Outputs a JSON summary with:
- `body`: markdown comment for the pull request (empty when nothing worth posting)
- `total_cost_usd`: float total cost after applying `show_micro_costs`
- `total_duration_seconds`: int sum of per-provider durations
- `provider_durations`: dict mapping provider name to duration in seconds

Security: only validated model IDs and numeric values are read; no prompt or response text
ever leaves this script.
"""
import json
import os
import pathlib
import re
import sys

MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._:/-]+(\[[0-9a-z]+\])?$")
MICRO_COST_THRESHOLD_USD = 0.01

# Standard Gemini API token pricing per 1M tokens: (input, cached_input, output_and_thoughts).
# Rates reflect Google AI Studio standard tier (Dec 2026+ for Gemini 4).
GEMINI_PRICING_PER_1M = {
    "gemini-4-carbon": (4.00, 1.00, 20.00),
    "gemini-4-neon": (3.00, 0.75, 15.00),
    "gemini-4-argon": (4.00, 1.00, 20.00),
    "gemini-4-hydrogen": (1.50, 0.375, 7.50),
    "gemini-3.8-flash": (0.50, 0.125, 3.00),
    "gemini-3.5-flash": (0.30, 0.075, 2.50),
    "gemini-3.5-flash-lite": (0.10, 0.025, 0.40),
    "gemini-3-pro": (2.00, 0.50, 12.00),
    "gemini-2.5-pro": (1.25, 0.3125, 10.00),
    "gemini-2.5-flash": (0.30, 0.075, 2.50),
    "gemini-2.5-flash-lite": (0.10, 0.025, 0.40),
}


def load_json(path_str):
    if not path_str:
        return None
    path = pathlib.Path(path_str)
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def is_valid_model_id(name):
    return isinstance(name, str) and bool(MODEL_ID_RE.match(name))


def fmt_usd(amount):
    if amount is None:
        return "–"
    if 0 < amount < 0.01:
        return f"${round(amount, 4):.4f}".rstrip("0").rstrip(".")
    return f"${amount:.2f}"


def fmt_duration(seconds):
    if seconds is None or seconds < 0:
        return "–"
    total = int(round(seconds))
    if total < 60:
        return f"{total}s"
    mins, secs = divmod(total, 60)
    if mins < 60:
        return f"{mins}m {secs}s"
    hours, mins = divmod(mins, 60)
    return f"{hours}h {mins}m {secs}s"


def lookup_gemini_rate(model_name):
    normalized = model_name.lower()
    if "/" in normalized:
        normalized = normalized.split("/", 1)[1]
    if normalized in GEMINI_PRICING_PER_1M:
        return GEMINI_PRICING_PER_1M[normalized]
    for prefix, rates in sorted(GEMINI_PRICING_PER_1M.items(), key=lambda kv: -len(kv[0])):
        if normalized.startswith(prefix + "-"):
            return rates
    return None


def parse_claude(exec_path, meta, wanted_model, effort, fixed, show_micro_costs):
    data = load_json(exec_path)
    if not isinstance(data, list):
        return None

    # Count distinct assistant calls per model (main vs subagent).
    seen = set()
    calls = {}
    for entry in data:
        if not isinstance(entry, dict) or entry.get("type") != "assistant":
            continue
        msg = entry.get("message")
        if not isinstance(msg, dict):
            continue
        model = msg.get("model")
        if not is_valid_model_id(model):
            continue
        key = (msg.get("id") or id(entry), model)
        if key in seen:
            continue
        seen.add(key)
        bucket = calls.setdefault(model, {"main": 0, "sub": 0})
        if entry.get("parent_tool_use_id") is not None:
            bucket["sub"] += 1
        else:
            bucket["main"] += 1

    results = [e for e in data if isinstance(e, dict) and e.get("type") == "result"]
    if not results:
        return None
    last = results[-1]
    raw_total = last.get("total_cost_usd")
    if not isinstance(raw_total, (int, float)) or raw_total <= 0:
        return None

    turns = last.get("num_turns") if isinstance(last.get("num_turns"), (int, float)) else None
    duration = None
    if isinstance(last.get("duration_ms"), (int, float)) and last["duration_ms"] > 0:
        duration = int(round(last["duration_ms"] / 1000.0))
    elif isinstance(meta, dict) and isinstance(meta.get("duration_seconds"), (int, float)):
        duration = int(round(meta["duration_seconds"]))

    usage = last.get("modelUsage")
    rows = []
    if isinstance(usage, dict):
        for model_id, info in usage.items():
            if not is_valid_model_id(model_id) or not isinstance(info, dict):
                continue
            cost = info.get("costUSD")
            if not isinstance(cost, (int, float)):
                continue
            c = calls.get(model_id, {"main": 0, "sub": 0})
            rows.append({
                "provider": "Claude",
                "model": model_id,
                "cost": float(cost),
                "main": c["main"],
                "sub": c["sub"],
                "tokens": None,
            })
    rows.sort(key=lambda r: -r["cost"])

    wanted = re.sub(r"\[[0-9a-z]+\]$", "", (wanted_model or "").lower())
    main_model = None
    if wanted:
        for r in rows:
            if wanted in r["model"].lower():
                main_model = r["model"]
                break
    if main_model is None and rows:
        main_model = rows[0]["model"]

    filtered_rows = []
    hidden_micro = 0
    for r in rows:
        is_main = r["model"] == main_model
        if not show_micro_costs and not is_main and r["cost"] < MICRO_COST_THRESHOLD_USD:
            hidden_micro += 1
            continue
        r["is_main"] = is_main
        r["effort"] = effort if is_main and effort else "–"
        r["duration"] = duration if is_main else None
        parts = []
        if r["main"] > 0:
            parts.append(f"{r['main']} in the session")
        if r["sub"] > 0:
            parts.append(f"{r['sub']} in subagents")
        call_desc = ", ".join(parts)
        if is_main:
            purpose = "the review and its fix commit" if fixed else "the review"
            if call_desc:
                purpose = f"{purpose} ({call_desc})"
        elif r["main"] == 0 and r["sub"] > 0:
            purpose = f"subagents ({r['sub']} call(s))"
        elif r["main"] > 0:
            purpose = f"turns of the session ({call_desc})"
        else:
            purpose = "Claude Code calls outside the conversation"
        r["used_for"] = purpose
        filtered_rows.append(r)

    if filtered_rows:
        reported_cost = sum(r["cost"] for r in filtered_rows) if hidden_micro > 0 else float(raw_total)
    else:
        reported_cost = float(raw_total)

    return {
        "provider": "claude",
        "label": "Claude",
        "cost": reported_cost,
        "duration": duration,
        "turns": int(turns) if turns is not None else None,
        "rows": filtered_rows,
        "hidden_micro": hidden_micro,
    }


def parse_gemini(exec_path, meta, wanted_model, effort, fixed, show_micro_costs):
    data = load_json(exec_path)
    meta_duration = None
    if isinstance(meta, dict) and isinstance(meta.get("duration_seconds"), (int, float)):
        meta_duration = int(round(meta["duration_seconds"]))
    meta_model = meta.get("model") if isinstance(meta, dict) else None
    meta_effort = meta.get("effort") if isinstance(meta, dict) else effort

    models_stats = None
    if isinstance(data, dict):
        stats = data.get("stats")
        if isinstance(stats, dict) and isinstance(stats.get("models"), dict):
            models_stats = stats["models"]

    if not models_stats and meta_duration is None:
        return None

    rows = []
    total_requests = 0
    total_latency_ms = 0
    if isinstance(models_stats, dict):
        for model_id, info in models_stats.items():
            if not is_valid_model_id(model_id) or not isinstance(info, dict):
                continue
            tokens = info.get("tokens") if isinstance(info.get("tokens"), dict) else {}
            api = info.get("api") if isinstance(info.get("api"), dict) else {}
            prompt_tok = int(tokens.get("prompt", 0) or 0)
            cached_tok = int(tokens.get("cached", 0) or 0)
            cand_tok = int(tokens.get("candidates", 0) or 0)
            thought_tok = int(tokens.get("thoughts", 0) or 0)
            reqs = int(api.get("totalRequests", 0) or 0)
            lat_ms = int(api.get("totalLatencyMs", 0) or 0)
            total_requests += reqs
            total_latency_ms += lat_ms

            uncached_prompt = max(0, prompt_tok - cached_tok)
            output_tok = cand_tok + thought_tok
            rates = lookup_gemini_rate(model_id)
            if rates is not None:
                in_rate, cache_rate, out_rate = rates
                cost = (
                    (uncached_prompt / 1_000_000.0) * in_rate
                    + (cached_tok / 1_000_000.0) * cache_rate
                    + (output_tok / 1_000_000.0) * out_rate
                )
            else:
                cost = None

            clean_model = model_id.split("/", 1)[1] if "/" in model_id else model_id
            rows.append({
                "provider": "Gemini",
                "model": clean_model,
                "cost": cost,
                "requests": reqs,
                "tokens": prompt_tok + output_tok,
                "latency_s": int(round(lat_ms / 1000.0)) if lat_ms > 0 else None,
            })

    duration = meta_duration
    if duration is None and total_latency_ms > 0:
        duration = int(round(total_latency_ms / 1000.0))

    if not rows and meta_model and is_valid_model_id(meta_model):
        rows.append({
            "provider": "Gemini",
            "model": meta_model,
            "cost": None,
            "requests": 0,
            "tokens": 0,
            "latency_s": duration,
        })

    rows.sort(key=lambda r: -(r["cost"] if r["cost"] is not None else -1.0))

    wanted = (wanted_model or meta_model or "").lower()
    main_model = None
    if wanted:
        for r in rows:
            if wanted in r["model"].lower():
                main_model = r["model"]
                break
    if main_model is None and rows:
        main_model = rows[0]["model"]

    filtered_rows = []
    hidden_micro = 0
    for r in rows:
        is_main = r["model"] == main_model
        if (
            not show_micro_costs
            and not is_main
            and r["cost"] is not None
            and r["cost"] < MICRO_COST_THRESHOLD_USD
        ):
            hidden_micro += 1
            continue
        r["is_main"] = is_main
        r["effort"] = meta_effort if is_main and meta_effort else "–"
        r["duration"] = duration if is_main else r["latency_s"]
        base_purpose = "the review and its fix commit" if (is_main and fixed) else (
            "the review" if is_main else "auxiliary Gemini CLI calls"
        )
        if r["requests"] > 0:
            r["used_for"] = f"{base_purpose} ({r['requests']} request(s))"
        else:
            r["used_for"] = base_purpose
        filtered_rows.append(r)

    known_costs = [r["cost"] for r in filtered_rows if r["cost"] is not None]
    reported_cost = sum(known_costs) if known_costs else None

    return {
        "provider": "gemini",
        "label": "Gemini",
        "cost": reported_cost,
        "duration": duration,
        "turns": total_requests if total_requests > 0 else None,
        "rows": filtered_rows,
        "hidden_micro": hidden_micro,
    }


def main():
    claude_exec = os.environ.get("CLAUDE_EXECUTION_FILE", "")
    gemini_exec = os.environ.get("GEMINI_EXECUTION_FILE", "")
    state_dir = os.environ.get("STATE", "")
    claude_meta = load_json(os.path.join(state_dir, "claude-meta.json")) if state_dir else None
    gemini_meta = load_json(os.path.join(state_dir, "gemini-meta.json")) if state_dir else None

    claude_model = os.environ.get("CLAUDE_MODEL", "")
    claude_effort = os.environ.get("CLAUDE_EFFORT", "")
    gemini_model = os.environ.get("GEMINI_MODEL", "")
    gemini_effort = os.environ.get("GEMINI_EFFORT", "")
    fixed = os.environ.get("FIXED", "false") == "true"
    claude_oauth = os.environ.get("CLAUDE_OAUTH", "false") == "true"
    show_micro_costs = os.environ.get("SHOW_MICRO_COSTS", "false") == "true"
    run_url = os.environ.get("RUN_URL", "")
    run_tag = os.environ.get("RUN_TAG", "")

    summaries = []
    gemini_summary = parse_gemini(
        gemini_exec, gemini_meta, gemini_model, gemini_effort, fixed, show_micro_costs
    )
    if gemini_summary:
        summaries.append(gemini_summary)
    claude_summary = parse_claude(
        claude_exec, claude_meta, claude_model, claude_effort, fixed, show_micro_costs
    )
    if claude_summary:
        summaries.append(claude_summary)

    if not summaries:
        print(json.dumps({
            "body": "",
            "total_cost_usd": 0.0,
            "total_duration_seconds": 0,
            "provider_durations": {},
        }))
        return

    provider_durations = {
        s["provider"]: s["duration"] for s in summaries if s["duration"] is not None
    }
    total_duration = sum(provider_durations.values())
    costs = [s["cost"] for s in summaries if s["cost"] is not None]
    total_cost = sum(costs) if costs else None

    all_rows = []
    for s in summaries:
        all_rows.extend(s["rows"])

    headline_parts = []
    if total_cost is not None:
        headline_parts.append(f"**{fmt_usd(total_cost)}**")
    if provider_durations:
        if len(provider_durations) > 1:
            per_prov = " + ".join(
                f"{s['label']}: {fmt_duration(s['duration'])}"
                for s in summaries
                if s["duration"] is not None
            )
            headline_parts.append(f"Total time: **{fmt_duration(total_duration)}** ({per_prov})")
        else:
            headline_parts.append(f"Time: **{fmt_duration(total_duration)}**")

    lines = ["### Review cost & timing", "", " · ".join(headline_parts)]

    if all_rows:
        lines.extend([
            "",
            "| Provider | Model | Effort | Used for | Time | Cost |",
            "| --- | --- | --- | --- | --- | --- |",
        ])
        for r in all_rows:
            effort_cell = f"`{r['effort']}`" if r["effort"] != "–" else "–"
            lines.append(
                f"| {r['provider']} | `{r['model']}` | {effort_cell} | {r['used_for']} | "
                f"{fmt_duration(r['duration'])} | {fmt_usd(r['cost'])} |"
            )

    notes = []
    has_claude = any(s["provider"] == "claude" for s in summaries)
    has_gemini = any(s["provider"] == "gemini" for s in summaries)
    if has_claude and has_gemini:
        notes.append("Estimated from Claude Code and Gemini CLI token counts, not an invoice")
    elif has_claude:
        notes.append("Reported by Claude Code from the tokens it counted, not an invoice")
    else:
        notes.append("Estimated from Gemini CLI token counts and standard API rates, not an invoice")
    if has_claude and claude_oauth:
        notes.append(
            "Claude uses a subscription token, so its tokens are not billed per token and show the API equivalent"
        )
    if run_url:
        notes.append(f"[The run]({run_url})")

    footer = "_" + ". ".join(notes) + "._"
    lines.extend(["", footer])
    if run_tag:
        lines.extend(["", run_tag])

    print(json.dumps({
        "body": "\n".join(lines),
        "total_cost_usd": round(total_cost, 6) if total_cost is not None else 0.0,
        "total_duration_seconds": total_duration,
        "provider_durations": provider_durations,
    }))


if __name__ == "__main__":
    main()
