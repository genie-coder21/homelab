# Local LLM on the gaming-pc

A local large language model served by [Ollama](https://ollama.com) on the Windows gaming-pc's GPU. The always-on server wakes the PC on demand and calls the model over the LAN. Its main consumer is a job-application automation tool that uses it to draft free-text answers (e.g. "Tell us about a project you're proud of"), which a human then reviews.

## Why local

- **No API costs and no API keys to manage** for a workload that makes thousands of calls.
- **Personal data stays home.** Each request carries a résumé-style context packet, and it never leaves the LAN.
- **The hardware was already there.** The gaming-pc has a consumer GPU with 12 GB of VRAM that sits idle most of the day. The server has no GPU and would be far too slow for 150 to 300-word answers.

## Architecture

```
  server (always on, no GPU)                       gaming-pc (Windows 11, GPU, sleeps)
  +------------------------------+                 +---------------------------------+
  | client tool                  |   1. drop a     |                                 |
  |  needs an answer ------------+-> request file  |                                 |
  |                              |                 |                                 |
  | hl-llm-wake.path  -> service |  2. Wake-on-LAN |                                 |
  |   wait for API, keep-awake --+---------------->|  Ollama server (at-logon task)  |
  |                              |                 |   OpenAI-compatible + native API|
  |  3. POST /api/chat ----------+---------------->|   model on GPU (+ RAM offload)  |
  |     JSON packet + schema     |  LAN only;      |   unloads 30 min after last use |
  |  <- {"answer", "confidence"} |  firewall allows|                                 |
  |  stored as UNAPPROVED -> human review          |  keep-awake holder releases     |
  +------------------------------+  server only    |  itself when idle               |
                                                   +---------------------------------+
```

## How a request looks

The client sends **one JSON context packet** per question. It contains:
- the task
- explicit rules: first person, plain language, *only claim what is in the applicant data*, respect the limits, return `null` with a reason instead of guessing
- the question and its limits (words, characters)
- a job description excerpt and the matched keywords
- the applicant's real background and a few approved answers as style examples

The reply is constrained by a **JSON schema** through Ollama's native `format` field: `{"answer": string|null, "confidence": number}`. The client validates the length itself and stores every answer **unapproved**. A human approves or edits it. If the model is unreachable, the question simply waits for the human.

`scripts/server/ask_local_llm.py` is a minimal, generic version of this client.

## Model choice

Three candidates that fit the GPU were benchmarked on a realistic, roughly 2,000-token packet with schema-constrained output (`scripts/windows/bench-llm.ps1`):

| Model | Write speed | Cold load | Verdict |
|---|---|---|---|
| Gemma 4 12B (QAT) | ~69 tok/s, fully on GPU | ~28 s | accurate, but leaned salesy ("extensive experience") |
| **Gemma 4 26B MoE, about 4B active (QAT)** | **~65 tok/s**, about 57 % on GPU, the rest in RAM | ~14 s | **chosen**: most natural voice, grounded |
| gpt-oss 20B | ~67 tok/s | n/a | **rejected**: invented experience that wasn't in the packet |

With the 26B MoE, a warm 150-word answer takes about 3 seconds: about 1 s to read the prompt at roughly 2,000 tok/s, then about 2 s to write. Because only about 4B parameters are active per token, offloading part of the model to system RAM barely hurts. Larger dense models (18 to 24 GB) were skipped as too slow once offloaded.

## Design decisions

- **The model is wrapped in rules and schema, never trusted.** Rules forbid inventing facts, the schema forces parseable output, the client validates limits, and a human approves. The benchmark showed why: one capable model fabricated experience on the first test.
- **Thinking is off.** For Gemma 4, the native API gets `think: false`; otherwise you pay for hidden reasoning tokens on a task that doesn't need them.
- **Wake on demand instead of always on.** The workload isn't latency-sensitive. Worst case is about 25 s for the first answer in a batch (wake plus model load), then about 3 s each.
- **Never force the PC back to sleep.** The server asks the PC to stay awake but never turns that off. A holder on the PC releases itself after a quiet period, so the server can't interrupt someone actively using the machine.
- **Keep-alive of 30 minutes.** While loaded, the model holds about 8.5 GB of VRAM. A 30-minute keep-alive is a compromise between batch speed and handing the GPU back for gaming. Unloading the model frees it immediately.
- **Network access is restricted by the firewall.** Ollama has no API keys, so access control is a Windows Firewall rule that allows only the server's address.
- **Only required questions go to the model.** Optional questions are left alone. Early runs showed the model will happily opt into things nobody asked it to.

## Traps and lessons learned

- **The Ollama desktop app's own server died silently** on this setup once `OLLAMA_HOST` was set to listen on all interfaces: no log, and the app looped on "server not ready". Running the server binary directly in serve mode worked. The fix is an at-logon scheduled task that runs the server, with the desktop app attaching to it as a chat window.
- **In Windows Firewall, Block beats Allow.** Windows auto-creates per-program rules for `ollama.exe` on first run. Flipping them to Block locked out the server too, despite an explicit Allow rule for it. The right move is to **delete** them and let the default inbound policy plus one Allow rule do the work.
- **Benchmark with fresh prompts.** Repeating an identical prompt hits Ollama's prompt cache and shows absurd "read" speeds (tens of thousands of tok/s).
- **Use structured output.** On the OpenAI-compatible endpoint that means `response_format` with a JSON schema; on the native endpoint it means `format`. Every benchmark run returned valid JSON within the word limit.
- **Context size matters more than it looks.** Measured on real requests, background notes were nearly half of each packet. Rewriting them so each fact is stated once cut about 8 %. Sending all of a form's open questions in **one** call instead of one call per question cut packet size by about two-thirds.
- **It's a decent coder for mid-size tasks, not for spec-heavy systems.** In an informal coding ladder the chosen model passed every test on scripts, a duration parser, an LRU+TTL cache and an expression evaluator. It failed at writing its own regex engine and a strict JSON parser.
