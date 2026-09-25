# Astra Planner

开工前的一道固定工序：把任务交给 Codex CLI 的 Astra 模型（`gpt-6-astra`）编译成**傻瓜级方案 + 可运行的自检 harness + 可机器判定的成功标准**，拿到方案之后再由执行者照着做。

它是「模具」，不是玩具：每次开工都走同一条流水线，产出可复用、可校验、可追溯。

```
任务 ──▶ Astra 编译 ──▶ 提取 harness ──▶ 执行 ──▶ 自检（红就修到绿）
```

## 它解决什么

大模型直接干活容易两件事做不好：**漏步骤**和**自己说自己干完了**。这个 skill 把这两件事交给机器判定：

- 方案必须包含固定八段（傻瓜级步骤 / 工具预调清单 / 知识库检索清单 / 技术细节 / 模具清单 / 自检 Harness / 成功标准 / 风险与回滚），缺一段就报错。
- 方案里写的自检脚本会被自动提取成真正的 `.sh` 文件并执行，输出 `[PASS]` / `[FAIL]`，有 FAIL 就非零退出。
- 每次调用的运行记录（模型、推理档位、退出码、方案行数、**会话 ID**）写进 `run.status`，事后可查。

## 依赖

| 依赖 | 是否必需 | 说明 |
| --- | --- | --- |
| Bash 4+ / macOS 或 Linux | 必需 | 脚本主体 |
| [Codex CLI](https://github.com/openai/codex) `codex` | 必需 | 需在 `PATH` 里，版本 ≥ 0.155；`~/.codex/config.toml` 里默认模型设为 `gpt-6-astra` |
| 能访问 `chatgpt.com` 的网络 | 必需 | 通常需要代理，见下 |
| `curl` | 必需 | 只用来探测候选代理哪个真能通 |
| Git | 可选 | 只在本仓库的安装/打包环节用到 |
| `scutil` | 可选 | macOS 自带，用来读系统代理；没有也能跑，退化为读环境变量 |
| `zip` | 可选 | 只用得到 `scripts/package.sh` |

## 安装

```bash
# <owner> = 你 fork / 下载所在的账号名（这里不写死任何具体账号）
git clone https://github.com/<owner>/workbuddy-skill-astra-planner.git \
  "${WORKBUDDY_SKILLS_DIR:-$HOME/.workbuddy/skills}/astra-planner"

# 或者不用 git：
mkdir -p "${WORKBUDDY_SKILLS_DIR:-$HOME/.workbuddy/skills}"
cp -R workbuddy-skill-astra-planner "${WORKBUDDY_SKILLS_DIR:-$HOME/.workbuddy/skills}/astra-planner"
```

## 配置代理（大多数时候不用配）

Codex 要连 `chatgpt.com`，这一步离不开代理，但**脚本会自己挑**，不用你先把端口抄进某个文件。它按这个顺序找，并且每个候选都真的连一次 `chatgpt.com` 验证能通，用第一个通的：

1. `ASTRA_PROXY` —— 你显式指定的，最优先
2. macOS 系统代理（`scutil --proxy` 读出来的那个）
3. 标准环境变量：`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`（含小写形式）

**为什么不直接用环境变量？** 因为宿主环境常常往 shell 里注入自己的代理变量，而那个代理未必真能通（典型症状：连上就 502）。只信环境变量，你会卡在一个"配置看起来齐全、却怎么都跑不通"的状态里，而且不知道为什么。

### 装完先跑一次看看

```bash
# 第 0 步：确认自己这台机器有没有系统代理、端口是多少（macOS）
scutil --proxy

# 然后直接跑，什么都不用配
SKILL="${WORKBUDDY_SKILLS_DIR:-$HOME/.workbuddy/skills}/astra-planner"
bash "$SKILL/scripts/ask_gpt.sh" /tmp/task.md .astra
# 正常时会看到一行：[代理] 来源: macOS 系统代理
```

### 什么时候才需要手动指定

Linux、CI，或者你的代理端口是手工起的、不在系统设置里：

```bash
export ASTRA_PROXY=http://<你的代理地址>:<端口>     # 建议写进 shell profile
```

两点要注意：

- 别把宿主环境（比如工作台）注入的那六个代理变量原样搬来用 —— 它们可能存在但并不通。脚本只把它们当**兜底候选**，不是首选。
- 一旦设了 `ASTRA_PROXY`，脚本就完全信你：连不通会直接报错退出，不会偷偷回退到别的代理。想回到自动探测，`unset ASTRA_PROXY`。

### 全都连不通时

脚本打印 `No usable proxy found` 并退出，按这个顺序排查：

1. 显式指定：`export ASTRA_PROXY=http://<你的代理地址>:<端口>`
2. 系统代理没开就打开；macOS 上用 `scutil --proxy` 看当前端口
3. 检查是不是被注入了一个"存在但其实不通"的环境变量

## 用法

```bash
SKILL="${WORKBUDDY_SKILLS_DIR:-$HOME/.workbuddy/skills}/astra-planner"

# 1) 写任务描述（越具体越好：目标、约束、交付物）
cat > /tmp/task.md <<'EOF'
给「个人工作台」项目出一个首版方案：网页形态，要能发布成在线链接，
数据来自企业微信与腾讯文档。只把一个场景做透。
EOF

# 2) 问 Astra 要方案（脚本是模具，任务描述是原料）
bash "$SKILL/scripts/ask_gpt.sh" /tmp/task.md .astra

# 3) 读方案，照着做
#    .astra/PLAN.md           方案本体
#    .astra/harness/*.sh      Astra 写好的自检脚本
#    .astra/context.md        喂给 Astra 的上下文快照
#    .astra/run.status        本次运行记录（含 session_id）

# 4) 每完成一批步骤跑一次自检，FAIL 修到 PASS 再往下走
bash "$SKILL/scripts/ask_gpt.sh" --check .astra
```

其他入口：

```bash
# 只校验某份方案守不守契约（章节齐全 / harness 命名安全 / 不过长）
bash "$SKILL/scripts/ask_gpt.sh" --validate-only .astra/PLAN.md
# 只重跑 harness 提取，不再调 Astra
bash "$SKILL/scripts/ask_gpt.sh" --extract .astra/PLAN.md .astra
# 打包分发
bash "$SKILL/scripts/package.sh" [输出目录]
```

### 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `ASTRA_MODEL` | `gpt-6-astra` | 模型 |
| `ASTRA_EFFORT` | `xhigh` | 推理档位 |
| `ASTRA_PROXY` | 留空 = 自动探测 | 显式代理地址；**设了就只用它**，连不通直接报错不回退 |
| `ASTRA_SANDBOX` | `read-only` | Codex 沙箱策略 |
| `ASTRA_EPHEMERAL` | 不设（会话落盘） | 设为 `1` 则不保留会话 |
| `CODEX_BIN` | 按 `PATH` 查找 `codex` | 也识别 `ASTRA_CODEX_BIN`，方便测试注入假 codex |

## 执行纪律

1. 先读 `PLAN.md` 再动手；方案与自己的判断冲突时，停下来跟用户确认，不默默绕开。
2. 「工具预调清单」「知识库检索清单」里的东西，在走到那一步之前就备好。
3. 每完成一批步骤跑一次 `--check`，不带着红灯往下走。
4. 模具清单里的东西要真的落盘。
5. 对用户说"我在问 Astra"。

**心态**：不要觉得自己比 Astra 聪明。它是规划者，执行者是干活的那个。harness 报 FAIL，默认改自己的实现，而不是判定"这条断言过度设计"。契约细节（阈值、变量名、参数形式）随时可能被它调整，以最新方案为准。

## 打包与发布

```bash
bash scripts/package.sh [输出目录]     # 生成 astra-planner-<version>.zip
```

## License

MIT
