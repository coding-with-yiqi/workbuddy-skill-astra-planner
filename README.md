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
| `curl` | 排错用 | 只在验证代理能不能通时需要 |
| Git | 可选 | 只在本仓库的安装/打包环节用到 |
| `scutil` | 可选 | macOS 自带，用来查系统代理端口；没有也能跑 |
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

## 配置代理（开工前必做）

Codex 要连 `chatgpt.com`，离不开代理。**脚本不会替你探测哪个代理能通** —— 这件事因机器而异，写死在脚本里就是替你猜。这一步由你（或你的 AI 助手）来做，脚本只负责用你给的那个。

```bash
# 1. 看这台机器的代理（macOS）
scutil --proxy

# 2. 设好再跑。多数翻墙客户端是混合端口，必须用 socks5h://
export ASTRA_PROXY=socks5h://127.0.0.1:<端口>

# 3. 验一次：看到 403 就说明通了（chatgpt.com 会拒绝 curl，但代理是好的）
curl --proxy "$ASTRA_PROXY" --max-time 8 -sS -o /dev/null -w '%{http_code}\n' https://chatgpt.com/
```

- 也可以用标准变量 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY`；脚本按顺序取第一个非空值，`ASTRA_PROXY` 优先。
- **别直接用宿主注入的代理变量** —— 它常常"存在但不通"（典型症状 502）。
- 没有任何代理变量时，脚本打印 `No usable proxy found` 并退出，不会调用 Codex。
- 完整排查清单见 `SKILL.md` 的「开工前：先把代理接通」。


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
| `ASTRA_PROXY` | 留空则用环境变量 | 显式代理地址；优先于所有标准变量 |
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
