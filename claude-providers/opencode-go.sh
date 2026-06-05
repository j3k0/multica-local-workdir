# OpenCode Go (open-weight models: GLM, Kimi, DeepSeek, Qwen, MiniMax, MiMo)
# via the `oc-go-cc` proxy.
#
# Unlike deepseek/openrouter, OpenCode Go has NO Anthropic-compatible endpoint —
# its models speak OpenAI/Responses/Gemini formats. `oc-go-cc serve` runs a local
# proxy that translates Anthropic Messages requests to OpenCode Go's format. So
# this file only points claude at that proxy; the subscription key lives in the
# PROXY's environment (OC_GO_CC_API_KEY), not here.
#
# REQUIRED: the proxy must already be running (started separately, once, shared
# by all agents — a single :3456 listener is fine under concurrency:1 agents):
#   OC_GO_CC_API_KEY=sk-opencode-... oc-go-cc serve        # listens on :3456
# Get the key from an OpenCode Go (or Zen) subscription: https://opencode.ai/auth
#
# Model selection is the PROXY's job: oc-go-cc auto-routes by request tier
# (default / thinking / long-context / background) per its own config, keyed off
# the claude-* model name claude sends. So we deliberately do NOT override
# ANTHROPIC_DEFAULT_*_MODEL here — doing so would feed the proxy unknown model
# strings and break its tier detection. Configure the tier→model mapping in
# oc-go-cc's config instead. (LWD_MODEL is intentionally unused for this provider.)

export ANTHROPIC_BASE_URL="${OPENCODE_GO_PROXY_URL:-http://127.0.0.1:3456}"
export ANTHROPIC_AUTH_TOKEN=unused   # proxy authenticates upstream via OC_GO_CC_API_KEY
export ANTHROPIC_API_KEY=""          # explicitly empty to avoid auth conflicts
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
