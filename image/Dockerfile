# 實驗用工作負載映像：同一個 tag 分別在 amd64 與 arm64 機器上建置，再匯入各節點的 k3s containerd
# （或推到 registry 做成 multi-arch manifest）
# 重現性：base image 應以 digest 鎖定（FROM python:3.12-slim@sha256:<digest>），digest 用
# `docker buildx imagetools inspect python:3.12-slim` 查；建好後也記下兩個架構映像的 digest。
FROM python:3.12-slim
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1
# 版本與 README 一致：torch 2.14.1+cu130；torchvision 0.29.x 對應 torch 2.14（兩者在 cu130 index 都有 amd64 / arm64 wheel）
RUN pip install --retries 10 --timeout 120 torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu130
RUN python -c "import torchvision as tv; tv.datasets.MNIST('/data', download=True); tv.datasets.MNIST('/data', train=False, download=True)"
COPY train.py alloc.py /app/
WORKDIR /app
