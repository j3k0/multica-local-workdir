# DeepSeek via their Anthropic-compatible API.
# Requires DEEPSEEK_API_KEY in .env (or the environment).
# Override the primary model with LWD_MODEL (default: deepseek-v4-pro[1m]).
# For other configurations (e.g. flash-only) create a sibling provider file.

: "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY must be set in .env to use the deepseek provider}"

export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
export ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY"
export ANTHROPIC_MODEL="${LWD_MODEL:-deepseek-v4-pro[1m]}"
export ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro
export ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro
export ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
export CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-pro
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
export CLAUDE_CODE_EFFORT_LEVEL=max
