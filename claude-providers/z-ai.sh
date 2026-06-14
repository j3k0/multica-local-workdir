# Z.AI via their Anthropic-compatible API (GLM models).
# Requires ZAI_API_KEY in .env (or the environment).
# Models are pinned per tier (haiku=glm-4.5-air, sonnet/opus=glm-5.2[1m]);
# to switch, edit here or copy to a sibling provider file.

: "${ZAI_API_KEY:?ZAI_API_KEY must be set in .env to use the z-ai provider}"

export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
export ANTHROPIC_AUTH_TOKEN="$ZAI_API_KEY"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000
export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-4.5-air"
export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.2[1m]"
export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.2[1m]"
export API_TIMEOUT_MS=3000000
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
