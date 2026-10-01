#!/bin/bash
# 把编译错误和 swift test 的失败用例写成 GitHub annotations，不登录也能看到失败原因。
set -uo pipefail
esc() { local m="${1//'%'/'%25'}"; printf '%s' "${m:0:1500}"; }
rel() { printf '%s' "${1#"$GITHUB_WORKSPACE"/}"; }

LINES=()
for LOG in "$@"; do
    [[ -s "$LOG" ]] || continue
    while IFS= read -r l; do LINES+=("$l"); done < <(grep -E '^/.+:[0-9]+(:[0-9]+)?: error: ' "$LOG" | sort -u)
done

if [[ ${#LINES[@]} -eq 0 ]]; then
    echo "::error title=没解析到错误行::可能是依赖解析失败或测试进程崩溃，看「编译」「单测」两步的原始输出"
    exit 0
fi

echo "::error title=错误数::${#LINES[@]} 条（下面最多列出 9 条）"
for line in "${LINES[@]:0:9}"; do
    file="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"
    if [[ "$line" == *"error: -["* ]]; then
        title="$(sed -E 's/.*error: -\[([^]]+)\].*/\1/' <<<"$line")"
        msg="$(sed -E 's/.*error: -\[[^]]+\] : //' <<<"$line")"
    else
        title="编译错误"
        msg="$(sed -E 's/.*: error: //' <<<"$line")"
    fi
    echo "::error file=$(rel "$file"),line=${lineno},title=${title}::$(esc "$msg")"
done
