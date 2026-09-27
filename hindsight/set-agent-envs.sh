#!/usr/bin/env bash
# Add LWD_HINDSIGHT_BANK_ID + LWD_HINDSIGHT_SCOPING to each selected agent WITHOUT
# dropping existing env. `multica agent env set` REPLACES the whole custom_env map, so
# each agent's current map is re-sent with every existing key as the "****" sentinel
# (documented to preserve the stored value), then verified. Fails closed if the env
# can't be read. Secrets are never read into the payload.
# Reads ./manifest.json (copy ./manifest.json.example and fill it in).
#   ONLY=<name|bank regex> ./set-agent-envs.sh   # restrict (canary)
#   MANIFEST=<path> ./set-agent-envs.sh          # alternate manifest
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
MANIFEST="${MANIFEST:-manifest.json}"
[ -f "$MANIFEST" ] || { echo "$MANIFEST not found; copy manifest.json.example to manifest.json and fill it in" >&2; exit 1; }
MULTICA="${MULTICA_BIN:-multica}"
ONLY="${ONLY:-}"
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

ok=0; skipped=0
while read -r row; do
  d() { echo "$row" | base64 --decode | jq -r "$1"; }
  id="$(d .agent_id)"; name="$(d .name)"; bank="$(d .bank_id)"; scoping="$(d .scoping)"

  cur="$("$MULTICA" agent env get "$id" 2>/dev/null || true)"
  if ! printf '%s' "$cur" | jq -e --arg id "$id" '.agent_id == $id' >/dev/null 2>&1; then
    printf '%-24s %-28s SKIP (could not read current env; refusing to replace)\n' "$name" "$bank"
    skipped=$((skipped+1)); continue
  fi
  before_keys="$(printf '%s' "$cur" | jq -r '(.custom_env // {}) | keys | join(" ")')"
  payload="$(printf '%s' "$cur" | jq -c --arg b "$bank" --arg s "$scoping" \
      '(.custom_env // {}) | with_entries(.value="****") + {LWD_HINDSIGHT_BANK_ID:$b, LWD_HINDSIGHT_SCOPING:$s}')"

  printf '%-24s %-28s ' "$name" "$bank"
  if ! "$MULTICA" agent env set "$id" --custom-env-stdin --output json <<<"$payload" >/dev/null 2>&1; then
    echo "FAIL (set rejected)"; skipped=$((skipped+1)); continue
  fi
  after="$("$MULTICA" agent env get "$id" 2>/dev/null || true)"
  missing=0
  for k in $before_keys; do
    printf '%s' "$after" | jq -e --arg k "$k" '.custom_env | has($k)' >/dev/null 2>&1 || missing=$((missing+1))
  done
  nbefore="$(printf '%s' "$before_keys" | wc -w | tr -d ' ')"
  if [ "$missing" -ne 0 ]; then
    echo "WARN ($missing of $nbefore prior keys missing after set!)"; skipped=$((skipped+1))
  elif ! printf '%s' "$after" | jq -e --arg b "$bank" --arg s "$scoping" \
        '.custom_env.LWD_HINDSIGHT_BANK_ID == $b and .custom_env.LWD_HINDSIGHT_SCOPING == $s' >/dev/null 2>&1; then
    echo "WARN (bank/scoping not confirmed)"; skipped=$((skipped+1))
  else
    echo "ok ($nbefore prior keys kept + 2 hindsight vars)"; ok=$((ok+1))
  fi
done < <(jq -r --arg only "$ONLY" \
  '.agents[] | select(.selected)
   | select($only == "" or (.bank_id | test($only; "i")) or (.name | test($only; "i")))
   | @base64' "$MANIFEST")
echo "done: $ok ok, $skipped skipped/failed"
