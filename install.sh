#!/usr/bin/env bash
# Installer for the ai-review local CLI and Agent Skill (no git clone required).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Quartel-Enterprise/ai-review/main/install.sh | bash
#
# Optional environment variables:
#   AI_REVIEW_REPO     GitHub owner/repo (default: Quartel-Enterprise/ai-review)
#   AI_REVIEW_VERSION  Release tag or branch (default: latest release, fallback: main)
#   AI_REVIEW_HOME     Install directory (default: ~/.local/share/ai-review)
#   AI_REVIEW_BIN      Binary directory (default: ~/.local/bin)
#   AI_REVIEW_SKILLS   Set to 'false' to skip linking the skill into detected agents
set -euo pipefail

repo=${AI_REVIEW_REPO:-Quartel-Enterprise/ai-review}
version=${AI_REVIEW_VERSION:-}
install_home=${AI_REVIEW_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-review}
bin_dir=${AI_REVIEW_BIN:-$HOME/.local/bin}
install_skills=${AI_REVIEW_SKILLS:-true}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:?missing value for --repo}; shift 2 ;;
    --version) version=${2:?missing value for --version}; shift 2 ;;
    --home) install_home=${2:?missing value for --home}; shift 2 ;;
    --bin) bin_dir=${2:?missing value for --bin}; shift 2 ;;
    --no-skills) install_skills=false; shift ;;
    -h | --help)
      echo "Usage: install.sh [--version <tag|branch>] [--repo <owner/repo>] [--home <dir>] [--bin <dir>] [--no-skills]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "Invalid repo '$repo'." >&2; exit 2; }

# Strip trailing slashes so backup paths never resolve inside install_home.
while [[ "$install_home" == */ && "$install_home" != "/" ]]; do install_home=${install_home%/}; done
while [[ "$bin_dir" == */ && "$bin_dir" != "/" ]]; do bin_dir=${bin_dir%/}; done

for cmd in curl tar python3; do
  command -v "$cmd" > /dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

if [ -z "$version" ]; then
  latest=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2> /dev/null |
    python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("tag_name", ""))
except Exception:
    pass' || true)
  version=${latest:-main}
fi
[[ "$version" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Invalid version '$version'." >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Try tag tarball first, then branch tarball.
tarball="$tmp/ai-review.tar.gz"
url_tag="https://github.com/${repo}/archive/refs/tags/${version}.tar.gz"
url_head="https://github.com/${repo}/archive/refs/heads/${version}.tar.gz"

echo "Downloading ai-review (${repo}@${version})..."
if ! curl -fsSL "$url_tag" -o "$tarball" 2> /dev/null; then
  if ! curl -fsSL "$url_head" -o "$tarball" 2> /dev/null; then
    echo "Failed to download ${repo}@${version} from GitHub." >&2
    exit 1
  fi
fi

mkdir -p "$tmp/extract"
tar -xzf "$tarball" -C "$tmp/extract" --strip-components=1

entry="$tmp/extract/skills/ai-review/scripts/ai-review.sh"
if [ ! -f "$entry" ]; then
  echo "Downloaded archive does not contain skills/ai-review/scripts/ai-review.sh (is version '${version}' v2+?) " >&2
  exit 1
fi
chmod +x "$entry" "$tmp/extract/skills/ai-review/scripts/post-review.sh"
[ -f "$tmp/extract/local/ai-review.sh" ] && chmod +x "$tmp/extract/local/ai-review.sh"
[ -f "$tmp/extract/install.sh" ] && chmod +x "$tmp/extract/install.sh"

printf '%s\n' "$version" > "$tmp/extract/.ai-review-version"
printf '%s\n' "$repo" > "$tmp/extract/.ai-review-repo"

mkdir -p "$(dirname "$install_home")" "$bin_dir"
if [ -e "$install_home" ] || [ -L "$install_home" ]; then
  if [ ! -f "$install_home/.ai-review-version" ] && { [ ! -d "$install_home" ] || [ -n "$(ls -A "$install_home" 2> /dev/null)" ]; }; then
    echo "Refusing to overwrite '$install_home': directory is not empty and does not look like an ai-review installation (.ai-review-version missing)." >&2
    exit 1
  fi
fi
backup="${install_home}.old.$$"
rm -rf "$backup"
[ -e "$install_home" ] && mv "$install_home" "$backup"
if mv "$tmp/extract" "$install_home"; then
  rm -rf "$backup"
else
  [ -e "$backup" ] && mv "$backup" "$install_home"
  echo "Failed to move installation into $install_home" >&2
  exit 1
fi

ln -sf "$install_home/skills/ai-review/scripts/ai-review.sh" "$bin_dir/ai-review"
echo "Installed ai-review (${version}) to $bin_dir/ai-review"

if [ "$install_skills" = true ]; then
  "$bin_dir/ai-review" skills install
fi

if ! command -v jq > /dev/null 2>&1; then
  echo ""
  echo "Note: 'jq' is required at runtime by ai-review (install it via brew install jq / apt-get install jq)."
fi

case ":${PATH}:" in
  *":${bin_dir}:"*) ;;
  *)
    echo ""
    echo "Add ${bin_dir} to your PATH (e.g. in ~/.zshrc or ~/.bashrc):"
    echo "  export PATH=\"${bin_dir}:\$PATH\""
    ;;
esac
