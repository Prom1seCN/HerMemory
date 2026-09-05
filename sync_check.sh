#!/usr/bin/env bash
# sync_check.sh — 同步健康自检（一句话触发：「体检一下」「同步正常吗」）
# 对应 Agent.md §1 #2 多端同步的状态自检；检查项为骨架提案，读写安全规则待云盘实机测试定
# 定位：只读检查，本脚本永不写任何文件
set -uo pipefail

# ---------- 配置区（install.sh 装机时写入实际路径） ----------
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SYNC_ROOT="${SYNC_ROOT:-$HOME/HerMemory}"          # 同步根（用户文档 + HerMemory/）
CORE_FILES=(SOUL.md MEMORY.md USER.md AGENTS.md)   # 软链四件（SOUL/AGENTS 在 HERMES_HOME 根，MEMORY/USER 在 memories/）
CONFLICT_PATTERNS=('*.conflict' '* (1)*' '*~')     # 同步冲突产物特征

# ---------- 输出工具（人话，不用术语） ----------
ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
bad()  { echo "❌ $1"; }

# ---------- 1. 软链四件健康 ----------
# 每个核心文件：同步库里存在 + 服务器侧软链指向它 + 指向有效
check_links() {
  for f in "${CORE_FILES[@]}"; do
    # TODO(实测)：确认 MEMORY/USER 软链位置 memories/ 与 SOUL/AGENTS 在 HERMES_HOME 根的最终路径表
    : # TODO
  done
}

# ---------- 2. 同步目录可达 ----------
# 同步根存在、非空、且不是未水合的占位符状态
# 上游事实：iCloud/CloudStorage 未水合文件读会无限等待，检测须 fail-closed
check_sync_root() {
  # TODO(实测)：目录存在性；云盘占位符探测（未水合判定方式待云盘实机测试，见待验证清单）
  : # TODO
}

# ---------- 3. 空文件扫描 ----------
# 核心文件内容为空 = 同步异常信号 → 报警并提示恢复备份；如何处置待云盘实机测试后定
check_empty_files() {
  # TODO：四个核心 md 任一为 0 字节 → bad 提示「检测到空文件，建议先恢复备份」
  : # TODO
}

# ---------- 4. 冲突副本扫描 ----------
check_conflicts() {
  # TODO：按 CONFLICT_PATTERNS 在同步根下扫描；命中 → warn 列出路径，提示人工处理，脚本不合并
  : # TODO
}

# ---------- 5. 最近备份时间 ----------
check_backup() {
  # TODO：读取 updates.pre_update_backup 快照目录的最新时间戳 → 人话输出「上次快照：X 天前」
  : # TODO
}

# ---------- 6. AGENTS.md 威胁扫描检查 ----------
# 上游机制：AGENTS.md 含触发词会被整体 BLOCK（规则静默失效）——脚本无法直接探测扫描结果，
# TODO(实测)：找到可行的旁证（如 hermes doctor 输出 / 日志特征），找不到则从脚本中移除此项
check_agents_block() {
  : # TODO
}

# ---------- 汇总 ----------
main() {
  echo "—— HerMemory 体检 ——"
  check_links
  check_sync_root
  check_empty_files
  check_conflicts
  check_backup
  check_agents_block
  echo "—— 完 ——"
}

main "$@"
