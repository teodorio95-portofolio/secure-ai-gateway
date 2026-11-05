"""Offline proof that spent per-person DeepSeek budgets fall back: pro -> flash -> local.

Builds a LiteLLM Router from the homelab's own model_list and fallbacks
(values/litellm-homelab.yaml) with mocked answers, so no key or network is
needed. Both of teodor's aliases get a near-zero budget, so each serves one
call: pro, then flash, then `local` for everything; teodora is untouched.

    make check-budget-fallback    # runs it against the pinned LiteLLM
"""

import asyncio
import copy
import os
import sys
from pathlib import Path

import yaml

os.environ.setdefault("LITELLM_LOCAL_MODEL_COST_MAP", "True")
from litellm import Router  # noqa: E402

VALUES = Path(__file__).resolve().parents[1] / "values" / "litellm-homelab.yaml"


def router_from_values() -> Router:
    cfg = yaml.safe_load(VALUES.read_text())["proxy_config"]
    model_list = copy.deepcopy(cfg["model_list"])
    for entry in model_list:
        params = entry["litellm_params"]
        params["mock_response"] = f"served by {entry['model_name']}"
        params["api_key"] = "sk-offline"
        if entry["model_name"] in ("chat-teodor", "chat-teodor-pro"):
            params["max_budget"] = 0.000001  # spent after one call
    return Router(model_list=model_list, fallbacks=cfg["router_settings"]["fallbacks"], num_retries=0)


async def main() -> int:
    router = router_from_values()  # needs a running loop: the budget limiter starts a task

    async def ask(alias: str) -> str:
        reply = await router.acompletion(model=alias, messages=[{"role": "user", "content": "salut"}])
        await asyncio.sleep(0.3)  # spend is recorded by an async success callback
        return reply.choices[0].message.content

    calls = ["chat-teodor-pro"] * 3 + ["chat-teodor", "chat-teodora", "chat-teodora-pro"]
    want = [
        "served by chat-teodor-pro",  # pro has budget
        "served by chat-teodor",  # pro spent -> flash
        "served by local",  # flash spent too -> local
        "served by local",
        "served by chat-teodora",  # the other person keeps DeepSeek
        "served by chat-teodora-pro",
    ]
    got = [await ask(alias) for alias in calls]
    for call, (g, w) in enumerate(zip(got, want, strict=True), 1):
        print(f"{'PASS' if g == w else 'FAIL'}  call {call}: expected '{w}', got '{g}'")
    return 0 if got == want else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
