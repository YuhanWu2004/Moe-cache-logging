# Task 3 — does the timing leak survive the trip to the user?

Inside the server, each token's decode time tracks its **expert-cache misses**
(a miss = fetch an expert to the GPU, ~0.4 ms each). But a remote attacker only
sees **SSE chunks**, which a server can bundle, flush late, or let the network
jitter. This measures whether the per-token timing is still readable at the
user's edge.

## How it works — three clocks on every token

All use `time.perf_counter()` (comparable on one host; across hosts compare only
gaps between tokens).

| clock | set where | meaning |
|---|---|---|
| `t_gen` | server, in `TimedStreamer.put` | token produced inside the model |
| `t_send` | server, at SSE flush | token pushed onto the network |
| `t_arrival` | client, at raw-socket `recv()` | token received by the user |

Misses per token come from the existing `ExpertCacheLogger` (`_layers.csv`).

**Timing alignment:** prefill emits token 1, decode step *j* emits token *j+1*,
so the gap arriving at token *k* reflects decode step *k-1*. `analyze.py` pairs
`gap[k]` with the misses at step *k-1*. (Checked on synthetic data: the
mechanism score is a perfect +1.000.)

## Files

| file | role |
|---|---|
| `sse_server.py` | runs the model, streams tokens, stamps `t_gen`/`t_send`, logs misses |
| `sse_client.py` | raw-socket reader (no library buffering); stamps `t_arrival` |
| `analyze.py` | joins the three clocks + misses, prints the scores |
| `run_task3.sh` | runs it all: server → client A (cold) → client B (warm) → analyze |

## Run it

Inside salloc, from the moe-setup checkout:

```bash
bash moe-cache-logging/task3/run_task3.sh
# or with your own prompts / length:
MAX_NEW=128 PROMPT_A="..." PROMPT_B="..." bash moe-cache-logging/task3/run_task3.sh
```

## Reading the output — three scores (Pearson / Spearman)

- **[1] gen vs misses** — is the signal even there? (sanity check; expect it present)
- **[2] arrival vs gen** — did the trip keep the timing shape?
- **[3] arrival vs misses** — can a remote attacker read the misses? (the real goal)

Also printed: how many tokens arrived **bundled** into one chunk (the blurring).

- Strong **[3]** → the leak is remotely observable → feeds Task 4.
- Weak **[3]** with strong **[1]** → the transport destroyed it → a real limit on the attack.

Both outcomes are a result.

## Caveats & next steps

1. **`cache=cold`** only resets the usage counters, not GPU residency. A truly
   empty GPU needs a fresh server process. The warm-B-after-A case is the
   realistic cross-user scenario anyway.
2. **Same-host timing.** Client and server share the machine here (loopback), so
   `[2]` is a best case. Over a real network, trust the rank-based Spearman.
3. **Clean baseline.** One request at a time, so we measure transport alone. The
   realistic follow-up is the batching server (`api_server_v2.py`), which adds
   its own bundling on top.
