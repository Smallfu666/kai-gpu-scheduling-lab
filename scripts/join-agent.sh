#!/usr/bin/env bash
# 在「要加入叢集的 agent 節點」上執行，把它以 k3s agent 加入既有的 k3s server。
# kubelet 與 flannel 只綁在 overlay 網路介面上（對應 README 附錄 A.1 的 server 設定）。
#
# 用法（在 agent 節點上，需 sudo）：
#   sudo ./join-agent.sh <server-overlay-ip> <this-node-overlay-ip> <overlay-iface> <token-file>
#
#   <token-file>：從 server 的 /var/lib/rancher/k3s/server/node-token 複製過來的檔案。
#                 請用安全的管道傳遞（例如 ssh 管線），不要把 token 寫進 repo 或指令列。
set -euo pipefail
[ $# -eq 4 ] || { sed -n '5,8p' "$0"; exit 2; }
server_ip=$1; node_ip=$2; iface=$3; token_file=$4
K3S_VERSION=${K3S_VERSION:-v1.35.7+k3s1}

install -d -m 755 /etc/rancher/k3s
install -m 600 "$token_file" /etc/rancher/k3s/agent-token
cat > /etc/rancher/k3s/config.yaml <<CFG
server: https://${server_ip}:6443
token-file: /etc/rancher/k3s/agent-token
node-ip: ${node_ip}
flannel-iface: ${iface}
kubelet-arg:
  - address=${node_ip}
CFG

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC=agent sh -
systemctl status k3s-agent --no-pager | head -3
