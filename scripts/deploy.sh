#!/usr/bin/env bash
# deploy.sh — Qwen3.5-122B INT4 hybrid deploy (historical config; incident red lines built in)
# WARNING — historical status: this config has been superseded by a more stable setup (see the GPT-OSS-120B book). Use only if these are exactly the weights you have.
set -euo pipefail
PORT=8001; MODELS_DIR="$HOME/models"
while [ $# -gt 0 ]; do case "$1" in
  --port) PORT="$2"; shift 2;;
  --models-dir) MODELS_DIR="$2"; shift 2;;
  --i-know-this-is-legacy) LEGACY_OK=1; shift;;
  *) echo "unknown arg: $1"; exit 2;;
esac; done
say() { printf '\033[1m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[deploy] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

[ "${LEGACY_OK:-0}" = 1 ] || die "This config is legacy (needs vLLM dev/RC + patch — exactly the source of the instability). To deploy anyway, add --i-know-this-is-legacy; for new deployments read the GPT-OSS-120B book first."

# ── Red lines #1/#2, mechanized ──
[ "$(uname -m)" = "aarch64" ] || die "aarch64 required (Dell Pro Max with GB10)"
command -v docker >/dev/null || die "docker required"
BIG=$(docker ps --format '{{.Names}} {{.Size}}' 2>/dev/null | wc -l)
if docker ps --format '{{.Names}}' | grep -qx vllm-int4-122b; then
  say "Container vllm-int4-122b already running, skipping to liveness check (idempotent)"; SKIP_START=1
elif docker ps -a --format '{{.Names}}' | grep -qx vllm-int4-122b; then
  die "A stopped vllm-int4-122b exists. Reuse it with docker start vllm-int4-122b, or docker rm it and rerun."
else
  SKIP_START=0
  docker ps --format '{{.Image}}' | grep -qiE "vllm|llama|exl" && die "Red line #2: a large-weight inference instance is already running on this machine — never run two on one box (guaranteed OOM). Stop it first."
  lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "Port $PORT in use; red line #1: never grab a service name with a manual docker run"
fi

W="$MODELS_DIR/qwen35-122b-int4fp8"
[ -d "$W" ] || die "Missing weights dir $W (int4fp8 hybrid quantized, ~71GB)"

# ── known-good launch (soak-validated parameters; do NOT raise util above 0.70 — 0.9 is guaranteed OOM) ──
say "Launching known-good config @ :$PORT (vLLM needs a 0.19.1rc1.dev15+ class build + hybrid-quant patch, see README)"
if [ "${SKIP_START:-0}" = 0 ]; then
docker run -d --name vllm-int4-122b --gpus all --memory 100g -p "$PORT:$PORT" \
  -v "$W:/models/int4" "${VLLM_IMAGE:?set VLLM_IMAGE=your image built with the hybrid-quant patch}" \
  --model /models/int4 --served-model-name qwen-int4 --port "$PORT" \
  --max-model-len 32768 --max-num-seqs 8 --gpu-memory-utilization 0.70 \
  --attention-backend FLASHINFER \
  --speculative-config '{"method":"mtp","num_speculative_tokens":2}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking":false}'
fi

# ── Liveness check ──
ok=0
for i in $(seq 1 90); do curl -s -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ok=1; break; }; sleep 10; done
[ "$ok" = 1 ] || die "Not ready after 15 minutes, check docker logs vllm-int4-122b"
RESP=$(curl -s -m 60 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d '{
  "model":"qwen-int4","max_tokens":50,"messages":[{"role":"user","content":"Reply with one word: DEPLOY_OK"}]}')
echo "$RESP" | grep -q "DEPLOY_OK" || die "Inference assertion failed: $(echo "$RESP" | head -c 300)"
say "✅ Deploy complete (real full-32K concurrency ≈ 3.2 streams — do the math yourself, see the README's KV lever section); red line #3: soak any parameter change before it enters known-good"
