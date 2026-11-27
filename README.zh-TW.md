# Firn

[English](./README.md)

**Firn** 是一套開源、輕量級的 macOS Docker Linux VM 執行環境，以 Swift 與 Go 原生建構於 Apple `Virtualization.framework`（`VZVirtualMachine`）、`virtio-vsock`、`virtiofs` 與 Rosetta（`x86_64`）之上。

它致力於以極低閒置資源取代龐大的桌面容器 Helper：不到 2 秒冷啟動、閒置僅 ~0.5% CPU、接近 1 GiB/s 的 vsock TCP 轉發吞吐、**不畏 macOS `vmenet` 數量耗盡與企業 VPN 的 vsock L3/L4 使用者態網路**、**cgroup v2 閒置冷凍與 zram 分層記憶體回收**、**17 ms 目標優先 Auto-Thaw**、**`https://*.firn.local`** 本機 HTTPS 代理、互動式 **`firn shell`** 與原生 **選單列監控 App（`Firn.app`）**。

## 為什麼選擇 Firn？

- **近乎零待機功耗**：以 Docker `/events` 長輪詢事件驅動，無容器待機時 `firnd` 維持 **0.0% CPU**、VM 僅 **~0.5% CPU**。
- **同時保留 10+ worktree 環境不吃光記憶體**：閒置 Compose 專案透過 `cgroup.freeze` 暫停並將冷頁壓縮回收到記憶體 `zram` 與 swapfile（容器 RAM 縮減約 **98%**）；一旦本機流量打進連接埠或 `*.firn.local`，目標容器毫秒級自動解凍接手連線。
- **容器出網不受 `vmenet*` 上限與 VPN 影響**：除了 `vmnet` 外，`firn-guestd` 透過 `firn0` TUN + gVisor 使用者態網路堆疊走 `AF_VSOCK` 直接由 macOS 主機出網與解析 DNS，天然吃系統路由、企業代理與 split-DNS VPN。
- **高吞吐迴環連線與雙棧支援**：256 KiB 非阻塞 `poll()` 轉發搭配 1 MiB socket buffer 與 `127.0.0.1` + `[::1]` 雙棧監聽，避開 IPv6 fallback 延遲。
- **開箱即用的本機 HTTPS 與 SSH Agent 轉發**：內建主機 Root CA 與 `Network.framework` TLS 反向代理（`:8443`），並自動轉發 macOS `SSH_AUTH_SOCK` 至 `firn shell` 與容器建置流程。

## 實測數據（v0.3.0，同台 Apple Silicon Mac）

在同台 Apple Silicon 工作站執行完整 6 容器本地開發環境（`PostgreSQL 18`、`Valkey/Redis`、`Qdrant`、`SpiceDB`、`SeaweedFS`、`Mailpit`）的實測對照：

| 指標 | Firn v0.3.0 | 商業桌面容器方案（同機實測） |
| --- | --- | --- |
| Guest 冷啟動就緒（`[firn-init] ready`） | **`1.73s`**（首次建盤 `1.17s`） | — |
| 閒置宿主 CPU 佔用（0 容器待機） | **`0.5%`**（`firnd 0.0%` + VM `0.5%`） | **`96.5%`**（9 專案 / 62 容器） |
| 宿主記憶體 RSS | **`~503–994 MiB`**（VM + daemon） | **`4,194.8 MiB`**（僅 Helper） |
| `docker run --rm --entrypoint true postgres:18-alpine`（3 次中位數） | **`370.3 ms`** | `657.1 ms` |
| VirtioFS 走訪 240 個原始碼檔案（3 次中位數） | **`357.9 ms`** | `626.0 ms` |
| PostgreSQL `200x SELECT 1` TCP 平均延遲 | **`0.141 ms`**（`p50 0.134 ms`） | `0.182 ms` |
| PostgreSQL `19.25 MiB` 批次查詢吞吐（中位數） | **`896.4 MiB/s`**（`21.5 ms`） | `164.6 MiB/s`（`118.6 ms`） |
| 專案冷凍＋記憶體回收（`firn freeze --reclaim`） | `602.8 MB → 11.3 MB`（**釋放 98.1%**） | — |
| 目標優先 Auto-Thaw（冷凍狀態直連 Redis `PING`） | **`17.3 ms`**（解凍 RTT `24.97 ms`） | — |
| HTTPS Auto-Thaw（`https://*.firn.local:8443`） | **`0.281s`（HTTP 200）** | — |
| 容器無代理 HTTPS 出網（宿主存在 251 個 `vmenet*`） | **`HTTP/2 200`**（走 `firn0` vsock netstack） | — |

## 系統架構

```mermaid
flowchart LR
  subgraph macOS["macOS 主機"]
    CLI["firn CLI / Docker CLI"]
    Bar["Firn.app (FirnBar)"]
    subgraph Daemon["firnd (VZVirtualMachine)"]
      D["docker.sock <-> vsock:2375"]
      C["控制 API <-> vsock:2376"]
      T["AutoThawTCP / :8088 HTTP / :8443 HTTPS <-> vsock:2377"]
      DNS["分流 DNS (:53535 *.firn.local)"]
      R["轉發器: HTTP 代理 (:2378), DNS (:2379), Netstack TCP/UDP (:2380/:2381), SSH Agent (:2383)"]
      SH["shell.sock <-> vsock:2382"]
    end
  end
  subgraph Linux["Alpine Linux VM (arm64 6.12.x + Rosetta x86_64)"]
    GD["firn-guestd (Go + gVisor netstack + cgroup v2 回收器)"]
    TUN["firn0 TUN (10.89.0.2/24)"]
    DK["dockerd (overlay2 掛載於 cached APFS data.ext4)"]
    SW["分層 Swap: 2 GiB zram0 (pri 100) + 4 GiB swapfile (pri 10)"]
  end
  CLI --> D
  CLI --> SH
  Bar --> C
  D <-->|"AF_VSOCK"| GD
  C <-->|"AF_VSOCK"| GD
  T <-->|"AF_VSOCK"| GD
  R <-->|"AF_VSOCK"| GD
  SH <-->|"AF_VSOCK"| GD
  GD --> TUN
  GD --> DK
  GD --> SW
```

## 先決條件

- macOS 14+ 與支援 `Virtualization.framework` 的 Mac（建議 Apple Silicon）
- Xcode Command Line Tools（`swift`）
- Go 工具鏈（版本對齊 `guest/firn-guestd/go.mod`，用於跨編譯 `linux/arm64`）
- Docker CLI 與 Compose v2（`docker`），以及初次組裝 Alpine rootfs 映像檔所需的 builder context（`BUILD_DOCKER_CONTEXT`）

## 快速開始

```sh
# 編譯 Alpine 核心／rootfs、firn-guestd、firn CLI、firnd 與 Firn.app
make build

# 啟動 Firn VM（註冊 'firn' Docker context，不會覆寫原本的預設 context）
build/firn up

# 指定使用 Firn context
docker --context firn ps

# 或安全切換為預設 context（隨時可用 `firn context restore` 還原）
build/firn context use

# 實測容器走 vsock netstack 出網 + 進入互動式 Linux Shell
docker --context firn run --rm alpine:3.21 sh -c 'apk update && apk add curl && curl -I https://example.com'
build/firn shell
```

## CLI 指令一覽

| 指令 | 說明 |
| --- | --- |
| `firn up [--cpus N] [--memory-gib N] [--context NAME]` | 啟動 VM、同步組態並建立 Docker context |
| `firn down` | 透過 `/poweroff` 執行乾淨關機（`fstrim`、卸載與唯讀保護）並停止 `firnd` |
| `firn status [--json]` | 查看 VM／主機記憶體、APFS 稀疏磁碟空間、DNS／HTTPS 與各專案狀態 |
| `firn shell [-- COMMAND...]` | 經由 `vsock:2382` 開啟互動式 PTY Shell（內建 `SSH_AUTH_SOCK` 轉發） |
| `firn freeze <project> [--reclaim]` | 使用 `cgroup.freeze` 暫停專案並回收記憶體與釋放快取 |
| `firn thaw <project>` | 手動解凍指定專案（連線進入時也會自動解凍） |
| `firn reclaim [project]` | 回收閒置記憶體頁面而不強制暫停容器 |
| `firn balloon <shrink\|reset>` | 將 VZ Balloon 縮放至 guest 需求量或恢復上限 |
| `firn disk <usage\|trim> [--json]` | 查看 APFS 稀疏碟／`zram0` 用量，或線上執行 `fstrim` 回收空間 |
| `firn dns <status\|install\|uninstall>` | 檢視本機 DNS 紀錄或管理 `/etc/resolver/<domain>`（`sudo`） |
| `firn ca <status\|install\|uninstall>` | 檢視 Firn 本機 Root CA 或寫入 macOS System Keychain（`sudo`） |
| `firn https <status\|install\|uninstall>` | 檢視 `:8443` HTTPS 代理或安裝 `:80`/`:443` `pf` 轉向規則（`sudo`） |
| `firn context <status\|use\|restore>` | 查看、切換或還原預設 Docker context |
| `firn proxy` | 查看自動偵測到的 macOS 代理、VPN、DNS 與 `SSH_AUTH_SOCK` 狀態 |
| `firn gui` | 啟動 `build/Firn.app`（`FirnBar`）選單列監控介面 |
| `firn doctor` | 檢查虛擬化支援、Rosetta、簽章權限、CA、DNS、`pf` 與磁碟狀態 |
| `firn autostart <status\|install\|uninstall>` | 管理選用的使用者 LaunchAgent（`~/Library/LaunchAgents/dev.firn.firnd.plist`） |
| `firn bench [--project NAME] [--compare-orbstack]` | 實測冷凍回收與解凍耗時（可選並對照同機 Helper 佔用） |
| `firn logs [--serial\|--daemon]` | 查看 VM serial console 或主機 daemon 日誌 |

## 本機網域與 HTTPS（`*.firn.local`）

每個帶開放 TCP 埠的 Compose 容器皆會自動產生網域：
- `<container>.firn.local`
- `<service>.<project>.firn.local`（`mailpit` 另含 `mail.<project>.firn.local`）

1. 註冊 macOS 分流 DNS（選用）：`sudo build/firn dns install`
2. 信任本機 Root CA 啟用 `https://<service>.<project>.firn.local:8443`（選用）：
   ```sh
   sudo build/firn ca install
   ```
3. 啟用免連接埠號 `http://` 與 `https://`（透過 `pf` 將 loopback `:80`/`:443` 導向 Firn 代理，選用）：
   ```sh
   sudo build/firn https install
   ```

## Compose 標籤與系統組態

可在 `docker-compose.yml` 針對單一服務細調自動冷凍行為：

```yaml
services:
  postgres:
    image: postgres:18-alpine
    labels:
      - "firn.reaper.exempt=true"   # 永不自動冷凍此 Compose 專案

  worker:
    labels:
      - "firn.reaper.idle=300"      # 覆寫閒置秒數（設為 "0" 等同豁免）
```

全域設定儲存於 `~/.firn/config.json`（亦可從 `FirnBar` → **Settings…** 直接修改），並支援環境變數覆寫：

- `FIRN_HOME`（預設 `~/.firn`）
- `FIRN_CONTEXT`（預設 `firn`）
- `FIRN_CPUS`（預設 `8`）
- `FIRN_MEMORY_GIB`（預設 `8`）
- `FIRN_MIN_BALLOON_MIB`（預設 `768`）
- `FIRN_DOMAIN`（預設 `firn.local`）
- `FIRN_DNS_PORT`（預設 `53535`）
- `FIRN_HTTP_PROXY_PORT`（預設 `8088`）
- `FIRN_HTTPS_PROXY_PORT`（預設 `8443`）
- `FIRN_IDLE_SECONDS`（預設 `900`，`0` 代表停用全域自動冷凍）
- `FIRN_EXEMPT_PROJECTS`（逗號分隔之豁免 Compose 專案名稱，預設為空）
- `BUILD_DOCKER_CONTEXT`（`make build`／`guest/build-rootfs.sh` 建置 rootfs 所用之 Docker context）

## 參與貢獻與授權條款

請參閱 [CONTRIBUTING.md](./CONTRIBUTING.md) 與 [SECURITY.md](./SECURITY.md)。本專案採用 [Apache License 2.0](./LICENSE) 開源授權。
