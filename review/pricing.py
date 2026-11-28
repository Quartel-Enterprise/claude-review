"""Shared token pricing table and cost/duration formatting helpers.

Kept byte-for-byte identical between review/pricing.py and skills/ai-review/scripts/pricing.py
(enforced by scripts/lint.sh).
"""

MICRO_COST_THRESHOLD_USD = 0.01

# Standard API token rates per 1M tokens: (input, cached_input, output_and_thoughts).
# Rates reflect standard API pricing (Dec 2026+ for Gemini 4 and Claude 5.5).
MODEL_PRICING_PER_1M = {
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
    "claude-opus-5-5": (5.00, 0.50, 25.00),
    "claude-sonnet-5-5": (3.00, 0.30, 15.00),
    "claude-haiku-5-5": (1.00, 0.10, 5.00),
}


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


def lookup_rate(model_name):
    norm = (model_name or "").lower()
    if "/" in norm:
        norm = norm.split("/", 1)[1]
    if norm in MODEL_PRICING_PER_1M:
        return MODEL_PRICING_PER_1M[norm]
    for prefix, rates in sorted(MODEL_PRICING_PER_1M.items(), key=lambda kv: -len(kv[0])):
        if norm.startswith(prefix + "-"):
            return rates
    return None
