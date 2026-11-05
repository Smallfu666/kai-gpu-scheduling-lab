"""逐步配置 GPU 記憶體（每次 STEP_MIB），直到失敗或到 TARGET_MIB；用來測分卡記憶體隔離。"""
import os, time, torch
step = int(os.environ.get("STEP_MIB", "1024")); target = int(os.environ.get("TARGET_MIB", "16000"))
free, total = torch.cuda.mem_get_info()
print(f"cuda sees total {total/2**20:.0f}MiB free {free/2**20:.0f}MiB; CUDA_DEVICE_MEMORY_LIMIT={os.environ.get('CUDA_DEVICE_MEMORY_LIMIT')}", flush=True)
bufs = []; got = 0
try:
    while got < target:
        bufs.append(torch.empty(step * 2**20, dtype=torch.uint8, device="cuda")); got += step
        print(f"allocated {got} MiB", flush=True)
except Exception as e:
    print(f"ALLOC FAILED at {got + step} MiB: {type(e).__name__}: {str(e).splitlines()[0][:200]}", flush=True)
print(f"RESULT max_allocated={got}MiB", flush=True)
time.sleep(int(os.environ.get("HOLD_S", "60")))
