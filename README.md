# KAI GPU Scheduling Lab：k3s + NVIDIA KAI Scheduler on 4 heterogeneous GPUs

> **English summary.** A hands-on lab that runs NVIDIA KAI Scheduler v0.18.7 on a 4-node k3s v1.35.7 cluster
> with four different GPUs: 2× RTX A4500, an RTX 3060 and an NVIDIA GB10 (arm64, unified memory);
> three nodes form a low-latency group and one is a high-latency remote node.
> It tests card-type selection and queueing, hierarchical queues with quota / limit / over-quota weight,
> reclaim of borrowed GPUs (and checkpoint-based resume after eviction), gang scheduling spanning two nodes,
> GPU fractions with and without HAMi-core memory isolation, and real PyTorch training on amd64 and arm64.
> Every experiment includes the manifests and excerpts of the actual output. The write-up also explains how KAI
> computes fair share, lists the pitfalls found (GB10 missing `nvidia.com/gpu.memory`, preemption vs. `podFailurePolicy`,
> kubelet bound to an overlay IP), and compares KAI with Volcano + Kueue + HAMi and with Slurm for small teams.
> The write-up is in Traditional Chinese; manifests, commands and logs are language-neutral.

測試日期：2026-11-05。節點以 Node-A～Node-D 代稱；文中 log 是實際輸出的節錄，只把節點名稱換成代號，並刪掉與主題無關的欄位（例如 pod IP）。

## Repository layout（檔案結構）

```
README.md            本文：實驗設計、結果、KAI 原理說明、比較與建議
manifests/           各實驗的 YAML 與產生 YAML 的小腳本（檔名前綴對應實驗編號）
  00-namespace.yaml              namespace `lab`
  01-card-type.yaml              實驗 1：指定卡型、滿了排隊
  02-queues.yaml                 實驗 2：parent queue `lab` + alice / bob / carol
  03-*.yaml, 03-reclaim-sleep.sh 實驗 3：借用與 reclaim
  03b-*.yaml                     實驗 3b：被 reclaim 的訓練從 checkpoint 續跑（03b-ckpt-reset.yaml 清舊 checkpoint）
  04-blocker.yaml, 04-gang.yaml  實驗 4：gang scheduling（先占位、再送 gang）
  05-*.yaml, 05-fraction.sh      實驗 5：分卡與 HAMi-core 記憶體隔離
  06-train.sh                    實驗 6：在指定卡型上跑 MNIST 訓練
tools/gpu-submit     實驗 7：不用寫 YAML 就能送單卡 / 分卡 / gang 工作
tools/gpu-status     實驗 7：佇列用量、工作狀態、排隊原因、各節點 GPU 使用量
image/               訓練映像：Dockerfile（線上安裝 torch）、Dockerfile.site（離線用預先準備的 site-packages）、train.py、alloc.py
scripts/join-agent.sh  以 k3s agent 加入叢集，kubelet / flannel 只綁 overlay 介面
scripts/cleanup-exp.sh 依 exp label 清掉某個實驗的 Job / Pod 並等刪除完成
```

## How to reproduce（重現步驟）

前提：每個 GPU 節點已裝好 NVIDIA 驅動與 nvidia-container-toolkit。YAML 裡的 `<node-b>`、`<a4500-node>` 等請換成 `kubectl get nodes` 看到的實際節點名稱。

1. **建叢集**：k3s server 設定見附錄 A.1；agent 用 `scripts/join-agent.sh` 加入。
2. **裝 GPU Operator、KAI Scheduler、（選用）kai-resource-isolator**：指令見附錄 A.2。GB10 等統一記憶體節點要補 `nvidia.com/gpu.memory` label（第 6 節問題 4）。
3. **建映像**：在 amd64 與 arm64 機器上各自 `docker build -t example/torch:cu130 image/`（Dockerfile 已鎖 torch / torchvision 版本；base image 建議再以 digest 鎖定），匯入各節點（`ctr -n k8s.io images import`）或推到 registry 做成 multi-arch manifest。
4. **namespace 與佇列**：`kubectl apply -f manifests/00-namespace.yaml -f manifests/02-queues.yaml`
5. **依序跑實驗**。每個實驗結束、進下一個之前都要清場，否則前一輪的工作（例如實驗 3 的 `sleep 3600`）還占著卡，後面實驗的前提就不成立：

   ```bash
   scripts/cleanup-exp.sh <exp-label>   # 依 label 刪 Job / Pod，等刪除完成才返回；label 為 exp1、exp3、exp3b、exp4、exp5、exp6
   ```

   - 實驗 1：`kubectl apply -f manifests/01-card-type.yaml` → 結束後 `scripts/cleanup-exp.sh exp1`
   - 實驗 3：`kubectl apply -f manifests/03-alice.yaml`，之後依第 5 節的時間表 apply `03-bob.yaml`、`03-carol.yaml`；或用 `manifests/03-reclaim-sleep.sh <queue> <count> <sleep秒> | kubectl apply -f -` → 結束後 `scripts/cleanup-exp.sh exp3`
   - 實驗 3b：`03b-reclaim-ckpt.yaml` → `03b-alice-fill.yaml` → `03b-bob-pinned.yaml` → 結束後 `scripts/cleanup-exp.sh exp3b`。checkpoint 放在 Node-B 的 hostPath，**清場不會刪掉它**；重跑前先清舊 checkpoint，否則新的訓練會直接從上次的 epoch 續跑：

     ```bash
     kubectl apply -f manifests/03b-ckpt-reset.yaml
     kubectl -n lab wait --for=jsonpath='{.status.phase}'=Succeeded pod/ckpt-reset --timeout=300s
     kubectl -n lab delete pod ckpt-reset
     ```

   - 實驗 4：blocker 與 gang 分兩步送，確定 blocker 已占住卡再送 gang，否則 gang 可能先拿到兩張卡：

     ```bash
     kubectl apply -f manifests/04-blocker.yaml
     kubectl -n lab wait --for=condition=Ready pod/blocker --timeout=600s
     kubectl apply -f manifests/04-gang.yaml
     kubectl get podgroups -n lab          # 觀察 gang 整組 Pending
     kubectl -n lab delete pod blocker     # 兩個 gang pod 同時開始
     scripts/cleanup-exp.sh exp4
     ```

   - 實驗 5：`05-fraction-nonenforced.yaml`（預設模式與 HamiCore 各跑一次，中間 `scripts/cleanup-exp.sh exp5`）、`05-fraction-gb10-mem.yaml` → 結束後 `scripts/cleanup-exp.sh exp5`
   - 實驗 6：`manifests/06-train.sh train-a4500 NVIDIA-RTX-A4500 | kubectl apply -f -`（卡型換成 `NVIDIA-GB10`、`NVIDIA-GeForce-RTX-3060`）→ 結束後 `scripts/cleanup-exp.sh exp6`
   - 實驗 7：把 `tools/` 加入 `PATH`，`gpu-submit --help`、`gpu-status`；結束後 `scripts/cleanup-exp.sh --submit`
6. 觀察：`kubectl get queues`、`kubectl -n lab get pods -o wide`、`kubectl -n lab get events --field-selector reason=Unschedulable`、`kubectl get podgroups -n lab`。

---

## 目錄

1. [摘要](#1-摘要)
2. [背景與目標](#2-背景與目標)
3. [KAI Scheduler 是什麼、怎麼運作](#3-kai-scheduler-是什麼怎麼運作)
4. [測試環境](#4-測試環境)
5. [實驗 0–7](#5-實驗-07)
6. [遇到的問題與解法](#6-遇到的問題與解法)
7. [與 Volcano + Kueue + HAMi 的比較](#7-與-volcano--kueue--hami-的比較)
8. [對小規模團隊的建議](#8-對小規模團隊的建議)
9. [附錄](#9-附錄)

---

## 1. 摘要

**結論：KAI Scheduler 在功能上完全涵蓋「少數人共用少量異質 GPU」需要的四件事，四張不同型號的卡（2× RTX A4500、RTX 3060、NVIDIA GB10）全部實測可用。但對只有數人、數張卡的團隊來說，Kubernetes 本身的維運成本通常大於好處；建議先用輕量排隊方案，需要公平分配與搶占時再上 Slurm，k8s + KAI 留給要做長期平台或 GPU 數量明顯增加的情境。**

實測結果一覽：

| 需求 | KAI 的做法 | 結果 |
|---|---|---|
| 指定卡型、滿了就排隊 | `nodeSelector: nvidia.com/gpu.product` | 只排到指定卡型；卡滿時排隊，前一個工作結束約 3 秒內接上；旁邊有空的別種卡也不會亂跑過去（實驗 1） |
| 每人保證額度、閒置可借、有人要時歸還 | 階層式 Queue：`quota` / `limit` / `overQuotaWeight` + reclaim | 一人先借光 4 張卡，其他兩人各送 1 個工作，KAI 立即踢掉借用者超額的部分，收斂到 2/1/1，之後不會來回搶（實驗 2、3） |
| 被踢的訓練能續跑 | Job `backoffLimit` + 程式自己存 checkpoint | 被踢在 epoch 5，重新排上後從 epoch 6 續跑完成（實驗 3b） |
| 多卡工作要嘛一起開始、要嘛都不開始（gang） | annotation `kai.scheduler/batch-min-member` | 只剩 1 張卡時兩個 pod 都不啟動；卡夠時在兩個節點上同時開始，相差 20 ms（實驗 4） |
| 一張卡分給多人 | annotation `gpu-fraction` / `gpu-memory` | 預設模式**不隔離記憶體**（「半張」的工作吃到 15 GB）；加上 HAMi-core 隔離後容器只看得到 10 GB，超過即 CUDA OOM；GB10 上也有上限，但實際上限比要求多約 6.4%（實驗 5） |
| 異質硬體跑同一份訓練 | 同一個映像名稱、amd64/arm64 各自建置 | A4500、RTX 3060、GB10（arm64）都跑完 PyTorch 訓練（實驗 6） |
| 使用者介面 | 兩支小工具 `gpu-submit` / `gpu-status` | 使用者不用寫 YAML 就能送單卡、分卡、gang 工作並查看排隊原因（實驗 7） |

測試中的阻礙**幾乎都來自環境，而不是 KAI**：對外頻寬不足導致拉映像極慢、遠端節點延遲高、GB10 統一記憶體缺少一個節點 label、以及幾個 Kubernetes Job 語意上的細節。這些都整理在第 6 節。

---

## 2. 背景與目標

### 2.1 情境

典型的小型研究團隊：

- 數名使用者（本測試模擬 3 人：alice、bob、carol）。
- 少量 GPU，而且**型號不一**：兩張工作站卡 RTX A4500（20 GB）、一張消費級 RTX 3060 12 GB、一台 NVIDIA GB10（DGX Spark 類，arm64、CPU/GPU 統一記憶體）。
- 機器**不在同一個網段**，節點之間透過加密 overlay 網路互連；其中 3 台彼此低延遲，1 台是高延遲、低頻寬的遠端節點。
- 現況多半是「先講好誰用哪張卡」或直接登入搶卡，容易出現有人整天占著卡、別人只能等；或卡空著但沒人知道。

### 2.2 想回答的問題

1. 能不能讓使用者**指定卡型**送工作，卡滿就排隊，而不是被排到別種卡上？
2. 能不能給每人**保證額度**、閒置時可借用，別人要用時**自動歸還**，而且不會兩人互搶造成震盪？
3. 被搶占的訓練要怎麼**續跑**？
4. 多卡工作能不能做到 **gang scheduling**（全部到齊才開始）？
5. 一張卡能不能**分給多人**，而且記憶體真的隔離？
6. 異質硬體（含 arm64 的 GB10）能不能用**同一套流程**跑真的訓練？
7. 對使用者來說，介面可以簡化到什麼程度？
8. 和社群常見的 Volcano + Kueue + HAMi 組合相比、和 Slurm 相比，該怎麼選？

### 2.3 為什麼選 KAI Scheduler

KAI Scheduler 是 NVIDIA 開源的 Kubernetes GPU 排程器（源自 Run:ai 的排程核心）。它把「佇列、配額、借用與歸還、gang、分卡」都放在**同一個排程器**裡，以單一 Helm chart 安裝，理論上比把 Volcano、Kueue、HAMi 三套元件串起來簡單。本測試要驗證它在真實異質硬體上是否真的如此。

---

## 3. KAI Scheduler 是什麼、怎麼運作

這一節給沒用過 KAI 的讀者。後面每個實驗都會回頭對照這裡的概念。

### 3.1 元件

安裝 KAI 的 Helm chart 後，operator 會建立以下元件（本測試實測 7 個元件合計約 50m CPU、160 MiB 記憶體，開銷很小）：

| 元件 | 角色 |
|---|---|
| kai-operator | 依設定（`Config`、`SchedulingShard` CRD）部署並管理其他元件 |
| admission | webhook，檢查/補充送進來、指定 `schedulerName: kai-scheduler` 的 pod |
| pod-grouper | 把 pod 依其上層物件（Job、PyTorchJob、JobSet…）分組，建立 **PodGroup**（排程的最小單位，帶 `minMember`） |
| kai-scheduler | 排程核心：週期性取快照、計算各佇列的 fair share、決定誰該分到哪張卡、誰該被踢 |
| binder | 收到排程決定（`BindRequest`）後實際把 pod 綁到節點；分卡時負責建立 GPU 預留 pod、寫入分卡相關設定 |
| podgroup-controller | 維護 PodGroup 狀態 |
| queue-controller | 維護 Queue 狀態（已分配/要求中的資源量） |

如果要分卡的**記憶體隔離**，另外安裝 `kai-resource-isolator`（一個 webhook + 每個節點一個同步 HAMi-core 函式庫的 DaemonSet）。

### 3.2 一個 pod 從送出到執行的流程

```
使用者送 Job / Pod
  │  spec.schedulerName: kai-scheduler
  │  label  kai.scheduler/queue: <佇列>
  ▼
admission webhook ──► pod-grouper：建立 PodGroup（minMember = 1 或 batch-min-member）
  ▼
kai-scheduler 每個週期：
  1. 取叢集快照（節點、GPU、所有 PodGroup、所有 Queue）
  2. 依 Queue 樹計算每個佇列此刻的 fair share（見 3.4）
  3. 依序執行 actions：
       allocate   有空卡就分配（gang：整組放得下才放）
       reclaim    低於 fair share 的佇列，向超過 fair share 的佇列「討回」資源
       preempt    同一佇列內，高優先序踢低優先序
       （另有 consolidation、stale gang eviction 等）
  4. 產生 BindRequest
  ▼
binder：（分卡時先建立 GPU 預留 pod）→ 綁定節點 → kubelet 啟動容器
```

被 reclaim 或 preempt 選中的 pod 會被刪除（有 grace period，預設 30 秒），PodGroup 回到排隊狀態，由上層 Job 決定要不要重建 pod（見實驗 3 與第 6 節）。

### 3.3 Queue：quota、limit、overQuotaWeight

KAI 的佇列是**階層式**的。本測試的設計是：一個 parent queue 代表整個團隊，底下每位使用者一個 leaf queue。每個 queue 對每種資源（gpu、cpu、memory）各有三個參數：

| 參數 | 意義 | 本測試設定（leaf） |
|---|---|---|
| `quota` | **保證額度**（deserved）。在額度內的使用，原則上不會被別的佇列 reclaim | gpu: 1（每人保證 1 張） |
| `limit` | **上限**，含借用。`-1` = 不限 | gpu: -1（閒置的卡都可以借） |
| `overQuotaWeight` | 超出 quota 的那部分，多個佇列都想借時**按權重分** | 1（大家平分） |

> ⚠️ 預設值陷阱：`limit` **沒寫等於 0**，也就是「不准超出 quota」；cpu、memory 沒寫也會被當成 0 而擋住工作。所以範本裡每一項都明寫（實驗 2、第 6 節）。

### 3.4 Fair share 與 reclaim：KAI 怎麼決定該踢誰

可以把 fair share 想成「此刻這個佇列**應得**多少卡」，每個排程週期依當下的需求重新算：

1. 先滿足每個佇列的 `quota`（但不超過它實際要求的量）。
2. 剩下的卡，分給「要求量 > quota」的佇列，**依 `overQuotaWeight` 按比例分**，且不超過各自的 `limit` 與要求量。

接著：

- **allocate**：有空卡就先給，即使超過 fair share（這就是「借用」）。
- **reclaim**：若某佇列的實際分配**低於**它的 fair share、又沒有空卡，KAI 會從**超過** fair share 的佇列挑工作踢掉，把卡「討回來」。
- 為了避免震盪，reclaim 只在「踢完之後，討回方不會反過來超過自己的 fair share、被踢方也不會因此低於自己的 fair share」時才進行。

以實驗 3 的數字為例（共 4 張卡、三人 quota 各 1、權重相同）：

| 狀態 | 各佇列要求量 | fair share 計算 | 結果 |
|---|---|---|---|
| 只有 alice 要 4 張 | alice 4 | 只有 alice 有需求 → alice 4 | alice 借光 4 張 |
| bob 要 1 張 | alice 4、bob 1 | bob 的 quota 1 先保證 → alice 3、bob 1 | alice 超出 fair share，被 reclaim 1 張給 bob |
| carol 要 1 張 | alice 4、bob 1、carol 1 | 三人各 quota 1，剩 1 張只有 alice 要 → alice 2、bob 1、carol 1 | 再 reclaim alice 1 張給 carol |
| bob 再要第 2 張 | alice 4、bob 2、carol 1 | 剩 1 張由 alice、bob 依權重平分 → alice 1.5、bob 1.5、carol 1 | alice 2 > 1.5，但若把一張從 alice 給 bob，就變成 bob 2 > 1.5、alice 1 < 1.5，只是換人超額 → **不搶**，bob 的第 2 個工作排隊 |
| alice 結束 1 個工作 | | 空出 1 張 | 由排隊中的 bob 取得 |

最後一列是實驗中最重要的觀察：**KAI 不會為了 0.5 張的差距來回踢工作**，這對訓練工作很重要。

> 上表的 fair share 數字是依 KAI 的公開設計推算，用來解釋觀察到的行為；實際排程結果見實驗 3 的 log。

### 3.5 Gang scheduling

分散式訓練（例如 2 個 pod 各用 1 張卡做 DDP）如果只有一個 pod 先啟動，它會卡在等另一半、白白占著卡。KAI 以 **PodGroup 的 `minMember`** 解決：在 Job 上加 annotation `kai.scheduler/batch-min-member: "2"`，pod-grouper 建立 `minMember=2` 的 PodGroup，排程器只有在**整組都放得下時**才一起分配，否則全部維持 Pending，而且不占任何卡。KAI 也直接支援 PyTorchJob、JobSet 等常見的多 pod 工作型態。

### 3.6 分卡（GPU fraction）與記憶體隔離

在 pod 上加 annotation：

- `gpu-fraction: "0.5"`：要半張卡；或
- `gpu-memory: "8192"`：要 8192 MiB 的 GPU 記憶體（實測 HamiCore 實際給的上限略高於此值，見實驗 5）。

運作方式：

1. 排程器把多個分卡 pod 放進同一個「GPU group」（同一張實體卡）。
2. binder 在 `kai-resource-reservation` namespace 建立一個**預留 pod**，用一般的 `nvidia.com/gpu: 1` 向 device plugin 占下整張卡，取得卡的身分（UUID），再讓同組的分卡 pod 透過 `NVIDIA_VISIBLE_DEVICES` 看到這張卡。
   - 因此從 Kubernetes 的角度，這張卡顯示為「已用 1」。自己寫監控時要把預留 pod 排除，否則會重複計算。
3. 記憶體隔離有兩種模式（`global.gpuSharingMode`）：

| 模式 | 做法 | 隔離效果 |
|---|---|---|
| NonMemoryEnforced（預設） | 只在排程帳面上算「半張」 | **完全不隔離**：容器看得到整張卡，可以吃掉別人的記憶體 |
| HamiCore | `kai-resource-isolator` webhook 對分卡 pod 注入 `/etc/ld.so.preload` 與 HAMi-core 函式庫 `libvgpu.so`，並由 KAI 算出 `CUDA_DEVICE_MEMORY_LIMIT` | 攔截 CUDA 記憶體配置；容器只看得到自己的額度，超過即 CUDA OOM |

HamiCore 的限制要清楚：

- **只限記憶體，不限算力**（同卡的工作仍會互搶 SM）。
- 機制是 LD_PRELOAD，**刻意繞過是做得到的**。它足以防止使用者之間的誤用（例如忘了設 `PYTORCH_CUDA_ALLOC_CONF`、一不小心吃光整張卡），但**不是安全邊界**。

---

## 4. 測試環境

### 4.1 拓撲

實驗條件：**3 個節點組成低延遲群組 + 1 個高延遲遠端節點**，全部透過加密 overlay 網路互連（flannel VXLAN 走 overlay 介面）。下圖是示意，不代表實際的站點或網路配置。

```
   ┌──────────────────────── 低延遲群組（3 個節點）────────────────────────┐
   │  Node-A                     Node-B                     Node-C              │
   │  k3s server（也跑工作）      k3s agent                  k3s agent           │
   │  RTX A4500 20 GB, amd64     RTX A4500 20 GB, amd64     NVIDIA GB10, arm64  │
   │                                                        （統一記憶體）       │
   └──────────────────────────────────┬────────────────────────────────────┘
                                      │ 高延遲、低頻寬
                             ┌────────┴────────┐
                             │ 遠端節點 Node-D  │
                             │ k3s agent        │
                             │ RTX 3060 12 GB   │
                             │ amd64            │
                             └─────────────────┘
```

### 4.2 軟體版本

| 項目 | 版本 / 設定 |
|---|---|
| Kubernetes | **k3s v1.35.7+k3s1**（四個節點同版），containerd 2.2.5 |
| GPU 暴露 | **NVIDIA GPU Operator v26.7.2**，`driver.enabled=false`、`toolkit.enabled=false`（主機已裝好驅動與 nvidia-container-toolkit；k3s 會自動偵測 `nvidia` runtime 並建立 RuntimeClass） |
| 排程器 | **KAI Scheduler v0.18.7** |
| 記憶體隔離 | **kai-resource-isolator Helm chart 1.1.0**（HAMi-core），`global.gpuSharingMode=HamiCore` |
| NVIDIA 驅動 | 580.173 / 580.178 / 580.196 / 595.91（各節點不同，都支援 CUDA 13.0） |
| 作業系統 | Ubuntu 22.04、24.04、26.04 混合 |
| 訓練映像 | Python 3.12 + PyTorch 2.14.1+cu130，同一個映像名稱分別建置 amd64、arm64 版 |

### 4.3 叢集設定重點

- k3s server 的 `node-ip`、`advertise-address`、`bind-address`、kubelet `address` 都設為節點的 **overlay 網路 IP**，`flannel-iface` 設為 overlay 介面，讓 API server（6443）與 kubelet（10250）只在 overlay 網路上提供服務。
- 停用 k3s 內建的 traefik 與 servicelb（不需要）。
- 設定 `egress-selector-mode: disabled`（原因見第 6 節問題 2）。
- 設定檔範例見附錄 A.1。

---

## 5. 實驗 0–7

### 實驗 0：建立四節點叢集 ✅

**目的**：確認四張異質 GPU 都被 Kubernetes 正確識別，跨節點 pod 網路與 DNS 可用。

**做法**：安裝 k3s（一台 server、三台 agent），再用 Helm 安裝 GPU Operator（不裝驅動與 toolkit），由 Node Feature Discovery + GPU Feature Discovery 自動產生 GPU 相關的節點 label。

**結果**：

```
NODE     STATUS  ROLES          VERSION        OS-IMAGE            KERNEL
Node-A   Ready   control-plane  v1.35.7+k3s1   Ubuntu 22.04.5 LTS  5.15.0-202-generic
Node-B   Ready   <none>         v1.35.7+k3s1   Ubuntu 22.04.3 LTS  5.15.0-186-generic
Node-C   Ready   <none>         v1.35.7+k3s1   Ubuntu 24.04.5 LTS  7.0.0-1019-nvidia
Node-D   Ready   <none>         v1.35.7+k3s1   Ubuntu 26.04.1 LTS  7.0.0-34-generic

NODE     ARCH    GPU_ALLOC   PRODUCT                   MEM_MiB   DRIVER       COMPUTE(major)
Node-A   amd64   1           NVIDIA-RTX-A4500          20470     580.196.07   8
Node-B   amd64   1           NVIDIA-RTX-A4500          20470     580.173.02   8
Node-C   arm64   1           NVIDIA-GB10               <none>    580.178.04   12
Node-D   amd64   1           NVIDIA-GeForce-RTX-3060   12288     595.91.07    8
```

（`PRODUCT`、`MEM_MiB` 分別來自節點 label `nvidia.com/gpu.product`、`nvidia.com/gpu.memory`。）

跨節點網路：在四個節點上各起一個 pod，都能解析 cluster DNS 並連到 Kubernetes API 的 ClusterIP:443。

**觀察**：

- 四張卡都以 `nvidia.com/gpu: 1` 出現在 allocatable，`gpu.product` label 可直接拿來指定卡型。
- **GB10 沒有 `nvidia.com/gpu.memory` label**（`MEM_MiB` 為 `<none>`）。原因是 GB10 為 CPU/GPU 統一記憶體，GPU Feature Discovery 不產生這個 label。整卡排程不受影響，但**分卡會失敗**，見實驗 5 與第 6 節問題 4。
- 資源開銷：KAI 7 個元件合計約 50m CPU / 160 MiB；GPU Operator 中最重的是 dcgm-exporter，每個節點約 390 MiB。

---

### 實驗 1：指定卡型、滿了排隊、不亂跑 ✅

**目的**：使用者指定要 A4500 或 GB10，叢集只有 2 張 A4500、1 張 GB10 時，多出來的工作要排隊，而且**不能**跑去空著的 RTX 3060。

**做法**：同時送 5 個 pod，3 個要 A4500、2 個要 GB10，每個 `sleep 150`（YAML 見附錄 A.3）：

```yaml
spec:
  schedulerName: kai-scheduler
  runtimeClassName: nvidia
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-RTX-A4500     # 或 NVIDIA-GB10
  containers:
  - name: main
    image: nvidia/cuda:12.8.1-base-ubuntu22.04
    command: ["bash","-c","nvidia-smi --query-gpu=name --format=csv,noheader; sleep 150"]
    resources:
      limits:
        nvidia.com/gpu: 1
```

**結果**（時間為相對於送出時刻 T0）：

| Pod | 節點 | 開始 | 結束 | 備註 |
|---|---|---|---|---|
| gb10-1 | Node-C | T0+5:42 | T0+8:12 | |
| a4500-1 | Node-A | T0+6:36 | T0+9:06 | |
| a4500-2 | Node-B | T0+6:41 | T0+9:11 | |
| gb10-2 | Node-C | T0+8:15 | T0+10:45 | gb10-1 結束 3 秒後才開始 |
| a4500-3 | Node-A | T0+9:09 | T0+11:39 | a4500-1 結束 3 秒後才開始 |

排隊中的 pod 收到的事件：

```
Warning  Unschedulable  kai-scheduler  no nodes with enough resources were found:
  2 node(s) didn't have enough resources: GPUs. 2 node(s) didn't match Pod's node affinity/selector.
```

**觀察**：

- 整段期間 RTX 3060 都是空的，第三個 A4500 工作並沒有被排到 3060 上，而是等 A4500 空出來。
- 前一個工作結束後約 3 秒，排隊中的工作就接上。
- 排隊原因訊息清楚（「幾個節點卡不夠、幾個節點型號不符」），可以直接顯示給使用者。
- 建立到第一個開始之間的約 6 分鐘，全部花在從外部拉 CUDA base 映像（對外頻寬不足，見第 6 節問題 1），與排程無關。

---

### 實驗 2：個人佇列與配額 ✅

**目的**：建立「團隊 → 個人」的兩層佇列，每人保證 1 張卡、可以借用閒置的卡。

**做法**：一個 parent queue `lab`（不限），三個 leaf queue `alice`、`bob`、`carol`：

```yaml
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: alice
spec:
  parentQueue: lab
  resources:
    gpu:    {quota: 1,  limit: -1, overQuotaWeight: 1}   # 保證 1 張、可無限借用、借用時平分
    cpu:    {quota: -1, limit: -1, overQuotaWeight: 1}   # CPU/記憶體不管，但一定要明寫
    memory: {quota: -1, limit: -1, overQuotaWeight: 1}
```

工作透過 pod label `kai.scheduler/queue: alice` 指定佇列。

**結果**：

```
NAME    PARENT   CHILDREN
lab              ["bob","carol","alice"]
alice   lab
bob     lab
carol   lab
```

**觀察**：Queue 本身很簡單，一個 CRD 搞定。唯一的坑是預設值：`limit` 不寫等於 0（不准借用），cpu/memory 不寫也會擋工作，所以範本全部明寫（第 6 節問題 6）。

---

### 實驗 3：借用與歸還（reclaim）✅

**目的**：驗證「一人先借光、其他人來了就歸還、而且不震盪」。

**做法**：每個工作是一個 1-GPU 的 Job（`sleep`），不指定卡型。依序：

| 時間 | 動作 | alice | bob | carol | 發生什麼 |
|---|---|---|---|---|---|
| T0 | alice 送 4 個 | 4 | – | – | 四張卡（含 RTX 3060、GB10）全部借走 |
| T0+32s | bob 送 1 個 | 3 | 1 | – | 立即 reclaim alice 的一個工作給 bob |
| T0+1:30 | carol 送 1 個 | 2 | 1 | 1 | 再 reclaim alice 一個給 carol |
| T0+2:23 | bob 再送第 2 個（超出 quota） | 2 | 1（要 2） | 1 | **不搶**，bob 的第 2 個工作 Pending |
| T0+3:15 | alice 結束 1 個工作 | 1 | 2 | 1 | 空出的卡給了 bob 的第 2 個工作 |

（每一步為什麼這樣，見 3.4 的 fair share 推算。）

**實際輸出節錄**：

```
### T0+32s bob 送 1 個 1-GPU job
NAME    ALLOC_GPU   REQ_GPU
alice   3           3
bob     1           1
carol   <none>      <none>
Normal  Evict  podgroup/pg-alice-job-4-...  Pod lab/alice-job-4-mjlv2 was preempted by workload lab/pg-bob-job-1-...

### T0+1:30 carol 送 1 個
alice   2           2
bob     1           1
carol   1           1
Normal  Evict  podgroup/pg-alice-job-3-...  Pod lab/alice-job-3-rglbm was preempted by workload lab/pg-carol-job-1-...

### T0+2:23 bob 再送第 2 個（超出 quota）
alice   2           2
bob     1           2
carol   1           1
Warning  Unschedulable  kai-scheduler  no nodes with enough resources were found: 4 node(s) didn't have enough resources: GPUs.
```

**意外發現：被踢的 Job 直接 Failed**

第一輪的 Job 設定了 `backoffLimit: 0` 加上一般常見的寫法「被搶占不算失敗」：

```yaml
spec:
  backoffLimit: 0
  podFailurePolicy:
    rules:
    - action: Ignore
      onPodConditions:
      - type: DisruptionTarget
```

結果被 reclaim 的 Job 直接變成 `Failed / BackoffLimitExceeded`：

```
alice-job-4   Failed    0/1
{"conditions":[{"reason":"BackoffLimitExceeded","type":"FailureTarget"}, {"reason":"BackoffLimitExceeded","type":"Failed"}], "failed":1, ...}
```

原因：KAI 搶占時是直接刪除 pod，**不會**在 pod 上加 `DisruptionTarget` condition，所以 `podFailurePolicy` 的 `Ignore` 規則不會生效，這次被踢就算一次失敗。解法見實驗 3b。

---

### 實驗 3b：被踢的訓練自動續跑 ✅

**目的**：讓被 reclaim 的訓練不必人工介入就能從中斷處繼續。

**做法**：

- alice 的 MNIST 訓練 Job：`backoffLimit: 5`（被踢一次只算一次失敗，Job 會建新 pod 重新排隊）；訓練程式每個 epoch 存一次 checkpoint，啟動時若有 checkpoint 就載入（程式見附錄 A.6）。
- 本測試**沒有共享儲存**，只好把 checkpoint 放在節點本機的 hostPath，並把訓練固定在 Node-B。正式使用時應該放在 NFS 等共享儲存，讓重新排程的 pod 可以跑在任何節點。
- 另外送 3 個工作占滿其他卡，然後 bob 送一個**指定 Node-B** 的工作。

**結果**：

```
### alice 訓練（Node-B），bob 尚未送
epoch 0 time 2.6s acc 98.49% maxmem 720MiB
...
epoch 5 time 2.4s acc 98.97% maxmem 720MiB
### bob 送出指定 Node-B 的工作 → alice 的訓練被 reclaim
Normal  Evict  Pod lab/alice-train-td8j2 was preempted by workload lab/pg-bob-pinned-...
Job status: {"active":1,"failed":1, ...}        ← 算一次失敗，但 Job 自動建了新 pod 排隊
### bob 結束後，新 pod 排上
RESUMED from epoch 6
epoch 7 time 2.7s acc 98.86% maxmem 739MiB
epoch 8 time 2.4s acc 99.00% maxmem 739MiB
epoch 9 time 2.4s acc 99.06% maxmem 739MiB
DONE total 31.7s
Job: failed=1, succeeded=1, Complete
```

**觀察與給使用者的規則**：

1. 訓練程式**定期存 checkpoint、啟動時自動載入**。
2. Job 的 `backoffLimit` 至少 3（被踢幾次就會用掉幾次）。
3. 被踢時有 30 秒 grace period，可以在 SIGTERM handler 裡多存一次 checkpoint；但前提是程式真的收得到 SIGTERM（第 6 節問題 9）。
4. checkpoint 要放**共享儲存**。

---

### 實驗 4：Gang scheduling（跨節點同時開始）✅

**目的**：一個要 2 張卡的工作，在只剩 1 張卡時不能「先開一半」；卡夠時兩個 pod 要同時開始。

**做法**：Job `parallelism: 2`、annotation `kai.scheduler/batch-min-member: "2"`，每個 pod 要 1 張 A4500（叢集只有兩個節點各一張，所以必定跨節點）。先放一個 bob 的「占位」工作占住 Node-B 的 A4500，**等它 Running 後**再送 gang 工作（YAML 見附錄 A.4；兩步分開送，見重現步驟）。

**結果**：

有占位工作時，Node-A 的 A4500 明明是空的，兩個 gang pod 都 Pending，PodGroup 的狀態訊息：

```
pg-gang-2xa4500-... minMember=2
  Resources were found for 1 pods while 2 are required for gang scheduling.
  Additional pods cannot be scheduled due to: no nodes with enough resources were found:
  2 node(s) didn't have enough resources: GPUs. 2 node(s) didn't match Pod's node affinity/selector.
```

刪掉占位工作後，兩個 pod 同時開始，分別在 Node-A 與 Node-B。容器第一行印出的時間：

```
20:00:34.286456281   (Node-B)
20:00:34.306086746   (Node-A)
```

兩者相差約 20 ms。

**觀察**：

- gang 在等待期間**不占卡**（Node-A 那張卡維持空閒、可給別人用），這是 gang 與「各自排、排到的先占著」最大的差別。
- 實驗 7 也觀察到同樣行為：有人用了半張 A4500 時，要 2 張 A4500 的 gang 工作會整組等待。
- 本測試**沒有**實際跑 NCCL 多機訓練。低延遲群組內的節點間可行；遠端節點延遲高、頻寬低，把它納入多機訓練不實際。

---

### 實驗 5：分卡與記憶體隔離 ✅

**目的**：兩個人各用半張卡，而且一個人不能吃掉另一個人的記憶體。

**做法**：兩個 `gpu-fraction: "0.5"` 的 pod 放在同一張 A4500（20 GB）上。測試程式每次配置 1 GiB GPU 記憶體，直到失敗或到達目標：frac-a 目標 16 GiB（故意超過半張）、frac-b 目標 4 GiB。先用預設模式測，再切換到 HamiCore 重測，最後在 GB10 上用 `gpu-memory: "8192"` 測（YAML 見附錄 A.5，程式見附錄 A.6）。

```yaml
metadata:
  annotations: {gpu-fraction: "0.5"}     # 不寫 resources.limits.nvidia.com/gpu
spec:
  schedulerName: kai-scheduler
```

**結果**：

| 模式 | 容器內看到的總記憶體 | frac-a 最多配到 | 結論 |
|---|---|---|---|
| NonMemoryEnforced（預設） | 20470 MiB（整張） | **15360 MiB**，整張卡滿了才 OOM | 兩個 pod 確實排在同一張卡，但**完全沒有隔離** |
| HamiCore + kai-resource-isolator | **10235 MiB** | **9216 MiB**，下一次即 OOM | 記憶體限制有效 |
| HamiCore，GB10，`gpu-memory: "8192"` | 8718 MiB | **8192 MiB**，下一次即 OOM | 上限有作用，但實際上限 8718 MiB 比要求的 8192 MiB 多約 6.4%（需先補節點 label，見第 6 節問題 4） |

預設模式（NonMemoryEnforced）的 frac-a：

```
memory.total [MiB]: 20470 MiB
cuda sees total 20034MiB free 15552MiB; CUDA_DEVICE_MEMORY_LIMIT=None
allocated 1024 MiB
...
allocated 15360 MiB
ALLOC FAILED at 16384 MiB: OutOfMemoryError: CUDA out of memory. Tried to allocate 1024.00 MiB.
  GPU 0 has a total capacity of 19.56 GiB of which 192.00 MiB is free.
  Process 501768 has 4.18 GiB memory in use. Process 501822 has 15.18 GiB memory in use ...
RESULT max_allocated=15360MiB
```

注意 OOM 訊息裡直接看得到**另一個 pod 的 process**，表示兩個容器其實共用整張卡、彼此可見。

HamiCore 模式的 frac-a：

```
memory.total [MiB]: 10235 MiB
[HAMI-core Msg(...libvgpu.c...)]: Initialized
cuda sees total 10235MiB free 10185MiB; CUDA_DEVICE_MEMORY_LIMIT=10235m
allocated 1024 MiB
...
allocated 9216 MiB
[HAMI-core ERROR (... allocator.c:52)]: Device 0 OOM 10789847040 / 10732175360
ALLOC FAILED at 10240 MiB: OutOfMemoryError: CUDA out of memory. Tried to allocate 1024.00 MiB.
  GPU 0 has a total capacity of 10.00 GiB of which 969.00 MiB is free.
RESULT max_allocated=9216MiB
```

此時主機上 `nvidia-smi` 看到兩個 process 分別用 4278 MiB 與 9398 MiB，加起來沒有超過整張卡。

GB10（`gpu-memory: "8192"`）：

```
memory.total [MiB], memory.used [MiB]
[N/A], [N/A]                                   ← GB10 統一記憶體，nvidia-smi 不回報 GPU 記憶體
cuda sees total 8718MiB free 8548MiB; CUDA_DEVICE_MEMORY_LIMIT=8718m
allocated 1024 MiB
...
allocated 8192 MiB
[HAMI-core ERROR (... allocator.c:52)]: Device 0 OOM 9842442240 / 9141485568
RESULT max_allocated=8192MiB
```

要求 `gpu-memory: "8192"`，實際的 `CUDA_DEVICE_MEMORY_LIMIT` 卻是 `8718m`，多了約 6.4%。結論只能限縮為：**記憶體上限確實有被強制，但實際上限比要求高約 6.4%**；這個差距可能來自 MiB ↔ fraction 的換算或取整（GB10 的 `nvidia.com/gpu.memory` 是手動補的值），本測試**沒有追查**。需要精確額度時，請自行比對設定值與容器內的 `CUDA_DEVICE_MEMORY_LIMIT`。

**觀察**：

- **預設模式只適合互相信任、自己會控制記憶體用量的情境**；要讓多人安全共用一張卡，一定要開 HamiCore。
- HamiCore 只限記憶體、不限算力；機制是 LD_PRELOAD，是防誤用而不是安全邊界（見 3.6）。
- 切換模式很簡單：`helm upgrade ... --version v0.18.7 --reuse-values --set global.gpuSharingMode=HamiCore`，再安裝 kai-resource-isolator，整個過程不到 5 分鐘（不含拉映像時間）。
- 分卡會產生 `kai-resource-reservation` namespace 裡的預留 pod，Kubernetes 會把那張卡算成「已用 1」，監控時要排除（附錄的 `gpu-status` 已處理）。

---

### 實驗 6：在三種 GPU 上跑真的訓練 ✅

**目的**：確認異質硬體（含 arm64 的 GB10）能用同一套流程跑真的 PyTorch 訓練，而且 GPU 真的被用到。

**做法**：

- 訓練程式：MNIST、小型 CNN（2 層 conv + 2 層 fc）、batch 256、5 個 epoch（程式見附錄 A.6）。
- 映像：同一個映像名稱（文中以 `example/torch:cu130` 表示），PyTorch 2.14.1+cu130，amd64 與 arm64 **各自建置**後匯入對應節點。
- 用 `nodeSelector: nvidia.com/gpu.product` 指定卡型送 Job。

**結果**：

| GPU | 節點 | 架構 | Compute capability | 每 epoch | 5 epoch 總時間 | 峰值記憶體 | 測試準確率 |
|---|---|---|---|---|---|---|---|
| RTX A4500 | Node-A | x86_64 | 8.6 | 2.4 s | **12.4 s** | 720 MiB | 98.96% |
| RTX 3060 | Node-D | x86_64 | 8.6 | 4.0 s | **20.3 s** | 720 MiB | 98.96% |
| GB10 | Node-C | aarch64 | 12.1 | 3.8 s | **19.7 s** | 769 MiB | 98.83% |

各卡的完整輸出：

```
--- RTX A4500
host train-a4500-vvvfj arch x86_64 torch 2.14.1+cu130 gpu NVIDIA RTX A4500 cap (8, 6)
epoch 0 time 2.8s acc 98.67% maxmem 720MiB
epoch 1 time 2.4s acc 98.72% maxmem 720MiB
epoch 2 time 2.4s acc 98.90% maxmem 720MiB
epoch 3 time 2.4s acc 98.87% maxmem 720MiB
epoch 4 time 2.4s acc 98.96% maxmem 720MiB
DONE total 12.4s

--- RTX 3060
host train-3060-vxzvk arch x86_64 torch 2.14.1+cu130 gpu NVIDIA GeForce RTX 3060 cap (8, 6)
epoch 0 time 4.2s acc 98.54% maxmem 720MiB
epoch 1 time 4.0s acc 98.86% maxmem 720MiB
epoch 2 time 4.0s acc 98.98% maxmem 720MiB
epoch 3 time 4.0s acc 99.07% maxmem 720MiB
epoch 4 time 4.0s acc 98.96% maxmem 720MiB
DONE total 20.3s

--- GB10
host train-gb10-pq7ml arch aarch64 torch 2.14.1+cu130 gpu NVIDIA GB10 cap (12, 1)
epoch 0 time 4.3s acc 98.61% maxmem 769MiB
epoch 1 time 3.8s acc 98.86% maxmem 769MiB
epoch 2 time 3.8s acc 98.90% maxmem 769MiB
epoch 3 time 3.8s acc 98.84% maxmem 769MiB
epoch 4 time 3.9s acc 98.83% maxmem 769MiB
DONE total 19.7s
```

A4500 訓練進行中，在主機上 `nvidia-smi` 看得到容器內的 python process 使用 1780 MiB、GPU 使用率 15%；另一張閒置的 A4500 為 0%。

**觀察**：

- 三種卡（含 arm64、compute capability 12.1 的 GB10）都可以用**同一個映像名稱、同一份 Job 範本**跑，只差 `nodeSelector`。
- 這個模型很小，瓶頸在 dataloader 而不是 GPU（使用率只有 15%），**這組數字只用來確認 GPU 真的被用到，不應視為效能 benchmark**。在這個負載下 GB10 與 RTX 3060 相近、A4500 約快 1.6 倍。
- GB10 的峰值記憶體略高（769 vs 720 MiB），推測與 arm64 版本的 kernel/allocator 差異有關，未深入追查。
- PyTorch 官方的 `pytorch/pytorch` 映像只有 amd64，arm64 必須自建（第 6 節問題 7）。

---

### 實驗 7：給使用者的簡化介面 ✅

**目的**：使用者不必學 Kubernetes YAML，也能送工作、看排隊狀況。

**做法**：寫了兩支小 shell 工具（用法見附錄 B）：

- `gpu-submit`：把「卡型、卡數、分卡比例、映像、指令」轉成 KAI 用的 Job 並送出。
- `gpu-status`：顯示每人佇列的 quota / 使用中 / 要求中、所有工作的狀態與節點、排隊中工作的原因、每個節點的 GPU 使用量。

```bash
gpu-submit -t a4500 -- python /app/train.py              # 一張 A4500；佇列預設 = 登入帳號
gpu-submit -f 0.5 -t a4500 -- python /app/alloc.py       # 半張（HamiCore 限 10 GB）
gpu-submit -g 2 -t a4500 -- python /app/train.py         # gang：2 個 pod 一起開始
gpu-submit -t gb10 -- python /app/train.py               # 指定 GB10
```

**結果**：同時以三個使用者身分送出單卡訓練、半張卡工作、2 卡 gang 工作與 GB10 工作，`gpu-status` 的輸出：

```
== 佇列（quota=保證、ALLOC=正在用、REQ=要求中）
QUEUE   PARENT   GPU_QUOTA   GPU_LIMIT   ALLOC    REQ
alice   lab      1           -1          <none>   2
bob     lab      1           -1          500m     <none>
carol   lab      1           -1          <none>   <none>
lab     <none>   -1          -1          500m     2

== 工作（lab）
POD                 QUEUE   STATUS      NODE     FRACTION
alice-gang-krj5j    alice   Pending     <none>   <none>
alice-gang-vv5s4    alice   Pending     <none>   <none>
alice-gb10-rg88m    alice   Succeeded   Node-C   <none>
bob-half-g58c4      bob     Running     Node-A   0.5
carol-train-9hk5r   carol   Succeeded   Node-B   <none>

== 排隊原因
pod/alice-gang-krj5j: no nodes with enough resources were found: 1 node(s) didn't match Pod's node affinity/selector.
pod/alice-gang-vv5s4: no nodes with enough resources were found: 2 node(s) didn't have enough resources: GPUs.
                      2 node(s) didn't match Pod's node affinity/selector.
```

bob 的半張卡工作結束後，alice 的 gang 工作兩個 pod 同時在 Node-A、Node-B 開始：

```
POD                 QUEUE   STATUS      NODE     FRACTION
alice-gang-krj5j    alice   Running     Node-A   <none>
alice-gang-vv5s4    alice   Running     Node-B   <none>
bob-half-g58c4      bob     Succeeded   Node-A   0.5

== 節點 GPU
Node-A   NVIDIA-RTX-A4500           已用 1 / 1
Node-B   NVIDIA-RTX-A4500           已用 1 / 1
Node-C   NVIDIA-GB10                已用 0 / 1
Node-D   NVIDIA-GeForce-RTX-3060    已用 0 / 1
```

半張卡工作的容器內 `nvidia-smi` 看到 `memory.total = 10235 MiB`，確認 HamiCore 生效。

**觀察**：要正式給使用者用，還缺：

- 每人一個 namespace + RBAC、kubeconfig 發放流程。注意 **namespace + RBAC 擋不住別人填你的佇列**：佇列只是 pod 上的 `kai.scheduler/queue` label，RBAC 無法依 label 值授權；要限制「只能用自己的佇列」，需要 admission policy（例如 ValidatingAdmissionPolicy 或 Kyverno）檢查 namespace 與 queue label 是否對應，並涵蓋直接建立的 Pod 與 Job 等各種工作控制器。
- 共享儲存（資料集與 checkpoint）。
- 叢集內的 container registry mirror（第 6 節問題 1）。

---

## 6. 遇到的問題與解法

| # | 現象 | 原因 | 解法 / 建議 |
|---|---|---|---|
| 1 | 拉映像、`pip install torch` 極慢（小映像要拉好幾分鐘；裝 torch 一小時沒完成） | 部分節點對外頻寬有限 | 權宜：用本機已有的 wheel cache 離線組映像，再透過節點間的高速網路把映像 tar 傳到其他節點匯入（`ctr images import`）。**正式使用請在叢集內架 registry mirror / pull-through cache** |
| 2 | kubelet 綁在 overlay 網路 IP 後，`kubectl logs` / `kubectl exec` 對 agent 節點回 `EOF`（`Get "https://<node-ip>:10250/containerLogs/...": EOF`） | k3s 預設由 API server 透過 agent tunnel 連到 agent 本機的 `localhost:10250`，但 kubelet 已改為只聽 overlay IP | server 設定 `egress-selector-mode: disabled`，讓 API server 直接連各節點的 `<overlay-ip>:10250`（節點間防火牆需允許） |
| 3 | 遠端節點與其他節點之間延遲高、頻寬低 | 網路條件限制 | 控制面不受影響（排程、logs、exec 都正常）；但搬大檔、多機訓練不可行。高延遲的遠端節點只適合單卡工作 |
| 4 | GB10 上的分卡 pod 一直 Pending，GPU 預留 pod 不斷重建；binder log：`plugin gpusharing failed in PreBind: failed to add NvFractions annotation: node does not include nvidia.com/gpu.memory label` | GB10 為統一記憶體，GPU Feature Discovery 不產生 `nvidia.com/gpu.memory` label，而 KAI 分卡需要它來換算 fraction ↔ MiB | 手動補 label：`kubectl label node <gb10-node> nvidia.com/gpu.memory=124544`（數值取 `/proc/meminfo` 的 MemTotal 換算 MiB）。正式使用應寫成 NFD 規則或節點初始化設定，避免節點重建後遺失 |
| 5 | Job 設了 `podFailurePolicy: Ignore on DisruptionTarget`，被 KAI reclaim 仍直接 `Failed / BackoffLimitExceeded` | KAI 搶占是直接刪 pod，不會加 `DisruptionTarget` condition | `backoffLimit` ≥ 3，加上程式自己存 checkpoint（實驗 3b） |
| 6 | 建了 Queue 但工作永遠不會超出 quota，或因 CPU/記憶體被擋 | Queue `limit` 沒寫等於 0；cpu/memory 沒寫也會擋 | 範本中 gpu/cpu/memory 的 `quota`、`limit`、`overQuotaWeight` 全部明寫（不管的寫 `-1`） |
| 7 | arm64（GB10）節點拉不到 `pytorch/pytorch` | 官方 `pytorch/pytorch` 映像只提供 amd64 | 自建（同一 tag 分別建 amd64/arm64，或做成 multi-arch manifest），或改用 NGC `nvcr.io/nvidia/pytorch`（多架構，但映像 > 10 GB） |
| 8 | 被搶占時要等滿 30 秒 grace period 才結束 | 用 `bash -c "...; sleep ..."` 當容器的 PID 1，bash 不會把 SIGTERM 轉給子程序，也不會自己結束 | 用 `exec` 讓訓練程式成為 PID 1，或在程式裡處理 SIGTERM（順便存最後一次 checkpoint） |
| 9 | 自己寫的監控顯示「卡已滿」，但其實只用了半張 | 分卡時 KAI 在 `kai-resource-reservation` namespace 建立預留 pod 占住整張卡 | 統計時排除該 namespace 的 pod，改用分卡 pod 的 `gpu-fraction` annotation 計算 |
| 10 | GB10 容器內 `nvidia-smi --query-gpu=memory.total,memory.used` 回傳 `[N/A]` | 統一記憶體架構不回報獨立的 GPU 記憶體 | 不影響運作；要看額度請用 `torch.cuda.mem_get_info()` 或 `CUDA_DEVICE_MEMORY_LIMIT` |

另外一點通用提醒：**一張 GPU 只應該交給一個排程者管理**。若同一台機器上還有其他容器環境或其他叢集也能直接使用同一張卡，KAI 並不知道那些用量，可能造成實際記憶體不足。

---

## 7. 與 Volcano + Kueue + HAMi 的比較

近期社群常見的另一種 k8s GPU 共用做法，是組合 Volcano（批次排程、gang）、Kueue（佇列與配額）與 HAMi（GPU 虛擬化，搭配 DRA）。下表右欄**未在本次實測**，依各專案公開的設計整理。

| 面向 | KAI Scheduler v0.18.7（本次實測） | Volcano + Kueue + HAMi（DRA） |
|---|---|---|
| 元件數 | 1 個 Helm chart（operator 管理 scheduler / binder / admission / pod-grouper / queue controller）；要記憶體隔離再加 kai-resource-isolator | 三套各自的 scheduler / controller / webhook，再加 GPU Operator 的 DRA driver 與 HAMi 的 DRA driver |
| 佇列與配額 | 階層式 Queue（quota / limit / overQuotaWeight / priority），一個 CRD | Kueue 的 ClusterQueue / LocalQueue / Cohort / ResourceFlavor；Volcano 也有自己的 Queue，兩者要決定分工 |
| 借用與歸還 | 內建；實測自動 reclaim、收斂且不震盪 | Kueue cohort borrowing + preemption 可以做到，但需要把兩套串好 |
| Gang | Job annotation `batch-min-member`；也支援 PyTorchJob、JobSet 等。資源不夠整組時**全部不開始、不占卡**（all-or-nothing admission） | Volcano PodGroup 是同類的 all-or-nothing。Kueue `waitForPodsReady` **不等價**：工作被 admit 後部分 pod 可以先啟動，逾時仍未全部 Ready 才撤銷 admission、重新排隊 |
| 分卡 | `gpu-fraction` / `gpu-memory` annotation；HamiCore 只限記憶體 | HAMi 原生 vGPU：記憶體與算力（core %）都能限制 |
| 選卡 | `nodeSelector` / affinity；GB10 需補 label | DRA DeviceClass + CEL 條件，彈性大，但需要較新的 k8s（1.34+）與相關 feature gate |
| 推理服務 | 非重點 | 常與 LWS、AI Gateway、llm-d、vLLM 等推理堆疊一起介紹 |
| 對小團隊 | 若一定要走 k8s，**明顯比較簡單** | 元件多、組合複雜，對數人規模過重；適合要同時做推理平台的團隊 |

**一句話**：KAI 用一個排程器換掉三套元件，訓練用的「佇列 + 借用 + gang + 分卡」都能用；HAMi 的強項是算力也能切，DRA 的強項是選卡條件更細，這兩點是 KAI 目前比較弱的地方。

---

## 8. 對小規模團隊的建議

規模假設：數名使用者、數張型號不一的 GPU，部分節點之間可能是高延遲網路。

| 選項 | 優點 | 缺點 | 適合度 |
|---|---|---|---|
| **A. 輕量排隊工具**（每台機器用 `task-spooler`，或一支檢查 `nvidia-smi` + `flock` 的小腳本，再加一份共用的使用公約與看板） | 幾乎零維運；不需要容器，使用者照舊用 conda / uv；當週就能上線 | 沒有跨機器的公平分配與搶占，靠自律；全體狀態要另外做小 dashboard | ★★★★ 立即可用 |
| **B. Slurm**（一個 slurmctld、每台 slurmd，GRES 依卡型分 `gpu:a4500` 等，fairshare + QOS，`PreemptMode=REQUEUE`） | HPC 標準，多數 HPC 中心都用 Slurm，使用者轉移成本低；`sbatch --gres=gpu:a4500:1`、`squeue` 直覺；fairshare、配額、搶占、多節點工作都有；不需要容器 | 需要 munge、各機 UID 一致，最好有共享檔案系統；x86 與 arm64 要分 partition；遠端節點要開對應的連線；分卡只能用 MPS / shard，記憶體隔離不如 HAMi | ★★★★ 中期最平衡 |
| **C. k3s + KAI（本次測試）** | 功能最完整：佇列 + 借用 + 搶占 + gang + 分卡（含記憶體隔離）；容器化環境可重現 | 使用者要學容器與 YAML；需要 registry、共享儲存、RBAC、憑證發放；Kubernetes 本身的升級與除錯成本；對外頻寬不足時拉映像很痛 | ★★ 適合要長期經營平台、或 GPU 數量明顯增加時 |
| **D. Volcano + Kueue + HAMi** | 訓練 + 推理平台全家桶 | 元件最多、整合成本最高 | ★ 小團隊不建議 |

**建議路線**：**A（現在）→ B（需要公平分配、搶占時）**。本次 KAI 測試的設定可以作為將來 GPU 變多、要容器化時的起點；若一開始就確定要走 k8s，KAI 比 Volcano + Kueue + HAMi 簡單很多。

如果決定採用 C（k3s + KAI），上線前的檢查清單：

1. 叢集內 registry mirror（或 pull-through cache），並預先建好 amd64 / arm64 的基礎訓練映像。
2. 共享儲存（NFS 等），放資料集與 checkpoint。
3. 每位使用者一個 namespace + RBAC、kubeconfig 發放流程；再加 admission policy（ValidatingAdmissionPolicy 或 Kyverno）檢查 namespace 與 `kai.scheduler/queue` label 是否對應。單靠 RBAC 無法限制使用者填別人的佇列，因為佇列只是 pod label。
4. Queue 範本把 gpu / cpu / memory 的 quota、limit、overQuotaWeight 全部明寫。
5. 一開始就啟用 HamiCore（kai-resource-isolator），不要用預設的不隔離模式讓多人共卡。
6. GB10 等統一記憶體節點補上 `nvidia.com/gpu.memory` label，並寫進節點初始化設定。
7. 給使用者的規則：程式要存 checkpoint、Job `backoffLimit` ≥ 3、訓練程式要能收 SIGTERM。
8. 高延遲的遠端節點只放單卡工作。

---

## 9. 附錄

### A. YAML 範例

以下範例已去識別化：`<overlay-ip>`、`<overlay-iface>`、`<gb10-node>` 等請換成實際值；映像名稱 `example/torch:cu130` 代表自建的 PyTorch 映像。

#### A.1 k3s server 設定（`/etc/rancher/k3s/config.yaml`）

```yaml
node-ip: <overlay-ip>
advertise-address: <overlay-ip>
bind-address: <overlay-ip>
flannel-iface: <overlay-iface>
kubelet-arg:
  - "address=<overlay-ip>"
disable:
  - traefik
  - servicelb
egress-selector-mode: disabled   # kubelet 只聽 overlay IP 時，避免 logs/exec 回 EOF
```

#### A.2 安裝 GPU Operator 與 KAI（示意）

```bash
# GPU Operator：主機已裝驅動與 nvidia-container-toolkit
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace \
  --version v26.7.2 --set driver.enabled=false --set toolkit.enabled=false

# KAI Scheduler
helm upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  -n kai-scheduler --create-namespace --version v0.18.7

# 改用 HamiCore 記憶體隔離，再安裝 kai-resource-isolator（HAMi-core）
# --reuse-values 不會鎖住 chart 版本，所以 upgrade 也要明確指定 --version
helm upgrade kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  -n kai-scheduler --version v0.18.7 --reuse-values --set global.gpuSharingMode=HamiCore
helm install kai-resource-isolator oci://docker.io/projecthami/kai-resource-isolator \
  -n kai-resource-isolator --create-namespace --version 1.1.0-chart

# 統一記憶體節點（GB10）補 label，數值為 MemTotal 換算的 MiB
kubectl label node <gb10-node> nvidia.com/gpu.memory=124544
```

#### A.3 佇列與「指定卡型」的 Pod

```yaml
# 團隊 parent queue
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: lab
spec:
  displayName: "team"
  resources:
    gpu:    {quota: -1, limit: -1, overQuotaWeight: 1}
    cpu:    {quota: -1, limit: -1, overQuotaWeight: 1}
    memory: {quota: -1, limit: -1, overQuotaWeight: 1}
---
# 個人 leaf queue：保證 1 張、可借用、借用時平分
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: alice
spec:
  parentQueue: lab
  resources:
    gpu:    {quota: 1,  limit: -1, overQuotaWeight: 1}
    cpu:    {quota: -1, limit: -1, overQuotaWeight: 1}
    memory: {quota: -1, limit: -1, overQuotaWeight: 1}
---
# 指定卡型的 Pod
apiVersion: v1
kind: Pod
metadata:
  name: a4500-1
  namespace: lab
  labels:
    kai.scheduler/queue: alice
spec:
  schedulerName: kai-scheduler
  runtimeClassName: nvidia
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-RTX-A4500   # NVIDIA-GB10 / NVIDIA-GeForce-RTX-3060
  containers:
  - name: main
    image: nvidia/cuda:12.8.1-base-ubuntu22.04
    command: ["bash","-c","nvidia-smi --query-gpu=name --format=csv,noheader; sleep 150"]
    resources:
      limits:
        nvidia.com/gpu: 1
```

#### A.4 可被搶占後續跑的訓練 Job、gang Job

```yaml
# 可續跑的訓練：backoffLimit > 0 + checkpoint
# 注意：KAI 搶占不會加 DisruptionTarget，podFailurePolicy Ignore 無效，所以靠 backoffLimit
apiVersion: batch/v1
kind: Job
metadata: {name: alice-train, namespace: lab}
spec:
  backoffLimit: 5
  template:
    metadata: {labels: {kai.scheduler/queue: alice}}
    spec:
      schedulerName: kai-scheduler
      runtimeClassName: nvidia
      restartPolicy: Never
      containers:
      - name: train
        image: example/torch:cu130
        command: ["python","/app/train.py"]
        env:
        - {name: EPOCHS, value: "10"}
        - {name: CKPT_DIR, value: /ckpt/alice-train}
        resources: {limits: {nvidia.com/gpu: 1}}
        volumeMounts: [{name: ckpt, mountPath: /ckpt}]
      volumes:
      # 本測試因無共享儲存而用 hostPath 並固定節點；正式環境請改用共享儲存的 PVC
      - {name: ckpt, persistentVolumeClaim: {claimName: ckpt-shared}}
---
# Gang：2 個 pod 各 1 張 A4500，要嘛一起開始、要嘛都不開始
# 重現時先送 04-blocker.yaml 並等它 Running，再送這個 Job（見重現步驟）
apiVersion: batch/v1
kind: Job
metadata:
  name: gang-2xa4500
  namespace: lab
  annotations:
    kai.scheduler/batch-min-member: "2"
spec:
  parallelism: 2
  completions: 2
  backoffLimit: 0
  template:
    metadata:
      labels: {kai.scheduler/queue: alice}
    spec:
      schedulerName: kai-scheduler
      runtimeClassName: nvidia
      restartPolicy: Never
      nodeSelector: {nvidia.com/gpu.product: NVIDIA-RTX-A4500}
      containers:
      - name: main
        image: nvidia/cuda:12.8.1-base-ubuntu22.04
        command: ["bash","-c","date +%T.%N; hostname; nvidia-smi --query-gpu=name --format=csv,noheader; sleep 60"]
        resources:
          limits: {nvidia.com/gpu: 1}
```

#### A.5 分卡 Pod

```yaml
# 半張卡（依比例）
apiVersion: v1
kind: Pod
metadata:
  name: frac-a
  namespace: lab
  labels: {kai.scheduler/queue: bob}
  annotations: {gpu-fraction: "0.5"}
spec:
  schedulerName: kai-scheduler
  restartPolicy: Never
  containers:
  - name: main
    image: example/torch:cu130
    command: ["bash","-c","nvidia-smi --query-gpu=memory.total,memory.used --format=csv; python /app/alloc.py"]
    env: [{name: TARGET_MIB, value: "16384"}, {name: STEP_MIB, value: "1024"}, {name: HOLD_S, value: "90"}]
    # 注意：分卡 pod 不寫 resources.limits.nvidia.com/gpu
---
# 指定記憶體量（GB10 需先補 nvidia.com/gpu.memory label）
apiVersion: v1
kind: Pod
metadata:
  name: frac-gb10
  namespace: lab
  labels: {kai.scheduler/queue: bob}
  annotations: {gpu-memory: "8192"}
spec:
  schedulerName: kai-scheduler
  restartPolicy: Never
  nodeSelector: {nvidia.com/gpu.product: NVIDIA-GB10}
  containers:
  - name: main
    image: example/torch:cu130
    command: ["python","/app/alloc.py"]
    env: [{name: TARGET_MIB, value: "16384"}, {name: STEP_MIB, value: "1024"}, {name: HOLD_S, value: "90"}]
```

#### A.6 測試程式

`train.py`（MNIST 小 CNN，支援 checkpoint 續跑；節錄重點）：

```python
EPOCHS = int(os.environ.get("EPOCHS", "3"))
CKPT_DIR = os.environ.get("CKPT_DIR")
...
ck = os.path.join(CKPT_DIR, "ckpt.pt") if CKPT_DIR else None
if ck and os.path.exists(ck):                         # 啟動時有 checkpoint 就載入
    s = torch.load(ck); m.load_state_dict(s["model"]); opt.load_state_dict(s["opt"]); start = s["epoch"] + 1
    print(f"RESUMED from epoch {s['epoch']}", flush=True)
for ep in range(start, EPOCHS):
    ...                                               # 訓練一個 epoch、測試準確率
    if ck:                                            # 每個 epoch 存一次
        os.makedirs(CKPT_DIR, exist_ok=True)
        torch.save({"model": m.state_dict(), "opt": opt.state_dict(), "epoch": ep}, ck)
```

`alloc.py`（逐步配置 GPU 記憶體，用來測分卡隔離）：

```python
step = int(os.environ.get("STEP_MIB", "1024")); target = int(os.environ.get("TARGET_MIB", "16000"))
free, total = torch.cuda.mem_get_info()
print(f"cuda sees total {total/2**20:.0f}MiB free {free/2**20:.0f}MiB; "
      f"CUDA_DEVICE_MEMORY_LIMIT={os.environ.get('CUDA_DEVICE_MEMORY_LIMIT')}", flush=True)
bufs = []; got = 0
try:
    while got < target:
        bufs.append(torch.empty(step * 2**20, dtype=torch.uint8, device="cuda")); got += step
        print(f"allocated {got} MiB", flush=True)
except Exception as e:
    print(f"ALLOC FAILED at {got + step} MiB: {type(e).__name__}: ...", flush=True)
print(f"RESULT max_allocated={got}MiB", flush=True)
```

映像（amd64 / arm64 各建一次，同一個 tag；完整檔案見 `image/Dockerfile`）。測試時只記錄了 torch 版本（2.14.1+cu130），torchvision 鎖在對應 torch 2.14 的 0.29.1；base image 建議再以 digest 鎖定：

```dockerfile
FROM python:3.12-slim          # 建議改成 python:3.12-slim@sha256:<digest>
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1
RUN pip install torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cu130
RUN python -c "import torchvision as tv; tv.datasets.MNIST('/data', download=True); tv.datasets.MNIST('/data', train=False, download=True)"
COPY train.py alloc.py /app/
WORKDIR /app
```

### B. 使用者工具：gpu-submit / gpu-status

兩支都是包一層 `kubectl` 的 bash 腳本，放在使用者登入後可存取 kubeconfig 的機器上、加入 `PATH` 即可。

#### B.1 gpu-submit

```
gpu-submit [-q 佇列] [-g GPU數] [-t a4500|gb10|3060|any] [-f 比例] [-i 映像] [-n 名稱] [-w 工作目錄（hostPath）] [--dry-run] -- 指令...
```

| 參數 | 意義 | 預設 |
|---|---|---|
| `-q` | 佇列 | 環境變數 `GPU_QUEUE`，否則為登入帳號 |
| `-g` | GPU 數；> 1 時自動變成 gang（`parallelism` = `batch-min-member` = N，每個 pod 1 張） | 1 |
| `-t` | 卡型，對應到 `nvidia.com/gpu.product` 的 `nodeSelector`；`any` 不限 | any |
| `-f` | 分卡比例（例如 `0.5`），會改用 `gpu-fraction` annotation | 不分卡 |
| `-i` | 映像 | 團隊預設的 PyTorch 映像 |
| `-n` | Job 名稱 | `<佇列>-<月日-時分秒>-<6 位隨機十六進位>`（同一秒送多個也不撞名） |
| `-w` | 掛到容器 `/work` 的工作目錄 | 無 |
| `--dry-run` | 只印出產生的 YAML，不送出 | |

送出用 `kubectl create`，同名 Job 已存在時會直接報錯，不會被 `apply` 靜默合併。指令參數以 argv 原樣序列化成 JSON，含換行的參數（例如 `bash -c` 的多行腳本）會保持為單一參數。

範例：

```bash
gpu-submit -t a4500 -- python /app/train.py                    # 一張 A4500
gpu-submit -f 0.5 -t a4500 -- python /app/alloc.py             # 半張（HamiCore 會限制記憶體）
gpu-submit -g 2 -t a4500 -- python /app/train.py               # 2 個 pod 各 1 卡、gang 一起開始
gpu-submit -t any -i myimage:tag -- bash -c "nvidia-smi; python x.py"
gpu-submit -t any -- bash -c 'nvidia-smi
python x.py'                # 多行腳本也是一個參數
gpu-submit -t gb10 --dry-run -- python /app/train.py           # 先看 YAML
```

產生的 Job 骨架（重點欄位）：

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: <名稱>
  namespace: lab
  labels: {gpu-submit: "true", owner: "<佇列>"}
  annotations: {kai.scheduler/batch-min-member: "<N>"}   # 只有 -g > 1 時
spec:
  parallelism: <N>
  completions: <N>
  backoffLimit: 5                  # 被 reclaim 會算一次失敗；程式要自己存 checkpoint 才能續跑
  ttlSecondsAfterFinished: 86400   # 結束一天後自動清掉
  template:
    metadata:
      labels: {kai.scheduler/queue: "<佇列>"}
      annotations: {gpu-fraction: "<比例>"}               # 只有 -f 時
    spec:
      schedulerName: kai-scheduler
      runtimeClassName: nvidia
      restartPolicy: Never
      nodeSelector: {nvidia.com/gpu.product: <卡型>}      # -t any 時為空
      containers:
      - name: main
        image: <映像>
        command: [<指令>]
        resources: {limits: {nvidia.com/gpu: 1}}         # 分卡時不寫
```

送出後會提示：看狀態用 `gpu-status`、看輸出用 `kubectl -n lab logs -f job/<名稱>`、取消用 `kubectl -n lab delete job <名稱>`。

#### B.2 gpu-status

不需要參數（namespace 可用環境變數 `GPU_NS` 指定），依序輸出四段：

1. **佇列**：每個 queue 的 parent、GPU quota、limit、目前分配量（ALLOC，分卡時以 `500m` 表示半張）、要求量（REQ）。
2. **工作**：namespace 內所有 pod 的佇列、狀態、所在節點、分卡比例。
3. **排隊原因**：每個 Pending pod 最近一次 `Unschedulable` 事件的訊息。
4. **節點 GPU**：每個節點的卡型與「已用 / 可用」，已排除 `kai-resource-reservation` 的預留 pod，分卡以小數計。

輸出範例見實驗 7。
