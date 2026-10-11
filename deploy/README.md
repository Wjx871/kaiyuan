# 自动部署（`deploy/`）

这一目录只有四个文件，加起来不到 300 行，负责一件事：

> **同学在 GitHub 上合并 PR → 1 分钟内，服务器上的页面自动变成新的。**

活动当天不需要任何人在服务器上敲命令。

---

## 为什么这么设计

### 1. 为什么用 zip 下载，而不是 `git clone`

部署前实测过这台服务器的出网情况：

| 目标 | 结果 |
|---|---|
| `github.com` | ❌ **TCP 超时**（15 秒无响应） |
| `codeload.github.com` | ✅ HTTP 200，980 ms |
| `api.github.com` | ✅ HTTP 200，894 ms |
| `raw.githubusercontent.com` | ✅ HTTP 200，1038 ms |

`git clone` 走的是 `github.com`，在这台机器上**根本走不通**。
而 GitHub 打包好的 zip 走 `codeload.github.com`，畅通。

所以：**用 `Invoke-WebRequest` 下载 zip，再用 `Expand-Archive` 解压**，全程不碰 `git`。

### 2. 为什么是服务器「拉」而不是 GitHub Actions「推」

推送方案（`appleboy/ssh-action`）延迟更低，但要求 GitHub 能主动连上服务器的 22 端口。
这意味着：

- 每次换服务器都要改 GitHub Secrets；
- 服务器安全组必须长期对外开放 22 端口（我们这次是临时开的，活动后要关掉）。

**改成服务器主动拉取之后，服务器只需要「出网」，不需要任何入站端口。** 安全组可以关得干干净净。

### 3. 为什么每分钟轮询不会把 GitHub 限流

匿名调用 `api.github.com` 限额是 60 次/小时，每分钟一次就是 60 次/小时，正好卡线。

但脚本第一次请求时会把响应里的 `ETag` 存下来，之后每次都带上 `If-None-Match`：

- 内容没变 → GitHub 返回 `304 Not Modified`
- **GitHub 官方文档明确写了：返回 304 的请求不计入速率限制**

所以常态下每分钟一次轮询是**零成本**的，只有真的有人提交时才会消耗一次配额。

---

## 四个文件

| 文件 | 作用 |
|---|---|
| `carnival-sync.ps1` | 干活的。查更新 → 下载 zip → 解压 → 镜像到站点目录 → 自检 |
| `carnival-sync.cmd` | 计划任务的入口，`cmd.exe` 包一层调上面的 ps1 |
| `install-task.ps1` | 装。复制脚本、写配置、注册计划任务、立刻跑一次 |
| `README.md` | 你正在看的这个 |

> ⚠️ **`carnival-sync.ps1` 和 `install-task.ps1` 必须保持纯 ASCII（英文）。**
> Windows PowerShell 5.1 读取没有 UTF-8 BOM 的 `.ps1` 时，会按系统 ANSI 代码页（中文系统是 GBK）解析，
> 中文注释会变成乱码、把字符串引号吃掉，报出一堆莫名其妙的「意外的标记 `}`」。
> 这个坑我们在第一次部署时踩过，排查了半小时。**要么纯 ASCII，要么存成带 BOM 的 UTF-8。**

---

## 安装

在服务器上（管理员 PowerShell）：

```powershell
cd C:\inetpub\carnival-sync
.\install-task.ps1 -Repo "你的用户名/仓库名"
```

就这一条。它会：

1. 把 `carnival-sync.ps1` / `.cmd` 复制到 `C:\inetpub\carnival-sync\`
2. 写入 `config.json`（仓库地址、分支、站点目录）
3. 注册名为 **Carnival Sync** 的计划任务，**以 SYSTEM 身份、每 1 分钟运行一次**
4. 立刻跑一次，并把日志尾巴打出来

卸载：

```powershell
.\install-task.ps1 -Remove
```

---

## 它是怎么干活的

```
  ┌─ 每 1 分钟 ──────────────────────────────────────────────┐
  │                                                          │
  │  ① 问 GitHub：main 分支最新 commit 是哪个？              │
  │     GET api.github.com/repos/OWNER/REPO/commits/main      │
  │     带上 If-None-Match: <上次的 ETag>                     │
  │                                                          │
  │        ├─ 304 没变化 ──→ 记一行日志，退出（0.3 秒）      │
  │        └─ 200 有变化 ──→ 继续                            │
  │                                                          │
  │  ② 下载   codeload.github.com/.../zip/refs/heads/main     │
  │  ③ 解压   到 C:\inetpub\carnival-sync\tmp\stage           │
  │  ④ 检查   压缩包根目录必须有 index.html，没有就中止       │
  │  ⑤ 发布   robocopy /MIR 镜像到 C:\inetpub\wwwroot         │
  │  ⑥ 自检   请求 http://127.0.0.1/ 确认还能打开             │
  │  ⑦ 记账   把 commit sha 和新的 ETag 写进 state.json       │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
```

### 关于 `robocopy /MIR`

`/MIR` 是「镜像」：站点目录会被改成**和仓库完全一致**。
从仓库里删掉的文件，服务器上也会被删掉——这正是我们想要的，否则旧文件会永远堆在服务器上。

两个安全阀：

- 镜像前会确认压缩包里存在 `index.html`，不满足直接中止，**不会把站点清空**；
- `robocopy` 退出码 0–7 都算成功（1 表示有文件被复制，2 表示有文件被删除），**≥8 才判定为失败**。
  这个退出码约定反直觉，很多脚本在这里误判，所以我们显式处理了。

### 关于 `state.json`

```json
{
  "sha": "3f4847d...",
  "etag": "W/\"...\"",
  "repo": "owner/repo",
  "branch": "main",
  "files": 71,
  "updated_at": "2026-10-11T15:21:43Z"
}
```

它记录「上次同步到哪个 commit」。想强制重新发布一次，删掉这个文件即可（或者加 `-Force`）。

---

## 手动操作

```powershell
# 看计划任务状态和上次运行结果
Get-ScheduledTask -TaskName "Carnival Sync" | Get-ScheduledTaskInfo

# 立刻同步一次
Start-ScheduledTask -TaskName "Carnival Sync"

# 实时看日志
Get-Content C:\inetpub\carnival-sync\sync.log -Tail 30 -Wait

# 强制重新发布（忽略 ETag 缓存）
C:\inetpub\carnival-sync\carnival-sync.cmd -Force

# 换个仓库
notepad C:\inetpub\carnival-sync\config.json
```

## 退出码

| 码 | 含义 | 要不要管 |
|---|---|---|
| 0 | 已是最新，或同步成功 | 不用 |
| 1 | 同步失败（网络 / 解压 / robocopy / 自检） | **要**，看 `sync.log` 里的 `[ERROR]` |
| 2 | `config.json` 还没配好 | 跑 `install-task.ps1` |

未配置时脚本**不写日志直接退出**——计划任务每分钟触发一次，写日志会把文件刷爆。

---

## 已知限制

- **最多 1 分钟延迟。** 对摊位场景完全够用，志愿者说一句「稍等刷新看看」就行。想要秒级只能上 GitHub Actions 推送方案。
- **依赖 `api.github.com` 和 `codeload.github.com`。** 这两个域名当前可达；如果哪天被墙，脚本会在日志里报 `[ERROR]`，站点会停在最后一个成功的版本（不会变白屏）。
- **`robocopy /MIR` 不是原子操作。** 极端情况下（同步到一半断电）站点可能处于半新半旧状态。下一次运行会自动修复。要做到原子切换得用目录软链 + 停站，对校园活动来说不值得。
- **发布时排除了 `.github/`、`deploy/`、`.gitignore`、`.gitattributes`。** 这些是仓库自己的东西，没必要放到公网 Web 目录里。
