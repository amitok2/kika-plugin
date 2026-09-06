# Kika for Claude Code

One install, one credential, both halves of the memory:

- **the MCP server** — `get_brief`, `search_memory`, `remember`, `update_memory`,
  `close_loop`; and
- **the Stop hook** — which reads each finished turn and records what was
  decided, without the agent having to remember to.

The hook is the part no other memory product has. A handshake that says "write
things down when they matter" is advice, and a model under load ignores advice.
A hook is not advice.

## Install

```
/plugin marketplace add amitok2/kika-plugin
/plugin install kika@kika
```

Then `/mcp`, choose kika, and approve in the browser.

That is the whole install. The plugin carries both halves — the MCP server and
the Stop hook — so there is nothing to clone, no script to run, and no second
credential: the hook reads the OAuth token Claude Code already holds for this
server and keeps refreshed.

Engagements create themselves the first time something worth remembering is
said in a repository. There is nothing to set up per project.

### With a token instead

For CI, or a machine with no browser. Get one at **getkika.app/app/connect**:

```
claude mcp add --scope user --transport http kika https://api.getkika.app/mcp \
  --header "Authorization: Bearer kika_mcp_…"
```

`--scope user` matters: without it the server is bound to the one project you
happened to be in. The hook reads that same header out of your MCP
configuration, so it is still one credential.

### Platform note

The OAuth path is verified on macOS, where Claude Code keeps the token in the
login keychain. Elsewhere the hook looks for `~/.claude/.credentials.json`
first, which may or may not be where your build stores it. If capture is silent
on Linux or Windows, use the `--header` form above.

### For a teammate

They install the same way and sign in as themselves. What they do in their own
repositories is their own memory.

To put them on an engagement of yours, add them at
**getkika.app/app/projects** — the engagement, then **People**, then the email
address they sign in with. They do not need an account first; the invitation
waits and is claimed the first time they sign in.

From then on their checkout of that repository resolves to *your* graph rather
than a second copy of it: what they decide, you read, and the trail shows whose
turn each entry came from. Everyone on an engagement can read and write its
memory; only the owner decides who else is on it.

Until you add them, a repository that already belongs to an engagement is
refused rather than duplicated — the agent is told the engagement exists, that
they are not on it, and that whoever set it up can add them.

## How the hook works

Claude Code fires a `Stop` event when a turn ends and hands the hook the
finished turn on stdin. Because it runs `async`, your turn never waits for it.

```
turn ends
  ├─ reply too short, or "done." → exit, costs nothing
  ├─ POST /hooks/turn with the turn and the repo's git remote
  │    ├─ Haiku: is there durable state here?   (usually no)
  │    ├─ already in the graph?                 (restatement vs change of mind)
  │    └─ write, marked agent-written
  └─ exit 0, always
```

Most turns stop at the first line and cost nothing at all. The agent is not
involved in any of this — it is not deciding to remember.

## What the hook sends, and what it does not

It runs after your turn ends and, when a turn looks like it contains a decision,
posts to `https://api.getkika.app/hooks/turn`:

- the last assistant message, and the last user message from the transcript
  (4,000 characters of it at most)
- the working directory, and `git remote get-url origin` for it
- the Claude Code session id

It does **not** send file contents, your repository, your environment, or any
other conversation. Most turns are dropped locally before any request is made —
you can read exactly which in `hooks/capture.sh`, which is the whole program and
is 180 lines.

It reads a credential in one of three places, in this order: the `Authorization`
header you configured on the MCP server, the OAuth access token Claude Code
holds **for this server** (macOS keychain, or `~/.claude/.credentials.json`), or
`~/.kika/token`. It never reads a credential belonging to any other server. With
none of them present it exits immediately and silently, so an uninstalled or
unauthenticated setup costs nothing and says nothing.

## What it costs, and how to take it back

Watch the spend at **getkika.app/app/trail**, which shows every turn the hook
saw — including the ones it saved nothing from, and why — with what each one
actually cost in tokens. Everything the hook records is
marked agent-written and unverified: it can never overwrite something from one
of your meetings, never reaches your meeting notes, and every one is listed at
**getkika.app/app/activity** with an Undo that removes it from the graph.

## Turning it off

Remove the plugin, or `claude mcp remove kika` — with no token to find, the hook
exits immediately and silently.
