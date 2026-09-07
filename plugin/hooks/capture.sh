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

# The token: one credential, the one you already pasted. See token.sh — it is
# shared with the session-start hook so the two cannot drift apart.
# shellcheck source=token.sh
. "$(dirname "${BASH_SOURCE[0]}")/token.sh"

[ -z "$TOKEN" ] && exit 0
# `last_assistant_message` rather than the transcript, per Claude Code's own
# guidance: the transcript is written asynchronously and may not yet contain
# the turn that just ended.
# Bounded, like the user's side below. It was not, and the privacy policy and
# the README both claimed "4,000 characters at most" — true of the user message
# and not of this one, which can be a whole file dump. A document that overstates
# a limit is worse than one that states a larger limit honestly, and the server
# only reads the last 12,000 characters anyway, so nothing is lost by capping.
#
# The TAIL is kept, not the head: the conclusion of a reply is at the end, which
# is the same reason the server keeps the tail of the excerpt it classifies.
LAST=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""' | tail -c 8000)
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
