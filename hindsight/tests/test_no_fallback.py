"""FOV-2945: when the routed LLM fails, Hindsight must NOT retry on the server's LLM.
Stub 9001 = server LLM ("hosted memory"), counts hits. Stub 9002 = routed target, always 500.
Run in the Hindsight image (PYTHONPATH=ext dir), e.g. from the repo root:
docker run --rm --network none -v "$PWD/hindsight:/t:ro" -e PYTHONPATH=/t/ext --entrypoint python \
  ghcr.io/vectorize-io/hindsight:1.1.0-slim -B /t/tests/test_no_fallback.py"""

import asyncio
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

hits = {9001: 0, 9002: 0}


def stub(port, status):
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            hits[port] += 1
            self.rfile.read(int(self.headers.get("content-length", 0)))
            body = json.dumps({"id": "x", "object": "chat.completion", "created": 0, "model": "m",
                               "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"},
                                            "finish_reason": "stop"}],
                               "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(body if status == 200 else b'{"error":{"message":"down"}}')

        def log_message(self, *a):
            pass

    s = HTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()


stub(9001, 200)
stub(9002, 500)
os.environ.update(HINDSIGHT_API_LLM_BASE_URL="http://127.0.0.1:9002/v1", HINDSIGHT_API_LLM_API_KEY="dummy")

from bank_llm_routes import BankLLMRoutes  # noqa: E402
from hindsight_api.engine import memory_engine  # noqa: E402
from hindsight_api.engine.llm_wrapper import LLMProvider  # noqa: E402
from hindsight_api.extensions.llm_request import install_llm_request_extension  # noqa: E402

install_llm_request_extension(BankLLMRoutes({"bank_models": "agent-ema=qwen3.8-flash-next", "timeout": "10"}))
server = LLMProvider(provider="openai", api_key="dummy", base_url="http://127.0.0.1:9001/v1", model="memory",
                     max_retries=2, initial_backoff=0.1, max_backoff=0.2, timeout=10)
msgs = [{"role": "user", "content": "hi"}]


async def run(bank):
    tok = memory_engine._current_bank_id.set(bank)
    try:
        await server.call(messages=msgs, max_retries=2, initial_backoff=0.1, max_backoff=0.2)
        return "ok"
    except Exception as e:
        return f"raised {type(e).__name__}"
    finally:
        memory_engine._current_bank_id.reset(tok)


r = asyncio.run(run("agent-ema"))
print("agent-ema:", r, hits)
assert r.startswith("raised") and hits[9001] == 0 and hits[9002] >= 1, "FALLBACK TO SERVER LLM"
r = asyncio.run(run("agent-other"))
print("agent-other:", r, hits)
assert r == "ok" and hits[9001] >= 1
print("PASS test_no_fallback")
