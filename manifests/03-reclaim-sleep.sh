#!/usr/bin/env bash
# 產生「某人送 N 個 1-GPU Job」的 YAML。用法：03-reclaim-sleep.sh <queue> <count> <sleep秒>
q=$1; n=$2; s=$3
for i in $(seq 1 $n); do cat <<YAML
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $q-job-$i
  namespace: lab
  labels: {exp: exp3, owner: $q}
spec:
  backoffLimit: 0
  podFailurePolicy:
    rules:
    - action: Ignore            # 被 KAI 搶占（DisruptionTarget）不算失敗，Job 會重建 pod 重新排隊
      onPodConditions:
      - type: DisruptionTarget
  template:
    metadata:
      labels: {kai.scheduler/queue: $q, exp: exp3, owner: $q}
    spec:
      schedulerName: kai-scheduler
      runtimeClassName: nvidia
      restartPolicy: Never
      containers:
      - name: main
        image: nvidia/cuda:12.8.1-base-ubuntu22.04
        command: ["bash","-c","nvidia-smi --query-gpu=name --format=csv,noheader; sleep $s"]
        resources:
          limits: {nvidia.com/gpu: 1}
YAML
done
