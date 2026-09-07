#!/usr/bin/env bash
#
# Where this engagement stands, before you type anything.
#
# The MCP handshake tells the agent to call get_brief at the start of a session.
# Measured on real use: across 54 captured turns it called it eight times. So
# most sessions began blind on an engagement whose entire point is that you
# should not have to start blind — and the user never knew the difference,
# because a memory that goes unread looks exactly like a memory that is empty.
#
# A SessionStart hook does not depend on remembering. Claude Code injects a
# hook's stdout as session context, so this prints the standup and the agent
# simply has it.
#
# Silent whenever there is nothing to say: no token, no repository, a repository
# nobody has an engagement for, or an engagement with nothing in it yet. A hook
# that prints noise at the top of every session is a hook that gets uninstalled.
#
# Runs with async: true, so a slow reply never delays the session starting.

set -uo pipefail

INPUT=$(cat)
API="${KIKA_API_URL:-https://api.getkika.app}"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# The engagement is identified by the repository, exactly as capture does it.
# Outside a repository there is nothing to resolve and nothing to say.
REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
[ -n "$REMOTE" ] || exit 0

# shellcheck source=token.sh
. "$(dirname "${BASH_SOURCE[0]}")/token.sh"
[ -z "$TOKEN" ] && exit 0

# Short timeout on purpose. This is decoration on a session that is starting,
# not something worth waiting for — if Kika is slow or down, the session begins
# without it and nobody is told about a problem they cannot act on.
BRIEF=$(curl -s -m 12 -G "$API/hooks/brief" \
  --data-urlencode "repo=$REMOTE" \
  -H "authorization: Bearer $TOKEN" 2>/dev/null || true)

# Plain stdout is injected as context. Nothing to say → say nothing.
[ -n "$BRIEF" ] && printf '%s\n' "$BRIEF"
exit 0
