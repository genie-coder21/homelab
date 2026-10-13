#!/usr/bin/env python3
"""Minimal client: ask the local Ollama model one question and get strict JSON back.

The pattern that worked: send a single JSON "context packet" (task, rules, question,
limits, background) as the user message, constrain the reply with a JSON schema via
Ollama's native `format`, and turn thinking off for models that support it.
If the model is unreachable, return None and let a human handle it.
"""
from __future__ import annotations
import json
import urllib.request

OLLAMA = "http://<GAMING_PC_IP>:11434"      # placeholder
MODEL = "gemma4:26b-a4b-it-qat"
SCHEMA = {"type": "object",
          "properties": {"answer": {"type": ["string", "null"]},
                         "confidence": {"type": "number"},
                         "reason": {"type": "string"}},
          "required": ["answer", "confidence"]}
SYSTEM = ('Reply ONLY with JSON: {"answer": "...", "confidence": 0.0-1.0}, or answer null '
          'plus a reason if it cannot be answered truthfully from the packet. Follow every rule in the packet.')


def ask(packet: dict, timeout: int = 120) -> dict | None:
    body = {"model": MODEL, "stream": False, "format": SCHEMA, "think": False,
            "options": {"temperature": 0.6, "num_ctx": 16384},
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": json.dumps(packet)}]}
    req = urllib.request.Request(f"{OLLAMA}/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            reply = json.loads(json.loads(r.read())["message"]["content"])
    except Exception:  # noqa: BLE001 - unreachable or malformed: leave it for a human
        return None
    limit = packet.get("limits", {}).get("max_words")
    if reply.get("answer") and limit and len(reply["answer"].split()) > limit:
        return None                                   # validate limits; never trust them blindly
    return reply


if __name__ == "__main__":
    print(ask({"task": "Answer one question.", "rules": ["Be brief."],
               "question": {"text": "What is a homelab?"}, "limits": {"max_words": 40}}))
