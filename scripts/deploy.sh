#!/usr/bin/env bash
# deploy.sh — Qwen3.5-122B INT4 hybrid 部署(历史配置;事故红线内化)
# ⚠️ 历史定位:本配置已被更稳方案取代(见 GPT-OSS-120B 篇)。仅当你手上正是这个权重时使用。
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

[ "${LEGACY_OK:-0}" = 1 ] || die "本配置是历史方案(需 vLLM dev/RC+patch,正是不稳根源)。确认仍要部署请加 --i-know-this-is-legacy;新部署建议先读 GPT-OSS-120B 篇。"

# ── 红线 #1/#2 的机器化 ──
[ "$(uname -m)" = "aarch64" ] || die "需 aarch64(Dell Pro Max with GB10)"
command -v docker >/dev/null || die "需要 docker"
BIG=$(docker ps --format '{{.Names}} {{.Size}}' 2>/dev/null | wc -l)
if docker ps --format '{{.Names}}' | grep -qx vllm-int4-122b; then
  say "容器 vllm-int4-122b 已在跑,跳到验活(幂等)"; SKIP_START=1
elif docker ps -a --format '{{.Names}}' | grep -qx vllm-int4-122b; then
  die "存在已停止的 vllm-int4-122b。docker start vllm-int4-122b 复用,或 docker rm 后重跑。"
else
  SKIP_START=0
  docker ps --format '{{.Image}}' | grep -qiE "vllm|llama|exl" && die "红线 #2:本机已有大权重推理实例在跑,一台机绝不同跑两个(必 OOM)。先停再来。"
  lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "端口 $PORT 被占;红线 #1:绝不手动 docker run 抢服务名"
fi

W="$MODELS_DIR/qwen35-122b-int4fp8"
[ -d "$W" ] || die "缺权重目录 $W(int4fp8 hybrid 量化版,~71GB)"

# ── known-good 启动(soak 验证过的参数;util 0.70 勿上调——0.9 必 OOM) ──
say "启动 known-good 配置 @ :$PORT(vLLM 需 0.19.1rc1.dev15+ 级构建+hybrid-quant patch,见 README)"
if [ "${SKIP_START:-0}" = 0 ]; then
docker run -d --name vllm-int4-122b --gpus all --memory 100g -p "$PORT:$PORT" \
  -v "$W:/models/int4" "${VLLM_IMAGE:?请设 VLLM_IMAGE=你构建的含 hybrid-quant patch 的镜像}" \
  --model /models/int4 --served-model-name qwen-int4 --port "$PORT" \
  --max-model-len 32768 --max-num-seqs 8 --gpu-memory-utilization 0.70 \
  --attention-backend FLASHINFER \
  --speculative-config '{"method":"mtp","num_speculative_tokens":2}' \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking":false}'
fi

# ── 验活 ──
ok=0
for i in $(seq 1 90); do curl -s -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ok=1; break; }; sleep 10; done
[ "$ok" = 1 ] || die "15 分钟未就绪,docker logs vllm-int4-122b"
RESP=$(curl -s -m 60 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d '{
  "model":"qwen-int4","max_tokens":50,"messages":[{"role":"user","content":"回复一个词:DEPLOY_OK"}]}')
echo "$RESP" | grep -q "DEPLOY_OK" || die "推理断言失败: $(echo "$RESP" | head -c 300)"
say "✅ 部署完成(满 32K 实际并发≈3.2 路,README KV 杠杆一节自己算);红线 #3:任何调参先 soak 再进 known-good"
