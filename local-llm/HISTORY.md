# History

## 2026-10-06: from "no API" to a working local model in a day

### The ask

A job-application automation tool running on the server could already fill most of a form deterministically (profile fields, yes/no screening questions, standard choices). What it couldn't do was **free-text essay questions**. The owner didn't want to deal with a hosted LLM API, its keys and its bills, so the question became whether a local model could do it.

The tool already had a single hook for this: one function called only for questions nothing else could answer, whose output was always stored **unapproved** so the application went to human review instead of being submitted. A local backend only had to slot in behind that function.

### The design conversation

The server's maintainer wrote up the request for the gaming-pc side:
- **Host it on the gaming-pc.** It has the GPU, and the server's low-power CPU would be far too slow.
- **Expose an OpenAI-compatible endpoint on the LAN**, reachable from the server only.
- **Agree on a single request format**, a JSON "context packet" carrying the task, explicit rules (first person, plain, never invent employers, numbers, certifications or dates, respect limits, return null instead of guessing), the question, its limits, the job, the applicant's real background and a few approved answers as style examples.
- **Agree on the reply:** `{"answer", "confidence"}` or `null` plus a reason.

The open question was sleep. Should the server wake the PC, or treat "unreachable" as "leave it for the human"?

### Installing Ollama, and two traps

Ollama was installed per-user on Windows. It detected the GPU and its CUDA runtime and ignored the integrated graphics. Settings went into user environment variables: listen on all interfaces, a 30-minute keep-alive, flash attention on, a 16K context window.

**Trap one.** With those variables set, the desktop app's built-in server spawn died instantly with no log, and the app sat in a "server not ready" loop. Running the server binary directly in serve mode worked fine. The fix was a hidden at-logon scheduled task that runs the server with restart-on-failure; the desktop app then attaches to the already-running server as its chat window.

**Trap two.** Windows had auto-created per-program firewall rules for `ollama.exe`. The first instinct was to flip them to Block and add one Allow rule for the server's address. That locked the server out too, because **in Windows Firewall a Block rule always wins over an Allow**. The right fix was to delete the per-program rules entirely and let the default inbound policy plus the single Allow rule do the job. Reachability was then confirmed from the server against the version endpoint.

### Choosing a model by experiment

The model library was checked live for what fits a 12 GB GPU. Larger dense models (18 to 24 GB) were ruled out because they would run mostly from system RAM and be too slow. Three candidates were benchmarked with a script that builds a realistic packet in the agreed format, forces a cold load on the first run and measures load time, prompt-read speed, write speed, wall time and word count:

- **Gemma 4 12B:** fast and fully on the GPU, accurate, but its answers leaned salesy.
- **gpt-oss 20B:** similar speed, but it **invented experience** that was not in the packet. That is precisely what the rules forbid, so it was rejected outright.
- **Gemma 4 26B MoE (about 4B active parameters):** about 65 tok/s write and about 2,000 tok/s read, roughly 3 s for a warm 150-word answer and about 14 s cold load. It held about 8.5 GB on the GPU with the rest in RAM, and because few parameters are active per token, the offload barely hurt. Its answers were the most natural and stayed grounded. **Chosen.**

One measurement trap: an identical prompt sent twice showed impossible read speeds because of Ollama's prompt cache, so all comparisons used fresh prompts.

The recipe that made output reliable was the native chat endpoint with `format` set to a JSON schema and `think: false` for Gemma 4 (otherwise it spends tokens on hidden reasoning). Every benchmark run returned valid JSON within the word limit.

An informal coding ladder was also run, one attempt per level against hidden tests. The model handled scripts, a duration parser, an LRU+TTL cache and an expression evaluator with operator precedence. It failed at writing a regex engine and a strict JSON parser. Its code also grew bloated as difficulty rose.

### Wiring it in

The server-side tool was switched to the Ollama backend with exactly that recipe. Reachability was checked, and the client was unit-tested against a mock server before any real call. The first real answers came back in a few seconds each with valid JSON every time. The two real essays were grounded in the applicant's actual background with nothing invented.

One problem surfaced, and it was the client's fault, not the model's: it had also sent *optional* follow-up questions, and the model obligingly answered them and opted into things nobody wanted. From then on only required questions go to the model.

### Wake on demand

The recommendation from the gaming-pc side was to wake the PC, since the work isn't latency-sensitive. After the owner approved, it was built on the server as a systemd **path unit**. A client drops a request file, and a oneshot service:
1. deletes the request first, so a failure can't loop
2. checks whether the PC is up, and if not sends Wake-on-LAN and waits up to 150 s
3. asks the PC to hold itself awake through the same keep-awake mechanism other workloads already used

It deliberately **never** turns the keep-awake off. The holder on the PC releases itself after a quiet period, and an explicit "off" from the server could interrupt someone else's session. The worst-case latency for the first answer of a batch is about 25 s (wake plus model load).

## 2026-10-08: embeddings for reuse

A small embedding model was pulled into the same Ollama instance. Previously answered questions are embedded and cached, so a new question that is very close to an approved one can reuse that answer (with the model confirming the match) instead of generating a new one.

## 2026-10-12: measuring the packet

A real packet was measured at about 35,000 characters, and the background notes alone were almost half of it. They were rewritten so every fact is stated once, with nothing dropped, which cut the packet by about 8.5 %. Usage up to this point: about 2,200 calls, about 6.2 M input tokens and 58 K output tokens, all served by the local model at zero marginal cost.

## 2026-10-13: fewer, cheaper calls

Two efficiency changes on the client side:
- The fixed system prompt was cut almost in half by stating each rule once.
- All of a form's open questions are now sent in **one** call with an array schema, instead of one call per question. On a synthetic three-essay form that cut packet size by about two-thirds. Any entry that comes back empty or suspicious falls back to the single-question path.

The model also started doing small classification work. When the client's rule-based matching is unsure what a form field is asking, the model picks from a fixed menu of intents, and each verdict is cached so the same label is never asked twice.

## 2026-10-13: the public version

For this repository:
- The installer and benchmark were stripped of site details, and the benchmark packet was replaced with an entirely fictional applicant.
- The wake helper was rewritten to stand alone: Wake-on-LAN plus polling the model API, with an optional keep-awake hook.
- A minimal generic client was added.
