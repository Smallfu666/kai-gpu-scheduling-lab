"""MNIST 小訓練：支援 checkpoint 續跑（CKPT_DIR），印出每 epoch 時間與 GPU 資訊。"""
import os, time, torch, torch.nn as nn, torch.nn.functional as F
import torchvision as tv
EPOCHS = int(os.environ.get("EPOCHS", "3"))
CKPT_DIR = os.environ.get("CKPT_DIR")
EPOCH_SLEEP = float(os.environ.get("EPOCH_SLEEP", "0"))  # 拉長訓練方便觀察搶占
dev = torch.device("cuda")
print("host", os.uname().nodename, "arch", os.uname().machine, "torch", torch.__version__,
      "gpu", torch.cuda.get_device_name(0), "cap", torch.cuda.get_device_capability(0), flush=True)
tfm = tv.transforms.Compose([tv.transforms.ToTensor(), tv.transforms.Normalize((0.1307,), (0.3081,))])
train = torch.utils.data.DataLoader(tv.datasets.MNIST("/data", train=True, transform=tfm), batch_size=256, shuffle=True, num_workers=2)
test = torch.utils.data.DataLoader(tv.datasets.MNIST("/data", train=False, transform=tfm), batch_size=1024)
class Net(nn.Module):
    def __init__(s):
        super().__init__()
        s.c1 = nn.Conv2d(1, 64, 3); s.c2 = nn.Conv2d(64, 128, 3); s.f1 = nn.Linear(128 * 12 * 12, 256); s.f2 = nn.Linear(256, 10)
    def forward(s, x):
        x = F.max_pool2d(F.relu(s.c2(F.relu(s.c1(x)))), 2)
        return s.f2(F.relu(s.f1(torch.flatten(x, 1))))
m = Net().to(dev); opt = torch.optim.Adam(m.parameters(), 1e-3); start = 0
ck = os.path.join(CKPT_DIR, "ckpt.pt") if CKPT_DIR else None
if ck and os.path.exists(ck):
    s = torch.load(ck); m.load_state_dict(s["model"]); opt.load_state_dict(s["opt"]); start = s["epoch"] + 1
    print(f"RESUMED from epoch {s['epoch']}", flush=True)
t0 = time.time()
for ep in range(start, EPOCHS):
    te = time.time(); m.train()
    for x, y in train:
        x, y = x.to(dev, non_blocking=True), y.to(dev, non_blocking=True)
        opt.zero_grad(); F.cross_entropy(m(x), y).backward(); opt.step()
    torch.cuda.synchronize(); m.eval(); ok = 0
    with torch.no_grad():
        for x, y in test: ok += (m(x.to(dev)).argmax(1).cpu() == y).sum().item()
    print(f"epoch {ep} time {time.time()-te:.1f}s acc {ok/100:.2f}% maxmem {torch.cuda.max_memory_allocated()/2**20:.0f}MiB", flush=True)
    if ck: os.makedirs(CKPT_DIR, exist_ok=True); torch.save({"model": m.state_dict(), "opt": opt.state_dict(), "epoch": ep}, ck)
    time.sleep(EPOCH_SLEEP)
print(f"DONE total {time.time()-t0:.1f}s", flush=True)
