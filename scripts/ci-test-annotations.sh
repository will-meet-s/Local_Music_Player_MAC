#!/bin/bash
# 把 swift test 日志里的失败用例写成 GitHub annotations，供不登录也能看到失败原因。
set -uo pipefail
LOG="${1:-swift-test.log}"

if [[ ! -s "$LOG" ]]; then
    echo "::error title=没有单测日志::swift test 在运行用例之前就失败了（多半是编译错误），看「单测」这一步的原始输出"
    exit 0
fi

mapfile -t FAILS < <(grep -E '^/.+:[0-9]+: error: -\[' "$LOG")
if [[ ${#FAILS[@]} -eq 0 ]]; then
    echo "::error title=单测失败但没解析到用例::可能是编译错误或测试进程崩溃，看「单测」这一步的原始输出"
    exit 0
fi

echo "::error title=失败用例数::${#FAILS[@]} 条（下面最多列出 9 条）"
for line in "${FAILS[@]:0:9}"; do
    file="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"
    case_name="$(sed -E 's/.*error: -\[([^]]+)\].*/\1/' <<<"$line")"
    msg="$(sed -E 's/.*error: -\[[^]]+\] : //' <<<"$line" | cut -c1-1500)"
    msg="${msg//'%'/'%25'}"
    rel="${file#"$GITHUB_WORKSPACE"/}"
    echo "::error file=${rel},line=${lineno},title=${case_name}::${msg}"
done
