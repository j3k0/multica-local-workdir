# OpenRouter via their Anthropic-compatible API.
# Requires OPENROUTER_API_KEY in .env (or the environment).
# Override the model with LWD_MODEL, falling back to LWD_OPENROUTER_MODEL,
# then to qwen/qwen3.7-max.

model="${LWD_MODEL:-${LWD_OPENROUTER_MODEL:-qwen/qwen3.7-max}}"

export ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1
export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
export ANTHROPIC_MODEL="$model"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$model"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
export CLAUDE_CODE_SUBAGENT_MODEL="$model"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
