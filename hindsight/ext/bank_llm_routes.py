"""Hindsight LLM request extension: send chosen banks' LLM calls to another gateway alias.

FOV-2945. Hindsight 1.1 cannot set the LLM model per bank through the bank config API
(provider/model selection is server-wide). This hook is asked once per LLM call with
the bank and operation (retain, consolidation, reflect, mental-model refresh, ...) and
sends calls for the listed banks to a different alias on the same LiteLLM gateway, with
the server's own gateway key. Every other bank keeps the server's LLM.

Config (env, read by Hindsight's extension loader):
    HINDSIGHT_API_LLM_REQUEST_EXTENSION=bank_llm_routes:BankLLMRoutes
    HINDSIGHT_API_LLM_REQUEST_BANK_MODELS=agent-ema=qwen3.8-flash-next[,bank=alias...]
    HINDSIGHT_API_LLM_REQUEST_TIMEOUT=1800      # seconds, optional
Gateway URL and key come from HINDSIGHT_API_LLM_BASE_URL / HINDSIGHT_API_LLM_API_KEY.

A call Hindsight does not attribute to a bank (bank_id None) keeps the server's LLM.
"""

from __future__ import annotations

import logging
import os

from hindsight_api.config import LLMMemberConfig
from hindsight_api.extensions.llm_request import LLMRequestExtension, LLMRequestOverrides, LLMRequestTarget

logger = logging.getLogger(__name__)


def parse_bank_models(raw: str) -> dict[str, str]:
    routes: dict[str, str] = {}
    for item in filter(None, (p.strip() for p in raw.split(","))):
        bank, sep, model = (s.strip() for s in item.partition("="))
        if not sep or not bank or not model:
            raise ValueError(f"bad bank_models entry {item!r}, expected bank=model")
        routes[bank] = model
    return routes


class BankLLMRoutes(LLMRequestExtension):
    def __init__(self, config: dict[str, str]):
        super().__init__(config)
        self.routes = parse_bank_models(config.get("bank_models", ""))
        if not self.routes:
            raise ValueError("HINDSIGHT_API_LLM_REQUEST_BANK_MODELS is empty")
        base_url = os.environ.get("HINDSIGHT_API_LLM_BASE_URL")
        api_key = os.environ.get("HINDSIGHT_API_LLM_API_KEY")
        if not base_url or not api_key:
            raise ValueError("HINDSIGHT_API_LLM_BASE_URL and HINDSIGHT_API_LLM_API_KEY must be set")
        timeout = float(config["timeout"]) if config.get("timeout") else None
        # Built once: the engine caches the LLM it builds per distinct member config.
        self._members = {
            bank: LLMMemberConfig(provider="openai", model=model, base_url=base_url, api_key=api_key, timeout=timeout)
            for bank, model in self.routes.items()
        }
        logger.info("bank_llm_routes: routing %s", self.routes)

    async def resolve(self, target: LLMRequestTarget) -> LLMRequestOverrides | None:
        member = self._members.get(target.bank_id) if target.bank_id else None
        if member is None:
            return None
        logger.info(
            "bank_llm_routes: bank=%s op=%s %s -> %s", target.bank_id, target.operation, target.model, member.model
        )
        return LLMRequestOverrides(llm=member)
