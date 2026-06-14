# `opencode-go` claude-provider needs the oc-go-cc proxy (as of 2026-06)

"OpenCode Go" is OpenCode's ~$10/mo subscription for open-weight models
(glm-5.1, kimi-k2.6, deepseek-v4-pro/flash, qwen3.6-plus, minimax-m2.7, mimo-v2).
It is a **claude-provider** (`LWD_PROVIDER=opencode-go`), NOT a multica agent type.

Key constraint: unlike deepseek/openrouter, OpenCode Go has **no
Anthropic-compatible endpoint** — so the provider file cannot just point
`ANTHROPIC_BASE_URL` at OpenCode directly. It points at a local translating
proxy, `oc-go-cc` (github.com/samueltuyizere/oc-go-cc), which converts Anthropic
Messages → OpenCode's native format.

Wiring:
- `claude-providers/opencode-go.sh` sets only `ANTHROPIC_BASE_URL=http://127.0.0.1:3456`
  (override via `OPENCODE_GO_PROXY_URL`) + `ANTHROPIC_AUTH_TOKEN=unused`.
- The proxy runs SEPARATELY and is not started by any wrapper:
  `OC_GO_CC_API_KEY=sk-opencode-... oc-go-cc serve` (port 3456, `-b` for bg).
  The subscription key lives in the proxy's env, not in `.env`/the provider file.
- Do NOT override `ANTHROPIC_DEFAULT_*_MODEL` in the provider file: oc-go-cc
  auto-routes by request tier (default/thinking/long-context/background) keyed
  off the claude-* model name claude sends; feeding it custom model strings
  breaks tier detection. Configure the tier→model map in oc-go-cc's own config.

Caveat not yet handled: nothing supervises the proxy. If `oc-go-cc serve` isn't
up, claude calls fail (connection refused on :3456). Could be wired into
`multica-daemon` later if desired.

Note: OpenCode *Zen* (different product) DOES expose an Anthropic-format
endpoint at `https://opencode.ai/zen/v1/messages` — for Zen Claude models you
could skip the proxy with `ANTHROPIC_BASE_URL=https://opencode.ai/zen` +
`ANTHROPIC_AUTH_TOKEN=<zen key>`. But that's Zen, not Go's open-weight models.