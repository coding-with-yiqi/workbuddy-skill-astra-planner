---
name: astra-planner
description: 动手前先用 Codex CLI 的 Astra 模型(gpt-6-astra)把任务编译成「傻瓜级方案 + 可运行的自检 harness + 可机器判定的成功标准」，拿到之后再照方案执行。用户要求任何实质性任务开工前先跑一遍；触发词包括「问 Astra」「先规划一下」「开工前」「astra」「make a plan」。
description_zh: "开工前用 Astra 编译方案与自检 harness，再照方案执行"
description_en: "Compile a foolproof plan + self-verification harness via Codex Astra before executing any real task"
version: 1.2.1
display_name: "astra-planner"
display_name_en: "astra-planner"
visibility: "public"
allowed-tools: Bash,Read,Write,Edit,Glob,Grep
---

# Astra Planner

开工前的一道固定工序：把任务交给 Astra 编译成方案，拿到方案再执行。
原则：**多造模具，少造玩具** —— 能复用的（脚本/模板/skill/校验器）一律参数化成模具，只有一次性交付物才允许是玩具。

## 心态（最重要）

**不要觉得自己比 Astra 聪明。** 它是规划者，我是执行者。
- 它给出的步骤、标准、断言，默认照做，不要凭直觉改。
- harness 报 FAIL，默认是我的实现没达到它的要求 —— 去改实现，而不是判定"这条断言过度设计"。
- 契约细节（阈值、变量名、参数形式）**随时可能被它调整**，这很正常。以最新方案为准，不要跟旧版本较劲。
- 真觉得它错了：停下来把分歧摆给用户，由用户裁决，不默默绕开。

## 何时用

- 任何需要 3 步以上的实质性任务，开工前先跑一次。
- 一句话问答、纯查资料、闲聊 → 不跑，直接做。

## 用法

```bash
# 1) 写任务描述（越具体越好：目标、约束、交付物、deadline）
cat > /tmp/task.md <<'EOF'
<任务原文>
EOF

# 2) 问 Astra 要方案（脚本是模具，任务描述是原料）
~/.workbuddy/skills/astra-planner/scripts/ask_gpt.sh /tmp/task.md .astra

# 3) 读方案，照着做
#    .astra/PLAN.md            方案本体
#    .astra/harness/*.sh       Astra 写好的自检脚本
#    .astra/context.md         喂给 Astra 的上下文快照

# 4) 每完成一批步骤，跑自检
~/.workbuddy/skills/astra-planner/scripts/ask_gpt.sh --check .astra
```

脚本会自动：抓上下文快照 → 调 `codex exec -m gpt-6-astra` → 校验章节契约 → 把 harness 代码块提取落盘并 chmod +x → 打印缺失项。
任一 FAIL 或章节缺失，退出码非 0。

```bash
# 只重跑提取，不再调 Astra（改了提取逻辑后回放旧方案）
ask_gpt.sh --extract .astra/PLAN.md .astra
# 只校验某份方案守不守契约（章节 / harness 命名安全 / ≤300 行）
ask_gpt.sh --validate-only .astra/PLAN.md
```

打包分发（内含 SKILL.md + scripts + references，解压到 `~/.workbuddy/skills/` 即用）：

```bash
~/.workbuddy/skills/astra-planner/scripts/package.sh [输出目录]
```

harness 运行时 cwd = 输出目录，并导出 `ASTRA_OUT`（输出目录）、`ASTRA_ROOT`（项目根目录）、`ASTRA_SUBJECT`（被验收目标，默认 = ASTRA_ROOT）。
每次编译还会写 `$OUT/run.status`（codex_exit / validation_exit / model / effort / proxy / plan_lines / **session_id**），供 harness 断言"这次到底发生了什么"。
`session_id` 可在 `~/.codex/sessions/YYYY/MM/DD/rollout-*<id>*.jsonl` 查到完整原始记录（默认落盘；设 `ASTRA_EPHEMERAL=1` 才不落盘）。

输出目录固定布局：`PLAN.md` `harness/` `context.md` `codex.log` `run.status` `prompt.md`。

## 执行纪律

1. 先读 `PLAN.md`，再动手。方案与我的判断冲突时，停下来跟用户说，不默默绕开。
2. 「工具预调清单」和「知识库检索清单」里的东西，在执行到那一步之前就调好，不要临时抱佛脚。
3. 每完成一批步骤跑一次 `--check`，FAIL 就修到 PASS，不带着红灯往下走。
4. 模具清单里的东西要真的落盘，不能只在方案里提一句。
5. 对用户说"我在问 Astra"，不要说"在跑脚本"或"在调 Codex"。

## 代理解析与排错

调用 Codex 之前，脚本会自己挑一个**真的能通**的代理，顺序如下：

| 优先级 | 候选来源 | 行为 |
| --- | --- | --- |
| 1 | `ASTRA_PROXY` | 设了就只用它；连不通**直接报错退出**，不偷偷回退（否则你以为在用自己设的那个） |
| 2 | macOS 系统代理 | `scutil --proxy` 读出 HTTPS / HTTP / SOCKS；Linux 没有 `scutil`，这一步自然跳过 |
| 3 | `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 及小写形式 | 兜底候选 |

每个候选都会用 `curl --proxy <候选> --connect-timeout 3 --max-time 8` 真的连一次 `https://chatgpt.com/`，取第一个通的；候选先去重再逐个试。选中之后写进六个代理变量再启动 Codex，**日志只打印来源（如 `macOS 系统代理`），不打印完整地址** —— 地址里可能带凭据。

全部候选都不通时：打印 `No usable proxy found` 并以非零码退出，**完全不调用 Codex**，不会白跑一次编译。

为什么不能直接读环境变量：宿主常常会注入自己的代理变量，而那个代理未必通（典型症状 502）。只信它，用户会卡在"配置齐全却跑不通"的状态里不知所以。

```bash
scutil --proxy            # macOS：看系统代理有没有开、端口多少
unset ASTRA_PROXY         # 回到自动探测
```

## 排错

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| `Proxy connection failed: 502` | 环境变量指向的代理其实不通 Codex | 脚本会自动跳过它继续试别的候选；全都不通则打印 `No usable proxy found` 并退出 |
| `failed to refresh available models: timeout` | 网络抖动 | 忽略，不影响主流程 |
| 方案缺章节 | 模型偷懒 | 脚本会报 MISSING，重跑一次；仍缺就在 PLAN.md 里手工补 |
| 自检时触发批量删除拦截 | harness 把临时目录建在工作区里，清理累计触发保护 | 契约已要求用系统临时目录；若旧方案仍这样，把输出目录拷到 `/tmp` 下再 `--check` |

## 可调参数（环境变量）

`ASTRA_MODEL`(默认 gpt-6-astra) · `ASTRA_EFFORT`(默认 xhigh) · `ASTRA_PROXY`(留空即自动探测) · `ASTRA_SANDBOX`(默认 read-only) · `ASTRA_EPHEMERAL`(默认不设，即会话落盘) · `CODEX_BIN`(默认按 PATH 查找 codex)
