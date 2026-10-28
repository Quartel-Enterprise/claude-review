#!/bin/bash

# Lints the repository as CI does: shellcheck on the scripts and on every composite action's run
# blocks (actionlint only reads workflows), then actionlint on the workflows.
set -euo pipefail
cd "$(dirname "$0")/.."

shellcheck review/*.sh threads/*.sh scripts/*.sh
python3 -m py_compile review/extract-findings.py

blocks=$(mktemp -d)
trap 'rm -rf "$blocks"' EXIT
python3 - "$blocks" <<'PY'
import pathlib, re, sys, yaml

out = pathlib.Path(sys.argv[1])
for action in sorted(pathlib.Path(".").glob("*/action.yml")):
    for i, step in enumerate(yaml.safe_load(action.read_text())["runs"]["steps"]):
        if "run" in step:
            # An expression stands for a plain word, as GitHub substitutes it before bash runs.
            body = re.sub(r"\$\{\{.*?\}\}", "EXPR", step["run"], flags=re.S)
            (out / f"{action.parent}-{i}.sh").write_text("#!/bin/bash\n" + body)
PY
# SC2016: jq and GraphQL take their own $ variables in single quotes.
shellcheck --exclude=SC2016 "$blocks"/*.sh

actionlint
