# Qwen3.5-122B-A10B INT4 Hybrid on Dell Pro Max with GB10 —— Incident-Driven Ops Hardening (Historical)

> This was our earliest resident production config (the 2026-06 era): 122B MoE, int4fp8 hybrid quantization, vLLM.
> The ops discipline it taught us is worth more than its performance — this book is half configuration, half **red lines hardened after an OOM crash-loop x14 incident**.
> (Historical status: later replaced by a more stable setup — see the GPT-OSS-120B book's "release builds first" conclusion — but these ops rules are still in force today.)

## Configuration (post-incident known-good version)

| Item | Value |
|---|---|
| Weights | Qwen3.5-122B-A10B, int4fp8 hybrid quantization (~71GB) |
| Engine | vLLM **0.19.1rc1.dev15+** (dev/RC build) + a community-circulated hybrid-quant patch (~95 lines) — exactly the source of the instability |
| Launch command (known-good, full) | `vllm serve <int4fp8-weights-dir> --port 8001 --max-model-len 32768 --gpu-memory-utilization 0.70 --max-num-seqs 8 --attention-backend FLASHINFER --speculative-config '{"method":"mtp","num_speculative_tokens":2}' --reasoning-parser qwen3 --default-chat-template-kwargs '{"enable_thinking":false}'` |
| Performance | Single-stream decode: baseline ~28 → **~52 tok/s with MTP-2 + FLASHINFER (measured in our soak runs)**. Early community reports said 28→40; the gap comes from patch and parameter iteration — mind which stage a number was measured at when citing |
| Hosting | Single systemd controller (the only start/stop entry point, see red line #1) |

## Deploy script (historical config, red lines mechanized)

`scripts/deploy.sh --i-know-this-is-legacy` — an explicit confirmation gate (this config has been superseded) → automatic checks for red lines #1/#2 → launch with known-good parameters → inference assertion.

## Incident report: OOM crash-loop x14

One day an automation pipeline bypassed systemd and manually ran `docker run` grabbing the same container name → two instances fighting over unified memory → OOM → systemd restarts it → OOM again — the loop ran 14 times before a human noticed. Hardened afterwards:

### Red lines (still in force)

1. **A service has exactly one start/stop entry point**: a single systemd (or launchd) controller, with the known-good config file backed up with a date suffix; no person and no automation **ever manually runs `docker run` with the same container name**.
2. **Never run two large-weight instances on one GB10 at the same time** (two 71GB-class instances = guaranteed OOM).
3. **Any parameter change passes a soak run before entering known-good**: our util drop from 0.80 to 0.70 was soak-validated (freed 12GB and eliminated swap pressure; 0.9 is guaranteed OOM).

## The most valuable insight: the KV memory lever

On a unified-memory machine: `KV pool = util x 121GB − weights − overhead` — a **fixed pool**. Three counterintuitive conclusions:

- **With other parameters fixed, the biggest lever for reducing memory is lowering util** — not lowering max_model_len (KV dtype, concurrency caps etc. matter too, but in this config's tuning space util is decisive).
- **Raising ctx does not save memory**: it just slices the fixed pool into fewer concurrency slots.
- **The "supported concurrency" vLLM reports is optimistic**: real full-ctx concurrency = KV pool tokens / max_model_len — compute it yourself.

(Example: at util 0.70 this config's KV pool is ~10.65GB, which the engine reports as ~104K KV tokens; / 32K max_ctx ≈ **3.2 full-ctx concurrent streams** — enough for a fallback role; don't trust the more optimistic dashboard number.)

## Other first-hand conclusions

- **The wrong tool-call parser contaminates output**: pairing a qwen3-family model with `--tool-call-parser hermes` is wrong (a contaminated config from our incident triage); use a `qwen3`-family parser, or skip the engine's native tool_calls entirely (parsing tool calls yourself on the prompt side is more controllable).
- Baking thinking-off into the serving default (`--default-chat-template-kwargs '{"enable_thinking": false}'`) is right for a fallback role: a fallback needs fast and stable, not deep reasoning.

## Why it was ultimately replaced

Looking back at the GPT-OSS-120B book's conclusion: **any path that needs a dev build + patch to hit its target is the root cause of flapping**. This config needed the trio of vLLM dev/RC + a ~95-line hybrid-quant patch + MTP to reach 52 tok/s, while gpt-oss-120b hits 53 straight on release llama.cpp. The migration was inevitable.
But if these are exactly the weights you have, and 32K ctx is acceptable: the known-good config plus the red lines above cost us 14 OOMs to learn — copy them as-is.

---
*RyanAI Lab · All numbers measured on our resident environment. Updated 2026-09. Issues welcome.*
