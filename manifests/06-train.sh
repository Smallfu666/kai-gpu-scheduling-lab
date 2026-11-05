#!/usr/bin/env bash
# 產生 MNIST 訓練 Job。用法：06-train.sh <name> <gpu.product> [epochs]
n=$1; prod=$2; ep=${3:-5}
cat <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: $n, namespace: lab, labels: {exp: exp6}}
spec:
  backoffLimit: 0
  template:
    metadata: {labels: {kai.scheduler/queue: alice, exp: exp6}}
    spec:
      schedulerName: kai-scheduler
      runtimeClassName: nvidia
      restartPolicy: Never
      nodeSelector: {nvidia.com/gpu.product: $prod}
      containers:
      - name: train
        image: example/torch:cu130
        imagePullPolicy: IfNotPresent
        command: ["python","/app/train.py"]
        env: [{name: EPOCHS, value: "$ep"}]
        resources:
          limits: {nvidia.com/gpu: 1}
YAML
