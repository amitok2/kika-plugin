#!/usr/bin/env bash
#
# Stage 1 of deterministic capture: the free one.
#
# Runs when a turn ends and decides, without spending anything, whether this
# turn is even worth asking about. Most are not — "what does this function do",
# "run the tests", "fix that typo" — and dropping them here is what makes
# capture affordable enough to leave on permanently.
#
# It exits 0 in every path on purpose. A hook that fails loudly after every
# message is a hook the user disables within a day, and capture that is off is
# worth less than capture that occasionally misses a turn.
#
# Runs with async: true, so nothing here is on the user's critical path.

set -uo pipefail

INPUT=$(cat)
API="${KIKA_API_URL:-https://api.getkika.app}"

command -v jq >/dev/null 2>&1 || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')

# ── The token: ONE credential, the one you already pasted ──────────────────
#
# You configured the MCP server with a token. Asking for a second one — an env
# var, a dotfile — for the half of the product that runs three seconds later is
# friction we invented, not friction the design requires. So this reads the
# Authorization header out of the MCP configuration itself.
#
# The result is that the whole install is one command:
#
#   claude mcp add --transport http kika https://api.getkika.app/mcp \
#     --header "Authorization: Bearer kika_mcp_…"
#
# Looked for in the order Claude Code resolves MCP servers: a project .mcp.json
# first, then the per-project section of ~/.claude.json, then the global one.
# The cwd may be a subdirectory of the project root, so parents are walked.
token_from_mcp() {
  local f dir
  # A committed project config, if the team shares one.
  for dir in "${CLAUDE_PROJECT_DIR:-$CWD}" "$CWD"; do
    [ -n "$dir" ] || continue
    f="$dir/.mcp.json"
    if [ -r "$f" ]; then
      jq -r '.mcpServers.kika.headers.Authorization // empty' "$f" 2>/dev/null && return
    fi
  done

  f="$HOME/.claude.json"
  [ -r "$f" ] || return
  # Per-project, walking up from the working directory.
  dir="$CWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    jq -r --arg d "$dir" '.projects[$d].mcpServers.kika.headers.Authorization // empty' "$f" 2>/dev/null       | grep . && return
    dir=$(dirname "$dir")
  done
  # Global.
  jq -r '.mcpServers.kika.headers.Authorization // empty' "$f" 2>/dev/null
}

# Connected over OAuth instead? Then there is no header to read — but Claude
# Code is holding a live access token for this very server, and keeps it
# refreshed. Using it means OAuth users get capture with no second credential
# either, which is the difference between "capture works" and "capture works if
# you also went and made a token".
#
# The token is OURS: our authorization server issued it, for our resource, to
# this user. Reading it is not reaching into somebody else's secret.
#
# Matched on the serverUrl, OR on the entry key naming this server. The key
# carries a hash suffix (`kika|2df240d1…`) so only its name part is compared.
# Both, because either alone is brittle: a self-hosted or staging API breaks a
# URL-only match, and a server the user named something else breaks a key-only
# one.
token_from_oauth() {
  local raw
  # The portable store first; the macOS keychain second. Neither existing is
  # normal and must stay silent.
  if [ -r "$HOME/.claude/.credentials.json" ]; then
    raw=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null)
  elif command -v security >/dev/null 2>&1; then
    raw=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)
  fi
  [ -n "$raw" ] || return
  printf '%s' "$raw" | jq -r --arg api "$API" '
    (.mcpOAuth // {})
    | to_entries
    | map(select(
        ((.value.serverUrl // "") | startswith($api))
        or ((.key | split("|")[0] | ascii_downcase) == "kika")
      ))
    # Expired tokens are skipped rather than sent: Claude Code refreshes on its
    # own schedule, so the next turn will find a live one.
    | map(select((.value.expiresAt // 0) > (now * 1000)))
    | .[0].value.accessToken // empty' 2>/dev/null
}

TOKEN="${KIKA_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  # Strip the scheme: the config holds "Bearer kika_mcp_…", we want the token.
  TOKEN=$(token_from_mcp | head -1 | sed -E 's/^[Bb]earer[[:space:]]+//' | tr -d '[:space:]')
fi
[ -z "$TOKEN" ] && TOKEN=$(token_from_oauth | tr -d '[:space:]')
# Last resort, and now genuinely a last resort.
if [ -z "$TOKEN" ] && [ -r "$HOME/.kika/token" ]; then
  TOKEN=$(tr -d '[:space:]' < "$HOME/.kika/token")
fi

[ -z "$TOKEN" ] && exit 0
# `last_assistant_message` rather than the transcript, per Claude Code's own
# guidance: the transcript is written asynchronously and may not yet contain
# the turn that just ended.
LAST=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""')
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')

# The user's side of the turn, from the transcript. Worth reading even though
# it lags, because the DECISION is usually in what the user said ("no, use
# Postgres, we need RLS") while the assistant's reply is the work that followed.
USER_MSG=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  USER_MSG=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null \
    | jq -rs '[.[] | select(.type == "user")] | last | .message.content // ""' 2>/dev/null \
    | head -c 4000)
fi

EXCERPT=$(printf 'User:\n%s\n\nAssistant:\n%s' "$USER_MSG" "$LAST")

# A decision can be short. "We're going with Postgres, we don't want a second
# datastore" is sixty characters and is exactly what this exists to keep, so
# length alone is the wrong test — a 179-character turn settling Vitest over
# Jest, with its reason, was dropped by a 200-character floor.
#
# The floor was guarding a cost that is not real: the classifier is Haiku on a
# couple of thousand tokens, a fraction of a cent, and it already answers "no"
# to most of what reaches it. So the cheap check now looks for the SHAPE of a
# decision and lets anything with one through at any length, while everything
# else still has to clear a much lower bar.
#
# Matched across the whole excerpt, not just the reply: the decision is often
# the user's ("no, use Rabbit, their ops team knows it") and the reply is the
# work that followed.
DECISION_SHAPE='(because|rather than|instead of|decided|decision|blocked|blocker|ruled out|going with|we will use|turns out|the reason)'
if printf '%s' "$EXCERPT" | grep -qiE "$DECISION_SHAPE"; then
  : # a reason is present — worth a look however short
elif [ ${#LAST} -lt 120 ]; then
  exit 0
fi

# The heuristic. Every pattern here is a turn shape that has never once
# contained durable project state, and together they are most turns.
#
# Deliberately matched against the ASSISTANT's reply only. Filtering on what
# the user said would drop "we're going with Postgres because of RLS" for
# being short, and that is precisely the sentence worth keeping.
if printf '%s' "$LAST" | grep -qiE '^(done|fixed|added|updated|removed)\.?$'; then
  exit 0
fi

# The git remote identifies the engagement across machines and people, which is
# what lets a teammate's capture land in the same project rather than a second
# graph. Normalisation happens server-side, so every spelling is fine here.
REMOTE=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
fi

jq -n \
  --arg excerpt "$EXCERPT" \
  --arg cwd "$CWD" \
  --arg gitRemote "$REMOTE" \
  --arg sessionId "$(printf '%s' "$INPUT" | jq -r '.session_id // ""')" \
  '{excerpt: $excerpt, cwd: $cwd, gitRemote: $gitRemote, sessionId: $sessionId}' \
  | curl -s -m 120 -X POST "$API/hooks/turn" \
      -H "authorization: Bearer $TOKEN" \
      -H 'content-type: application/json' \
      --data-binary @- >/dev/null 2>&1

exit 0
