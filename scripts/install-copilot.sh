#!/usr/bin/env bash
# Install the agy-staff skills for GitHub Copilot in VS Code.
#
# Copilot has no marketplace or plugin mechanism: skills are plain directories
# it discovers on disk. So this script copies `skills/*` out of this checkout
# and rewrites, in the copies only, the three things that break once a skill
# leaves the repo:
#
#   1. `<skill-dir>/../../companion/agy-companion.mjs` -> an absolute path back
#      into this checkout (the relative hop no longer resolves).
#   2. `../jobs/...` cross-links -> `../agy-jobs/...` (see 3).
#   3. the frontmatter `name:` -> `agy-<name>`, because Copilot turns it into a
#      bare slash command and `~/.copilot/skills/` is account-wide, where
#      `/ask` or `/review` would collide with anything else installed.
#
# The sources under skills/ are never touched, so pulling upstream stays
# conflict-free. Re-run this script after every `git pull` to pick up changes.
#
# Requires the Antigravity CLI (`agy`) and Node.js.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPANION="$REPO_ROOT/companion/agy-companion.mjs"

dest=""
project=0
dry_run=0

usage() {
  cat <<EOF
Usage: scripts/install-copilot.sh [--project] [--dest <dir>] [--dry-run]

  (no flags)      install for your account:  ~/.copilot/skills/
  --project       install into the current project instead: ./.github/skills/
  --dest <dir>    install into an explicit directory
  --dry-run       print what would happen, write nothing

Skills are installed as agy-ask, agy-staffer, agy-researcher, agy-reviewer,
agy-implementer and agy-jobs. Re-running overwrites them in place.
To remove them again: rm -rf ~/.copilot/skills/agy-*
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) project=1; shift ;;
    --dest) dest="${2-}"; [ -n "$dest" ] || { echo "error: --dest needs a directory" >&2; exit 1; }; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# --- preconditions -----------------------------------------------------------

if ! command -v node >/dev/null 2>&1; then
  echo "error: node not found on PATH. The companion runs on Node.js - install it first." >&2
  exit 1
fi

if ! command -v agy >/dev/null 2>&1 || ! agy --version >/dev/null 2>&1; then
  echo "error: 'agy --version' failed. Install the Antigravity CLI first:" >&2
  echo "         curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
  echo "       docs: https://antigravity.google/docs/cli/install" >&2
  exit 1
fi

if [ ! -f "$COMPANION" ]; then
  echo "error: companion not found at $COMPANION - run this script from its checkout." >&2
  exit 1
fi

# --- target ------------------------------------------------------------------

if [ -n "$dest" ]; then
  target="$dest"
elif [ "$project" -eq 1 ]; then
  target="$PWD/.github/skills"
else
  target="$HOME/.copilot/skills"
fi

echo "agy-staff -> Copilot"
echo "  source:    $REPO_ROOT/skills"
echo "  companion: $COMPANION"
echo "  target:    $target"
echo "  node:      $(node --version)   agy: $(agy --version 2>/dev/null | head -1)"
echo

# sed replacement text is data, not pattern: escape what sed reads back.
esc_repl() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
companion_repl="$(esc_repl "$COMPANION")"

installed=0
for src in "$REPO_ROOT"/skills/*/; do
  [ -d "$src" ] || continue
  base="$(basename "$src")"
  name="agy-$base"
  out="$target/$name"

  if [ "$dry_run" -eq 1 ]; then
    echo "  would install $base -> $out"
    installed=$((installed + 1))
    continue
  fi

  mkdir -p "$target"
  rm -rf "$out"              # idempotent: a re-run replaces, never merges
  cp -R "$src" "$out"

  # Rewrite the copies. `sed -i` differs between GNU and BSD (and BSD needs an
  # explicit backup suffix), so write to a temp file and move it into place -
  # same behaviour on Linux and macOS, no feature detection.
  while IFS= read -r md; do
    [ -n "$md" ] || continue
    tmp="$md.agy-tmp"
    sed \
      -e "s|<skill-dir>/\.\./\.\./companion/agy-companion\.mjs|$companion_repl|g" \
      -e 's|\.\./jobs/|../agy-jobs/|g' \
      "$md" > "$tmp"
    mv "$tmp" "$md"
  done <<EOF
$(find "$out" -type f -name '*.md')
EOF

  # The frontmatter name only exists in SKILL.md; the range 1,/^---$/ keeps the
  # edit inside the frontmatter block.
  if [ -f "$out/SKILL.md" ]; then
    tmp="$out/SKILL.md.agy-tmp"
    sed '1,/^---$/s|^name: |name: agy-|' "$out/SKILL.md" > "$tmp"
    mv "$tmp" "$out/SKILL.md"
  fi

  echo "  installed $base -> $out  (/$name)"
  installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
  echo "error: no skills found under $REPO_ROOT/skills" >&2
  exit 1
fi

if [ "$dry_run" -eq 1 ]; then
  echo
  echo "dry run - nothing was written."
  exit 0
fi

cat <<EOF

Done ($installed skills). Verify in two steps:

  1. In a terminal, prove the companion itself works - this is the real
     dependency, and it fails loudly if agy is not signed in:

       node "$COMPANION" ask "reply with OK"

  2. Restart VS Code, open Copilot Chat, switch the mode picker to **Agent**
     (skills do not load in Ask or Edit mode), then run:

       /agy-ask reply with OK

Notes:
  - Copilot asks you to approve every terminal command, so a background job
    needs at least two approvals: one to start it, one for the wait that
    collects the result.
  - Upgrading: git pull in $REPO_ROOT, then re-run this script.
EOF
