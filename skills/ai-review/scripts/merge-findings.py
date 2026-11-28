"""Merges review findings from one or more AI providers into a single JSON array.

Each input argument is `<provider>:<path>` where `<path>` holds a JSON array of findings.
Every finding object is tagged with `"provider": "<provider>"`. Output is printed to stdout
only when at least one provider supplied a valid JSON list; otherwise nothing is printed so
post-review.sh posts the standard "ended without a findings list" notice.

Usage:
  merge-findings.py claude:/tmp/claude.json gemini:/tmp/gemini.json
"""
import json
import pathlib
import sys

RANK = {"must-fix": 0, "should-fix": 1, "nitpick": 2}


def norm_severity(value):
    if not isinstance(value, str):
        return "should-fix"
    norm = "-".join(value.strip().lower().replace("_", " ").split())
    return norm if norm in RANK else "should-fix"


def main():
    merged = []
    valid_sources = 0
    for arg in sys.argv[1:]:
        if ":" not in arg:
            continue
        provider, path_str = arg.split(":", 1)
        path = pathlib.Path(path_str)
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, list):
            continue
        valid_sources += 1
        for item in data:
            if not isinstance(item, dict):
                continue
            tagged = dict(item)
            tagged.setdefault("provider", provider)
            merged.append(tagged)

    if valid_sources == 0:
        return

    merged.sort(key=lambda item: RANK[norm_severity(item.get("severity"))])
    print(json.dumps(merged))


if __name__ == "__main__":
    main()
