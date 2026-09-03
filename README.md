# Qwen3.5-122B-A10B INT4 Hybrid on Dell Pro Max with GB10 —— 事故驱动的运维固化(历史篇)

> 这是我们最早期的本地主力配置(2026-06 时代):122B MoE、int4fp8 混合量化、vLLM。
> 它教会我们的运维纪律比它的性能更有价值——本书一半是配置,一半是**一次 OOM crash-loop ×14 事故后固化出来的红线**。
> (历史定位:后被更稳的方案取代,见 GPT-OSS-120B 篇"release 优先"结论;但这些运维纪律沿用至今。)

## 配置(事故后的 known-good 版)

| 项 | 值 |
|---|---|
| 权重 | Qwen3.5-122B-A10B,int4fp8 hybrid 量化(~71GB) |
| 引擎 | vLLM **0.19.1rc1.dev15+**(dev/RC 构建)+社区流传的 hybrid-quant patch(~95 行)——正是不稳的根源 |
| 启动命令(known-good 完整版) | `vllm serve <int4fp8权重目录> --port 8001 --max-model-len 32768 --gpu-memory-utilization 0.70 --max-num-seqs 8 --attention-backend FLASHINFER --speculative-config '{"method":"mtp","num_speculative_tokens":2}' --reasoning-parser qwen3 --default-chat-template-kwargs '{"enable_thinking":false}'` |
| 性能 | 单流 decode:baseline ~28 → MTP-2+FLASHINFER 后 **~52 tok/s(我们 soak 实测)**。社区早期报告为 28→40,差异来自 patch 与参数迭代——引用时注意阶段口径 |
| 托管 | systemd 单控制器(唯一起停入口,见红线 #1) |

## 部署脚本(历史配置,含红线机器化)

`scripts/deploy.sh --i-know-this-is-legacy`——显式确认门(本配置已被取代)→红线 #1/#2 自动检查→known-good 参数启动→推理断言。

## 事故实录:OOM crash-loop ×14

某次一个自动化流程绕过 systemd 手动 `docker run` 抢了同名容器 → 双实例争统一内存 → OOM → systemd 拉起 → 再 OOM——循环 14 次才被人发现。事故后固化:

### 红线(至今沿用)

1. **服务只有一个起停入口**:systemd(或 launchd)单控制器,known-good 配置文件备份一份带日期后缀;任何人/任何自动化**绝不手动 docker run 同名容器**。
2. **一台 GB10 绝不同时跑两个大权重实例**(两个 71GB 级=必 OOM)。
3. **调参改动先过 soak 再进 known-good**:我们的 util 从 0.80 降到 0.70 就是 soak 验证的(释放 12GB 消掉 swap 压力;0.9 必 OOM)。

## 最有价值的认知:KV 内存杠杆

统一内存机器上:`KV pool = util × 121GB − 权重 − 开销`,是个**固定池**。三个反直觉结论:

- **其他参数固定时,降内存最大的杠杆是降 util**——不是降 max_model_len(KV dtype/并发上限等当然也影响,但在本配置的调参空间里 util 是决定性的)。
- **加大 ctx 不省内存**:只是把固定池切成更少的并发槽。
- **vLLM 报告的"可支持并发数"是乐观值**:满 ctx 实际并发 = KV pool tokens ÷ max_model_len,自己算。

(例:util 0.70 时本配置 KV pool ≈10.65GB,按引擎报告折合 ~104K KV tokens;÷32K max_ctx ≈ **3.2 路满 ctx 并发**——兜底场景够用,别信面板上更乐观的数。)

## 其他一手结论

- **tool-call parser 用错会污染**:qwen3 系模型配 `--tool-call-parser hermes` 是错的(事故排查期的污染配置);该用 `qwen3` 系 parser,或干脆不依赖引擎原生 tool_calls(prompt 侧自解析工具调用更可控)。
- 关思考进 serving 默认(`--default-chat-template-kwargs '{"enable_thinking": false}'`)对兜底场景是对的:兜底要的是快和稳,不是深思。

## 为什么最终被取代

回看 GPT-OSS-120B 篇的结论:**需要 dev build+patch 才达标的路径就是 flapping 的根源**。本配置要 vLLM dev/RC+~95 行 hybrid-quant patch+MTP 三件套才到 52 tok/s,而 gpt-oss-120b 在 release llama.cpp 上直接 53。迁移是必然。
但如果你手上正是这个权重、且能接受 32K ctx:上面的 known-good 配置+红线是我们踩了 14 次 OOM 换来的,直接抄。

---
*RyanAI Lab · 历史配置实录(2026-06 时代),运维纪律沿用至今,更新于 2026-09。*
