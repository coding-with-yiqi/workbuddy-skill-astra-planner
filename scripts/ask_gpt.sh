#!/usr/bin/env bash
# ask_gpt.sh — 模具：用 Codex CLI (gpt-6-astra) 把任意任务编译成
#                「傻瓜级方案 + 可运行的自检 harness + 可机器判定的成功标准」
#
# 用法:
#   ask_astra.sh <task.md> [out_dir]      编译方案（默认 out_dir=./.astra）
#   ask_astra.sh --check <out_dir>        跑 harness/*.sh，汇总 PASS/FAIL
#
# 退出码: 0 = 全绿；1 = 有 FAIL 或章节缺失
set -uo pipefail

# 先按 PATH 找 codex（这样 harness 能用假 codex 做桩测试），找不到才回落到绝对路径
if [ -z "${CODEX_BIN:-}${ASTRA_CODEX_BIN:-}" ]; then
  CODEX_BIN="$(command -v codex 2>/dev/null || echo "$HOME/.local/bin/codex")"
else
  CODEX_BIN="${CODEX_BIN:-$ASTRA_CODEX_BIN}"
fi
MODEL="${ASTRA_MODEL:-gpt-6-astra}"
EFFORT="${ASTRA_EFFORT:-xhigh}"
SANDBOX="${ASTRA_SANDBOX:-read-only}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(pwd)"

# ---------- 代理 ----------
# 脚本不替你探测"哪个代理能通"。这件事因机器而异：混合端口只认 SOCKS、
# 宿主注入的变量可能返回 502、公司代理要认证……写死在脚本里等于替用户猜，
# 猜错了反而更难查。所以找代理是执行者的活（见 SKILL.md「开工前：先把代理接通」），
# 脚本只负责：按顺序取第一个非空变量 → 统一导出 → 没有就带着排查指引退出。
PROBE_URL="https://chatgpt.com/"
PROXY=""
PROXY_KIND=""

resolve_proxy() {
  PROXY="${ASTRA_PROXY:-${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}}}"
  if [ -z "$PROXY" ]; then
    echo "No usable proxy found" >&2
    echo "  Codex CLI 要能连到 ${PROBE_URL}，但这里没拿到任何代理变量。" >&2
    echo "  你这台机器怎么连出去（代理、端口、认证）由你自己决定，脚本不替你猜；" >&2
    echo "  连好之后 export ASTRA_PROXY=<你自己的代理> 再跑就行。" >&2
    exit 1
  fi
  PROXY_KIND="ASTRA_PROXY"
  [ -z "${ASTRA_PROXY:-}" ] && PROXY_KIND="环境变量"
  # 六个代理变量统一指向同一个值，绕过类变量一律清空
  export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" ALL_PROXY="$PROXY"
  export http_proxy="$PROXY" https_proxy="$PROXY" all_proxy="$PROXY"
  unset NO_PROXY no_proxy
  # 只报来源不报地址：地址里可能带凭据
  echo "[代理] 已就位，来源: ${PROXY_KIND}"
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- 上下文快照 ----------
build_context() {
  local out="$1"
  {
    echo "# 上下文快照"
    echo "- 时间: $(date '+%F %T %Z')"
    echo "- 工作目录: $ROOT"
    echo "- 执行者: WorkBuddy（有 Bash/Read/Write/Edit/Glob/Grep，可联网）"
    echo
    echo "## 项目树 (depth<=3)"
    find "$ROOT" -maxdepth 3 -not -path '*/.git/*' -not -path '*/node_modules/*' \
         -not -path '*/.workbuddy/*' 2>/dev/null | head -120
    echo
    echo "## 长期记忆"
    for f in "$HOME/.workbuddy/MEMORY.md" "$ROOT/.workbuddy/memory/MEMORY.md"; do
      [ -f "$f" ] && { echo "### $f"; head -60 "$f"; echo; }
    done
    echo "## 已装 Skills (~/.workbuddy/skills)"
    ls "$HOME/.workbuddy/skills" 2>/dev/null | grep -v '^_' | tr '\n' ' '; echo; echo
    echo "## 已启用的连接器 / 插件"
    python3 - <<'PY' 2>/dev/null || true
import json,os
p=os.path.expanduser("~/.workbuddy/settings.json")
try:
    d=json.load(open(p))
    print(", ".join(k for k,v in d.get("enabledPlugins",{}).items() if v))
except Exception as e:
    print("(读取失败)",e)
PY
    echo
    echo "## 本机可用 CLI"
    for c in codex node python3 ffmpeg git curl jq pandoc; do
      printf '%s: %s\n' "$c" "$(command -v "$c" || echo '-')"
    done
  } > "$out"
}

# ---------- 章节契约校验 (+ --validate-only) / harness 提取 ----------
post_process() {
  local plan="$1" out="${2:-$(dirname "$1")}"
  PLAN="$plan" OUT="$out" ASTRA_MODE="${ASTRA_MODE:-extract}" python3 - <<'PY'
import os, re, sys

plan_path = os.environ["PLAN"]; out = os.environ["OUT"]
mode = os.environ.get("ASTRA_MODE", "extract")
if not os.path.exists(plan_path):
    print("MISSING: PLAN.md 未生成"); sys.exit(1)
text = open(plan_path, encoding="utf-8").read()
lines_all = text.splitlines()

required = ["傻瓜级步骤", "工具预调清单", "知识库检索清单", "技术细节",
            "模具清单", "自检 Harness", "成功标准"]
missing = [s for s in required if not re.search(r"^#{1,3}\s*.*" + re.escape(s), text, re.M)]
for s in missing:
    print("MISSING-SECTION:", s)

# harness 名字安全：禁止路径穿越。只认「整行就是标记注释」的行，避开正文里的正则样例
bad = [n for n in re.findall(r"^#\s*harness/(\S+\.sh)\s*$", text, re.M)
       if not re.fullmatch(r"[A-Za-z0-9_.-]+\.sh", n)]
for n in bad:
    print("UNSAFE-HARNESS-NAME:", n)

MAX_LINES = 300
too_long = len(lines_all) > MAX_LINES
if too_long:
    print(f"TOO-LONG: {len(lines_all)} 行 > {MAX_LINES}")

# 重名会静默覆盖，必须拦住
names = re.findall(r"^#\s*harness/(\S+\.sh)\s*$", text, re.M)
dupes = sorted({n for n in names if names.count(n) > 1})
for n in dupes:
    print("DUPLICATE-HARNESS-NAME:", n)

if mode == "validate":
    sys.exit(1 if (missing or bad or too_long or dupes) else 0)

# 提取所有「自检 Harness」章节下的 bash 代码块
# 分段必须「围栏感知」：代码块里的 shell 注释 `# ...` 长得像 markdown 标题，不能用正则粗暴截断
harness_dir = os.path.join(out, "harness")
os.makedirs(harness_dir, exist_ok=True)
n = 0
for i, ln in enumerate(lines_all):
    mh = re.match(r"^(#{1,3})\s*.*自检\s*Harness", ln)
    if not mh:
        continue
    lvl = len(mh.group(1))
    in_fence = False
    end = len(lines_all)
    for j in range(i + 1, len(lines_all)):
        s = lines_all[j].lstrip()
        if s.startswith("```") or s.startswith("````"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m2 = re.match(r"^(#{1,3})\s+\S", lines_all[j])
        if m2 and len(m2.group(1)) <= lvl:
            end = j
            break
    section = lines_all[i + 1:end]
    # 围栏感知取块：块内可能含更短的 ``` （例如 awk 里拼 markdown），正则会提前截断
    blocks, k = [], 0
    while k < len(section):
        mf = re.match(r"^(`{3,})(?:bash|sh)\s*$", section[k])
        if mf:
            fence = len(mf.group(1)); k += 1; buf = []
            while k < len(section) and not re.match(r"^`{%d,}\s*$" % fence, section[k]):
                buf.append(section[k]); k += 1
            blocks.append("\n".join(buf))
        k += 1
    for block in blocks:
        lines = block.strip().splitlines()
        first = lines[0] if lines else ""
        mt = re.match(r"#\s*harness/([A-Za-z0-9_.-]+\.sh)", first)
        name = mt.group(1) if mt else f"check_{n+1}.sh"
        body = block if block.lstrip().startswith("#!") else "#!/usr/bin/env bash\n" + block
        if "#!/usr/bin/env bash" not in body:
            continue  # 不是可执行脚本，跳过
        p = os.path.join(harness_dir, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(p, 0o755)
        print("HARNESS:", os.path.relpath(p, out))
        n += 1
if n == 0:
    print("MISSING: 未提取到任何 harness 脚本")
sys.exit(1 if (missing or n == 0) else 0)
PY
}

# ---------- 跑自检 ----------
run_check() {
  local out="$1"
  # 幂等：先按当前 PLAN.md 重新提取一次，再跑
  [ -f "$out/PLAN.md" ] && post_process "$out/PLAN.md" "$out" >/dev/null
  local dir="$out/harness"
  [ -d "$dir" ] || die "没有 ${dir}，也没有可提取的 PLAN.md"
  # 契约闸门：方案自己都不守契约，就不该执行它写出来的 harness
  if [ -f "$out/PLAN.md" ]; then
    ASTRA_MODE=validate post_process "$out/PLAN.md" "$out" >/dev/null || {
      echo "方案不守契约，拒绝执行 harness —— 先修 PLAN.md"; return 1; }
  fi
  local fail=0
  # harness 在输出目录里跑（相对路径 PLAN.md 才解析得到），并暴露两个绝对路径变量
  export ASTRA_OUT="$(cd "$out" && pwd)"
  export ASTRA_ROOT="$ROOT"
  export ASTRA_SUBJECT="${ASTRA_SUBJECT:-$ROOT}"
  for s in "$ASTRA_OUT/harness"/*.sh; do
    [ -f "$s" ] || continue
    echo "── $(basename "$s")"
    # 原样输出，不加前缀：harness 可能用 grep -qx 断言自己的输出行
    log="$(mktemp)"
    ( cd "$ASTRA_OUT" && bash "$s" 2>&1 ) > "$log"
    rc=$?
    cat "$log"
    # 退出码非 0 算失败；即便退出 0，只要 SUMMARY 里 fail=N(N>0) 也算失败
    if grep -qE 'SUMMARY .*fail=[1-9]' "$log"; then
      echo ">> FAIL (SUMMARY 报告失败但退出码为 0)"; fail=1
    fi
    rm -f "$log"
    [ "$rc" -ne 0 ] && { echo ">> FAIL (exit=$rc)"; fail=1; }
  done
  [ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "HAS FAILURE"
  return "$fail"
}

# ---------- main ----------
if [ "${1:-}" = "--check" ]; then
  # 兼容 Astra 偶尔写出的组合形式：--check --validate-only <plan>
  if [ "${2:-}" = "--validate-only" ]; then
    ASTRA_MODE=validate post_process "${3:?PLAN.md}" "$(dirname "${3:?}")"; exit $?
  fi
  run_check "${2:-.astra}"; exit $?
fi

# 只重跑提取（不再调 Astra），用于修完提取逻辑后回放已有方案
if [ "${1:-}" = "--extract" ]; then
  post_process "${2:?PLAN.md}" "${3:-$(dirname "${2:-.}")}"; exit $?
fi

# 只校验方案是否守契约（章节齐全 / harness 命名安全 / 不过长），不联网
if [ "${1:-}" = "--validate-only" ]; then
  ASTRA_MODE=validate post_process "${2:?PLAN.md}" "$(dirname "${2:?}")"; exit $?
fi

TASK="${1:-}"; [ -n "$TASK" ] && [ -f "$TASK" ] || die "用法: ask_astra.sh <task.md> [out_dir]  |  ask_astra.sh --check <out_dir>"
OUT="${2:-.astra}"
mkdir -p "$OUT"

build_context "$OUT/context.md"
echo "[1/3] 收集上下文快照 -> $OUT/context.md"

# prompt 落盘再喂 stdin：大 prompt 不怕 argv 限制，且留下可复盘的原文
{
  cat "$SKILL_DIR/references/meta-prompt.md"
  echo
  echo "===== 上下文快照 ====="
  cat "$OUT/context.md"
  echo
  echo "===== 任务 ====="
  cat "$TASK"
} > "$OUT/prompt.md"

# 只有这条路会联网，所以在这里才解析代理（否则 --check 也会被网络卡住）
resolve_proxy

echo "[2/3] 正在问 Astra（${MODEL}, effort=${EFFORT}）…"
# 默认保留会话（可在 ~/.codex/sessions 里查到）；设 ASTRA_EPHEMERAL=1 才不落盘
EPHEMERAL_FLAG=""
[ -n "${ASTRA_EPHEMERAL:-}" ] && EPHEMERAL_FLAG="--ephemeral"

"$CODEX_BIN" exec --skip-git-repo-check $EPHEMERAL_FLAG -s "$SANDBOX" \
  -m "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" \
  -o "$OUT/PLAN.md" < "$OUT/prompt.md" > "$OUT/codex.log" 2>&1
rc=$?
[ "$rc" -ne 0 ] && { echo "codex 退出码 ${rc}，日志: $OUT/codex.log"; tail -15 "$OUT/codex.log"; }

# 兜底：个别 Codex CLI 版本（或降级路径）不会真的写 -o 指定的文件，
# 但内容还在它的输出里 —— 这时把输出捞回来，别让一次编译白跑。
if [ "$rc" -eq 0 ] && [ ! -s "$OUT/PLAN.md" ] && [ -s "$OUT/codex.log" ]; then
  cp "$OUT/codex.log" "$OUT/PLAN.md"
fi

echo "[3/3] 校验章节契约 + 提取 harness"
post_process "$OUT/PLAN.md" "$OUT"; vrc=$?

# 运行记录：让后续 harness 能断言"这次编译到底发生了什么"
{
  echo "codex_exit=$rc"
  echo "validation_exit=$vrc"
  echo "model=$MODEL"
  echo "effort=$EFFORT"
  # 只记来源不记地址：代理地址里可能带凭据，不该落进任何产物文件
  echo "proxy=${PROXY_KIND}"
  # 按记录数统计（与 awk 'END{print NR}' 一致），避免末尾无换行时差一行
  # 按记录数统计（与 awk 'END{print NR}' 一致），避免末尾无换行时差一行
  echo "plan_lines=$(awk 'END{print NR+0}' "$OUT/PLAN.md" 2>/dev/null)"
  # 会话 ID：让你能去 ~/.codex/sessions 里翻原始记录
  echo "session_id=$(sed -n 's/^session id: //p' "$OUT/codex.log" 2>/dev/null | head -1)"
} > "$OUT/run.status"

echo
lines=$(wc -l < "$OUT/PLAN.md" 2>/dev/null | tr -d ' ')
echo "方案: $OUT/PLAN.md  ($lines 行)"
[ "${lines:-0}" -gt 400 ] 2>/dev/null && echo "WARN: 方案超过 400 行，违反 minimalism，建议重跑或要求精简"
ls -1 "$OUT/harness" 2>/dev/null | sed 's/^/harness: /'
echo "自检: ask_gpt.sh --check $OUT"
exit "$vrc"
