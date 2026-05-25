# Ollama (local daemon, including Ollama Cloud models via `:cloud` suffix).
# Equivalent to `ollama launch claude --model <model>` — env vars captured
# from that invocation. Requires `ollama signin` for cloud models; no
# separate API key is needed in this file (the local daemon at 127.0.0.1:11434
# handles auth).
# Override the model with LWD_MODEL (default: glm-5.1:cloud).
# For other configurations create a sibling provider file.

model="${LWD_MODEL:-glm-5.1:cloud}"

export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_BASE_URL=http://127.0.0.1:11434
export ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$model"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
export CLAUDE_CODE_SUBAGENT_MODEL="$model"
export CLAUDE_CODE_ATTRIBUTION_HEADER=0
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=202752
export CLAUDE_CODE_NO_FLICKER=1
export CLAUDE_EFFORT=xhigh
