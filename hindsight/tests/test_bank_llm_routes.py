"""Run inside the Hindsight image (FOV-2945):
docker run --rm -v "$PWD/hindsight:/t:ro" -e PYTHONPATH=/t/ext --entrypoint python \
  ghcr.io/vectorize-io/hindsight:1.1.0-slim /t/tests/test_bank_llm_routes.py
"""

import asyncio
import os

os.environ.update(HINDSIGHT_API_LLM_BASE_URL="http://gw:4000/v1", HINDSIGHT_API_LLM_API_KEY="dummy")

from bank_llm_routes import BankLLMRoutes, parse_bank_models  # noqa: E402
from hindsight_api.extensions.llm_request import LLMRequestTarget  # noqa: E402


def target(bank):
    return LLMRequestTarget(schema="public", bank_id=bank, operation="retain", provider="openai", model="memory")


ext = BankLLMRoutes({"bank_models": "agent-ema=qwen3.8-flash-next", "timeout": "1800"})
o = asyncio.run(ext.resolve(target("agent-ema")))
assert o.llm.model == "qwen3.8-flash-next" and o.llm.base_url == "http://gw:4000/v1" and o.llm.api_key == "dummy"
assert o.llm.provider == "openai" and o.llm.timeout == 1800.0
assert "dummy" not in repr(o)
assert asyncio.run(ext.resolve(target("agent-other"))) is None
assert asyncio.run(ext.resolve(target(None))) is None
assert parse_bank_models(" a=x , b=y ,") == {"a": "x", "b": "y"}
for bad in ("a", "=x", "a="):
    try:
        parse_bank_models(bad)
        raise AssertionError(bad)
    except ValueError:
        pass
try:
    BankLLMRoutes({})
    raise AssertionError("empty config accepted")
except ValueError:
    pass
print("PASS test_bank_llm_routes")
