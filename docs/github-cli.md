# GitHub CLI（gh）：安装、登录与查 CI

> 本仓库的 CI 在 GitHub Actions 上跑（`.github/workflows/ci.yml`，workflow 名 `CI`）。本页说明如何用
> `gh` 取某个 run 的失败 job / step / 日志，以及 `gh` 没装、没登录、权限不够时怎么处理。
>
> 本页的查询类命令（§3.1–3.5、§3.7 的 `jobs` / `logs`）以 **gh 2.97.0**（2026-07-31）于 2026-11-17
> 对 run `43900679747` 实跑；`rerun` / `download` / `pr checks` 只按 `--help` 校对过，未实际执行。
> 只用网页也能看，但 `--log-failed` 一条命令就能把失败 step 的全文日志抓下来，比逐页点快得多。

**最短路径**（已装、已登录、仓库已配 remote）：

```bash
gh run list -w CI -L 5                                   # 找 run
gh run view <run-id> --json jobs --jq '
  .jobs[] | "\(.conclusion)\t\(.name)\t" +
  ([.steps[] | select(.conclusion=="failure") | .name] | join(", "))'
gh run view <run-id> --log-failed > /tmp/opencode/ci.log  # 失败 step 全文
```

## 0. 先判断：装没装、登没登、仓库有没有 remote

```bash
gh --version
gh auth status
```

| 现象 | 含义 | 去哪节 |
| --- | --- | --- |
| `command not found` / `'gh' 不是内部或外部命令` | 没装，或装了不在 PATH | §1 |
| `You are not logged into any GitHub hosts` | 装了没登录 | §2 |
| 列出账号、`Token scopes`、`Active account: true` | 可用 | §3 |

`gh auth status` 在未登录时退出码非 0，可以直接写进脚本做前置检查。

### 0.1 前置条件：当前仓库必须配了 remote

```bash
git remote -v
```

**约定：当前仓库没有 remote 时，不要用 `gh`。**

gh 的 `run` / `repo` / `pr` 命令默认从当前目录的 git remote 推断 `OWNER/REPO`；没有 remote 时它无法确定要查哪个仓库，
会直接报 `failed to determine base repo: no git remotes found`（2026-11-17 在空 remote 的临时仓库实测）。
不要用 `-R <owner>/<repo>` 绕过这条约定——先把 remote 补对，再跑 gh，避免结果对到错误的仓库上。

本仓库的 `origin` 自 2026-11-14 起是 `git@github.com:wangmingfa/MoonUI.git`：`git remote -v` 有输出且指向它，就可以按本页操作。
空输出（或指向别的仓库）时，先 `git remote add origin git@github.com:wangmingfa/MoonUI.git`，或者改用 GitHub 网页；
这与本仓库历史上「没有 remote、workflow 从未真跑」那段是同一类边界（`T275` 落地注）。

## 1. 安装

### macOS

```bash
brew install gh        # 官方推荐
brew upgrade gh
```

没有 Homebrew：MacPorts `sudo port install gh`，或从
[releases](https://github.com/cli/cli/releases/latest) 下 macOS 的包。

### Windows

```powershell
winget install --id GitHub.cli --source winget
winget upgrade --id GitHub.cli --source winget
```

安装器会改 PATH，**装完必须新开一个终端窗口**（只开新标签页不够）。备选：`choco install gh`、
`scoop install gh`，或 releases 里的 `.msi`。

### Linux

Debian / Ubuntu（官方源，含 keyring）：

```bash
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y
```

- Fedora / RHEL（DNF5）：`sudo dnf install dnf5-plugins && sudo dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo && sudo dnf install gh`
- Fedora / RHEL（DNF4）：`sudo dnf install 'dnf-command(config-manager)' && sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && sudo dnf install gh`
- Arch：`sudo pacman -S github-cli`
- Alpine：`apk add github-cli`
- 其它发行版 / 无包管理器：从 releases 取 tarball，解压后把 `bin/gh` 放进 PATH。

不建议 snap（上游明确不建议，运行时问题多）。发行版自带的老包（`2.45` / `2.46`）已因废弃 API 而损坏，
优先用上面的官方源。

验证：

```bash
gh --version
command -v gh        # Windows: where.exe gh
```

## 2. 登录

### 2.1 有浏览器的本机

```bash
gh auth login
```

交互选项依次是：

1. `GitHub.com`
2. `HTTPS`（这是 gh 自己走 API 的协议，与仓库 `origin` 用 ssh 无关）
3. `Login with a web browser`（或 `Paste an authentication token`）
4. 终端给一次性码（形如 `XXXX-XXXX`），回车打开浏览器，粘码、授权

### 2.2 无浏览器的机器（服务器 / 容器 / 远程）

在**能上网的终端**跑同一条命令，选 `Login with a web browser`：它会打印一次性码和
<https://github.com/login/device>。在另一台设备的浏览器里输码即可，令牌落在运行 gh 的那台机器上。

或者先建 token（见 2.3），再：

```bash
gh auth login --with-token < /path/to/token.txt
```

`--with-token` 从 stdin 读，文件里只放 token 本身。

### 2.3 需要的权限范围（scope）

| token 类型 | 需要 |
| --- | --- |
| 经典 PAT | `repo`、`read:org`、`gist`（网页登录流程默认就带这三个） |
| fine-grained PAT | `Actions: Read`（读 run / job / 日志）、`Metadata: Read`、`Contents: Read`；私有仓库还要给该仓库授权 |
| 只读公开仓库的 CI | 经典 token 勾 `public_repo`；但日志正文对匿名访问不开放，见 §5 |

补 scope：

```bash
gh auth refresh -h github.com -s repo,read:org
```

### 2.4 用环境变量（CI / 自动化）

```bash
export GH_TOKEN=ghp_xxx        # 优先
export GITHUB_TOKEN=ghp_xxx    # 备选
```

GitHub Actions 里按 `gh auth login --help` 的写法：`env: GH_TOKEN: ${{ github.token }}`。
fine-grained PAT 建议走 `GH_TOKEN`，不要用 `--with-token`（help 里明说对 fine-grained 可能行为古怪）。

### 2.5 凭据存在哪、多账号

- 默认存系统 keyring（macOS Keychain / Windows Credential Manager / Linux Secret Service）。
- 没有可用 keyring 时 gh 退回明文 `~/.config/gh/hosts.yml`（Windows 在 `%APPDATA%\GitHub CLI\hosts.yml`），
  `gh auth status` 会打印实际位置。确实要明文：`gh auth login --insecure-storage`。
- 多账号：`gh auth switch`；查看：`gh auth status`。

### 2.6 端到端自检

```bash
git remote -v                                            # 先确认有 remote，见 §0.1
gh api user --jq .login                                  # 打出登录账号
gh repo view wangmingfa/MoonUI --json nameWithOwner,visibility
gh run list -L 1                                         # 能列 run 就说明 API 通
```

私有仓库返回 404（而不是 403）通常是**账号没权限**，不是命令写错。

## 3. 查 CI

本仓库 workflow 名是 `CI`，`on.push` 跟 `main` / `master`，也支持 `workflow_dispatch`。
下面所有命令都在仓库根目录执行，且 `git remote -v` 有输出（见 §0.1）——没有 remote 时先不要用 gh。

### 3.1 找 run

```bash
gh run list -w CI -L 10
gh run list -b main -L 5
gh run list -c "$(git rev-parse HEAD)"        # 只看当前 HEAD
gh run list -s failure -L 10                  # 只看失败的
gh run list -L 20 --json databaseId,conclusion,headSha,createdAt,displayTitle \
  --jq '.[] | [.databaseId,.conclusion,.headSha[0:7],.displayTitle] | @tsv'
```

默认输出依次是状态 / 结论 / 标题 / workflow / 分支 / 事件 / run id / 耗时 / 时间
（旧版 gh 可能把前两列合成一列）。

### 3.2 看 run 里哪个 job / step 红了

```bash
gh run view <run-id>
gh run view <run-id> -v          # 带 step 列表

# 只打「失败的 job + 它红的 step」，日常最快的一条
gh run view <run-id> --json jobs --jq '
  .jobs[] | "\(.conclusion)\t\(.name)\t" +
  ([.steps[] | select(.conclusion=="failure") | .name] | join(", "))'

# 取 job 的真实 id（后面 --job / rerun --job 要用）
gh run view <run-id> --json jobs --jq '.jobs[] | {name, databaseId}'
```

`databaseId` 才是 job id。浏览器 URL 里的
`https://github.com/<owner>/<repo>/actions/runs/<run-id>/jobs/<number>` 那个 `<number>` **不是**
job id，拿去调 API 会 404——`gh run rerun --help` 专门写了这个坑。

### 3.3 取失败日志

```bash
gh run view <run-id> --log-failed
gh run view <run-id> --job <job-databaseId> --log-failed
gh run view <run-id> --job <job-databaseId> --log
gh run view <run-id> --attempt 2 --log-failed    # 重跑过的第 2 次尝试
```

日志行前缀是 `job<TAB>step<TAB>时间戳`；gh 认不出某行属于哪个 step 时写 `UNKNOWN STEP`
（本仓库日志里很常见），不影响内容。

**落盘位置**：按 `AGENTS.md`，仓库里不留调试产物，重定向到系统临时目录再 grep：

```bash
gh run view <run-id> --log-failed > /tmp/opencode/ci-<run-id>.log
grep -n 'FAILED\|\[x\]\|error:\|undefined reference' /tmp/opencode/ci-<run-id>.log
```

### 3.4 盯住 / 重跑 / 下产物

```bash
gh run watch <run-id> --compact --exit-status    # 实时进度；失败时退出码非 0
gh run rerun <run-id> --failed                   # 只重跑失败 job（含依赖）
gh run rerun <run-id> --job <job-databaseId>
gh run download <run-id> -D /tmp/opencode/artifacts
```

`gh run watch` 不支持 fine-grained PAT（help 原话：没法给 fine-grained PAT 配 `checks:read`）。

### 3.5 annotations（check-run 上的提示）

```bash
# 先拿 check-run id
gh api repos/wangmingfa/MoonUI/commits/<sha>/check-runs \
  --jq '.check_runs[] | [.id,.name,.conclusion] | @tsv'

# 再看某条 check-run 的 annotations
gh api repos/wangmingfa/MoonUI/check-runs/<check-run-id>/annotations \
  --jq '.[] | [.path,.start_line,.annotation_level,.message] | @tsv'
```

本仓库常见两类：`Process completed with exit code 1.`（没有更多信息）和平台级
`Node.js 20 is deprecated`（`actions/setup-node@v4` / `ilammy/msvc-dev-cmd@v1` 自身声明 Node 20、
被 runner 强制跑在 Node 24；`43900679747` 这一次 7 个 job 全有，**不是项目代码的警告**）。

### 3.6 PR 上的检查

```bash
gh pr checks
gh pr checks --watch
```

### 3.7 原始 API 兜底

gh 子命令不够时直接打 REST：

```bash
gh api repos/wangmingfa/MoonUI/actions/runs/<run-id>/jobs \
  --jq '.jobs[] | [.id,.name,.conclusion] | @tsv'

# 整个 run 的日志 zip（需要 actions:read；未认证会 403）
gh api repos/wangmingfa/MoonUI/actions/runs/<run-id>/logs > /tmp/opencode/run-logs.zip
```

## 4. 本仓库的 CI 形状（判读顺序）

`.github/workflows/ci.yml` 定义 5 个 job，`core` 是三平台矩阵，所以一次 run 通常有 7 个 job 实例：

| job | 实例 | 跑什么 | 红了先看 |
| --- | --- | --- | --- |
| `core` | `ubuntu-latest` / `macos-latest` / `windows-latest` | `moon check --deny-warn`、Core + Mock + 文档示例测试、无头 Demo、`moon info` / `fmt --check`、detlint、ABI | 失败 step 里的 `[x]` 行与 `moon` 报错 |
| `core-portability` | 1 | wasm 编译与测试 | `moon check/test --target wasm` 输出 |
| `macos-backend-link` | 1 | `moon clean` + 真窗 `moon test --target native backends/native-macos` + 只链接 gallery | 失败判据名（`native_test.mbt:NNNN`） |
| `windows-backend-link` | 1 | 同上，Win32 | 同上；路径大小写 / 8.3 短名是历史高发点 |
| `linux-backend-link` | 1 | GTK4 四道闸 + native 包 + gallery 链接（xvfb） | `adapter_native_gtk.c` 编译错误、mock-gtk 闸 |

判读顺序：**job 结论 → 红的 step → `--log-failed` 里的失败判据名 → 本机同命令复现**。

拿不到日志正文（例如超过保留期）时，不要靠反复重跑蒙绿：用 CI 里的精确命令在本机复现。
`TODO.md` 的 `T275` / `T277` / `T278` 就是这么定位的。

> CI 通过 ≠ 真后端通过：`backends/` 不在本地 native 门禁的清单里，本机仍需另跑真窗测试
> （见 README「测试与 CI」）。

## 5. 常见故障

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| `gh: command not found` / `'gh' 不是内部或外部命令` | 没装 / PATH 未生效 | §1；Windows 新开窗口，Linux 重新登录 shell |
| `You are not logged into any GitHub hosts` | 没登录 | §2 |
| `failed to determine base repo: no git remotes found` | 当前目录没配 remote（或 remote 不指向 GitHub） | 按 §0.1 的约定**先不用 gh**：`git remote -v` 确认，补对 remote 或改用网页；不要用 `-R` 绕过 |
| `HTTP 401: Bad credentials` | token 过期 / 被吊销 / 抄错 | `gh auth login` 重来，`gh auth status` 核对 |
| `HTTP 403: Must have admin rights to Repository`（取日志时） | 未认证，或 token 对该仓库没有读 / admin 权限；公开仓库的日志正文也不对匿名开放 | 确认 `gh auth status` 是本人账号且 scope 含 `repo`（或 fine-grained 的 `Actions: Read`）。`TODO.md` 的 `T275` / `T277` / `T278` 落地注里记过这条边界——那台机器当时没装 gh，走的是匿名访问 |
| job 结论是 `cancelled`，annotation 写 `The job was not acquired by Runner of type hosted even after multiple attempts` | 托管 runner 容量不足（macOS arm64 常见），job 根本没开始 | 用 `gh run rerun <run-id> --job <databaseId>` 单独重跑；`--failed` 只认 `failure`，不会带上 `cancelled` |
| 取 run / job 返回 `404 Not Found` | 仓库名写错、账号没权限（私有仓库伪装成 404）、run 过了保留期（默认 90 天）、把浏览器 URL 的 job number 当成了 job id | `gh repo view` 先确认仓库；用 `--json jobs --jq '.jobs[].databaseId'` 取真 id |
| `gh run watch` 报 fine-grained PAT 不支持 | 见 §3.4 | 改用经典 PAT（`repo`）或 `GH_TOKEN: ${{ github.token }}` |
| 日志下载慢 / 部分行没有 step | gh 拿不到 zip 时逐 job 走 API，缺失超过 25 个会失败（`gh run view --help` 原话） | 用 `--job <id>` 单独取 |
| `API rate limit exceeded` | 未认证或高频调用 | `gh api rate_limit`；认证后额度更高 |
| keyring 报错（WSL / 容器 / 无 D-Bus） | 没有 Secret Service | `gh auth login --insecure-storage`，或 `GH_TOKEN` |
| 企业网络 / 代理 | 需要走代理 | `export HTTPS_PROXY=http://host:port`；GHES 用 `gh auth login -h ghe.example.com` |

## 6. 相关文档

- CI 定义：`.github/workflows/ci.yml`
- 构建链、平台准备与本地门禁：`docs/build-and-environment.md`
- CI job 一览与「测试与 CI」：`README.md`
- 真实 CI 失败案例与取证方式：`TODO.md` 的 `T275` / `T277` / `T278`
