#!/usr/bin/env bash
# 清掉某個實驗留下的 Job 與 Pod（依 exp label），等刪除完成後才返回，避免前一輪工作還占著卡。
# 用法：cleanup-exp.sh <exp-label>   例：cleanup-exp.sh exp3
# 各實驗的 label：exp1、exp3、exp3b、exp4、exp5、exp6；gpu-submit 送的工作用 gpu-submit=true（傳 --submit）。
set -euo pipefail
[ $# -eq 1 ] || { sed -n '2,4p' "$0"; exit 2; }
ns=${GPU_NS:-lab}
if [ "$1" = --submit ]; then sel='gpu-submit=true'; else sel="exp=$1"; fi
# 先刪 Job（foreground：等它的 pod 一起刪完），避免 Job controller 在刪 pod 後又補建
kubectl -n "$ns" delete job -l "$sel" --cascade=foreground --wait=true --ignore-not-found
kubectl -n "$ns" delete pod -l "$sel" --wait=true --ignore-not-found
left=$(kubectl -n "$ns" get pod -l "$sel" --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$left" = 0 ] || { echo "還有 $left 個 pod 沒刪完（$sel）" >&2; exit 1; }
echo "已清除 $ns 中 $sel 的 Job 與 Pod"
