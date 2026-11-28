"""Formats merged AI review findings, timing, and estimated API-equivalent cost for terminal output."""
import json
import os
import sys

from pricing import MICRO_COST_THRESHOLD_USD, fmt_duration, fmt_usd, lookup_rate

BADGES = {
    "must-fix": "🔴 MUST FIX",
    "should-fix": "🟡 SHOULD FIX",
    "nitpick": "⚪ NITPICK",
}
PROV_NAMES = {"claude": "Claude", "gemini": "Gemini"}


def normalize_severity(raw):
    return "-".join(str(raw or "should-fix").strip().lower().replace("_", "-").split())


def compute_provider_cost(entry, show_micro_costs):
    """Returns (cost_usd_or_none, token_summary_str)."""
    # Claude CLI JSON format: modelUsage + total_cost_usd.
    model_usage = entry.get("model_usage")
    if isinstance(model_usage, dict) and model_usage:
        rows = []
        for mid, info in model_usage.items():
            if isinstance(info, dict) and isinstance(info.get("costUSD"), (int, float)):
                rows.append((mid, float(info["costUSD"])))
        rows.sort(key=lambda r: -r[1])
        wanted = (entry.get("model") or "").lower()
        main_mid = next((m for m, _ in rows if wanted and wanted in m.lower()), rows[0][0] if rows else None)
        kept = [
            (m, c)
            for m, c in rows
            if show_micro_costs or m == main_mid or c >= MICRO_COST_THRESHOLD_USD
        ]
        total = sum(c for _, c in kept) if kept else entry.get("total_cost_usd")
        return (float(total) if total is not None else None, "")

    if isinstance(entry.get("total_cost_usd"), (int, float)):
        return (float(entry["total_cost_usd"]), "")

    # Token-based calculation (agy or gemini-cli; input_tokens is uncached input).
    uncached = max(0, int(entry.get("input_tokens") or 0))
    cached_tok = max(0, int(entry.get("cached_tokens") or 0))
    out_tok = max(0, int(entry.get("output_tokens") or 0))
    think_tok = max(0, int(entry.get("thinking_tokens") or 0))
    if uncached == 0 and cached_tok == 0 and out_tok == 0 and think_tok == 0:
        return (None, "")

    total_out = out_tok + think_tok
    rates = lookup_rate(entry.get("model", ""))
    cost = None
    if rates is not None:
        in_r, cache_r, out_r = rates
        cost = (
            (uncached / 1_000_000.0) * in_r
            + (cached_tok / 1_000_000.0) * cache_r
            + (total_out / 1_000_000.0) * out_r
        )

    parts = [f"{uncached:,} in"]
    if cached_tok > 0:
        parts.append(f"{cached_tok:,} cached")
    parts.append(f"{out_tok:,} out")
    if think_tok > 0:
        parts.append(f"{think_tok:,} thoughts")
    return (cost, " / ".join(parts))


def main():
    raw = sys.stdin.read().strip()
    wall_s = int(os.environ.get("WALL_SECONDS", "0") or 0)
    show_micro_costs = os.environ.get("SHOW_MICRO_COSTS", "false") == "true"
    stats_raw = os.environ.get("PROVIDER_STATS", "[]")
    try:
        provider_stats = json.loads(stats_raw)
    except ValueError:
        provider_stats = []
    if not isinstance(provider_stats, list):
        provider_stats = []

    findings = None
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                findings = parsed
        except ValueError:
            findings = None

    # Compute per-provider timing and cost summary.
    enriched = []
    for entry in provider_stats:
        if not isinstance(entry, dict):
            continue
        cost, tok_desc = compute_provider_cost(entry, show_micro_costs)
        enriched.append({
            "provider": entry.get("provider", ""),
            "model": entry.get("model", ""),
            "engine": entry.get("engine", ""),
            "subscription": bool(entry.get("subscription", False)),
            "duration": int(entry.get("duration_seconds") or 0),
            "cost": cost,
            "tokens": tok_desc,
            "exit_code": int(entry.get("exit_code") or 0),
            "has_findings": entry.get("has_findings", True),
        })

    provider_warnings = os.environ.get("PROVIDER_WARNINGS", "").strip()

    sum_s = sum(e["duration"] for e in enriched)
    known_costs = [e["cost"] for e in enriched if e["cost"] is not None]
    total_cost = sum(known_costs) if known_costs else None
    all_sub = bool(enriched) and all(e["subscription"] for e in enriched)

    print("=== AI Code Review ===")

    if findings is None:
        print("AI review ended without a findings list.")
    elif not findings:
        print("No findings.")
    else:
        counts = {"must-fix": 0, "should-fix": 0, "nitpick": 0}
        prov_counts = {}
        for item in findings:
            if not isinstance(item, dict):
                continue
            sev = normalize_severity(item.get("severity"))
            if sev not in counts:
                sev = "should-fix"
            counts[sev] += 1
            prov = str(item.get("provider") or "").strip().lower()
            if prov:
                label = PROV_NAMES.get(prov, prov.title())
                prov_counts[label] = prov_counts.get(label, 0) + 1

        sev_summary = " · ".join(
            p
            for p in [
                f"🔴 {counts['must-fix']} must fix" if counts["must-fix"] else "",
                f"🟡 {counts['should-fix']} should fix" if counts["should-fix"] else "",
                f"⚪ {counts['nitpick']} nitpick(s)" if counts["nitpick"] else "",
            ]
            if p
        )
        prov_summary = (
            " — " + " · ".join(f"{k}: {v}" for k, v in prov_counts.items())
            if len(prov_counts) > 1
            else ""
        )
        print(f"{len(findings)} finding(s) ({sev_summary}){prov_summary}")

    if enriched:
        meta_bits = []
        if len(enriched) > 1:
            meta_bits.append(f"Wall time: {fmt_duration(wall_s)} · Sum: {fmt_duration(sum_s)}")
        else:
            meta_bits.append(f"Time: {fmt_duration(wall_s)}")
        if total_cost is not None:
            sub_note = " (API equiv. — subscription)" if all_sub else " (est.)"
            meta_bits.append(f"Cost: {fmt_usd(total_cost)}{sub_note}")
        print(" · ".join(meta_bits))
        for e in enriched:
            label = PROV_NAMES.get(e["provider"], e["provider"].title())
            sub_tag = " [subscription]" if e["subscription"] else ""
            status_tag = ""
            if e["exit_code"] != 0:
                status_tag = f" [FAILED exit={e['exit_code']}]"
            elif e["has_findings"] is False:
                status_tag = " [no findings list]"
            tok_part = f" ({e['tokens']})" if e["tokens"] else ""
            print(
                f"  - {label} (`{e['model']}` via {e['engine']}{sub_tag}){status_tag}: "
                f"{fmt_duration(e['duration'])} · {fmt_usd(e['cost'])}{tok_part}"
            )
    if provider_warnings:
        print(f"Warning: {provider_warnings}")

    if not findings:
        return

    print()
    for idx, item in enumerate(findings, 1):
        if not isinstance(item, dict):
            continue
        sev = normalize_severity(item.get("severity"))
        badge = BADGES.get(sev, BADGES["should-fix"])
        cat = item.get("category") or ""
        prov = str(item.get("provider") or "").strip().lower()
        prov_label = PROV_NAMES.get(prov, prov.title()) if prov else ""
        path = item.get("file") or item.get("path") or "(no file)"
        line = item.get("line")
        start = item.get("start_line")
        if line is not None and start is not None and start != line:
            loc = f"{path}:{start}-{line}"
        elif line is not None:
            loc = f"{path}:{line}"
        else:
            loc = path

        outcome = item.get("outcome")
        header_bits = [badge]
        if cat:
            header_bits.append(cat)
        if prov_label:
            header_bits.append(f"[{prov_label}]")
        if outcome:
            header_bits.append(f"({outcome})")

        print(f"{idx}. {' · '.join(header_bits)} — {loc}")
        if item.get("summary"):
            print(f"   {item['summary']}")
        if item.get("failure_scenario"):
            print(f"   Why: {item['failure_scenario']}")
        if item.get("fix"):
            print(f"   Fix: {item['fix']}")
        print()


if __name__ == "__main__":
    main()
