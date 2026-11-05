#!/usr/bin/env bash
# 分卡測試：產生一個分卡 Pod 的 YAML。用法：05-fraction.sh <name> <node> <gpu-fraction> <TARGET_MIB> | kubectl apply -f -
cat <<YAML
---
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: lab
  labels: {kai.scheduler/queue: bob, exp: exp5}
  annotations: {gpu-fraction: "$3"}
spec:
  schedulerName: kai-scheduler
  restartPolicy: Never
  nodeSelector: {kubernetes.io/hostname: $2}
  containers:
  - name: main
    image: example/torch:cu130
    imagePullPolicy: IfNotPresent
    command: ["bash","-c","nvidia-smi --query-gpu=memory.total,memory.used --format=csv; python /app/alloc.py"]
    env: [{name: TARGET_MIB, value: "$4"}, {name: STEP_MIB, value: "1024"}, {name: HOLD_S, value: "90"}]
YAML
