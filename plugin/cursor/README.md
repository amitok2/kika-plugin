# Kika in Cursor

Cursor has no plugin system, so this is two steps rather than one. Nothing on
the server differs: `/hooks/turn` and `/hooks/brief` are client-agnostic, and
the same scripts run unmodified.

## 1. The memory tools

Add the MCP server in Cursor's settings, or in `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "kika": {
      "type": "http",
      "url": "https://api.getkika.app/mcp",
      "headers": { "Authorization": "Bearer kika_mcp_…" }
    }
  }
}
```

Get the token at **getkika.app/app/connect**. Cursor has no OAuth flow for MCP,
so unlike Claude Code this one does need a pasted token.

## 2. Capture

Copy `hooks/capture.sh` and `hooks/token.sh` somewhere together — they must stay
side by side, because the first sources the second — and point a `stop` hook at
`capture.sh`. Set `KIKA_TOKEN` to the same token you pasted above.

The hook finds its credential the same way it does in Claude Code, and Cursor's
config is one of the places it looks. Exporting `KIKA_TOKEN` is the reliable
route here.

## Checking it works

`KIKA_DEBUG=1` makes the hook say what it looked for and whether it found a
token, on stderr. Capture is silent by design — a hook that complains after
every message gets disabled within a day — so this is the way to find out why
nothing is being recorded.

Then watch **getkika.app/app/trail**: every turn the hook sent, including the
ones that saved nothing and why.
