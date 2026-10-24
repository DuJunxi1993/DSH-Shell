# DSH Shell — 共享契约规范（SPV）

> 本文件定义 `windows/` 与 `macos/` **两个独立实现之间必须保持一致的行为**。
> 共享的是契约，不是代码：两侧不互相引用任何文件，各自构建、各自发布。
> 当一侧改变规则，另一侧必须同步改变，并在两侧各有一条测试覆盖它。

**dsh 版本锚点**：`@deepseek-ai/dsh@0.2.0-rc.2`（2026-10 实测）。dsh 为 pre-1.0，契约可能随上游变化。

**两侧实现位置**

| 条款 | Windows | macOS |
|---|---|---|
| §2 端点解析 | `windows/src-tauri/src/endpoint.rs` | `Sources/DSHShellCore/Services/EndpointResolver.swift` |
| §3 测试替身 | `windows/src-tauri/src/bin/stub-dsh.rs` | `Sources/stub-dsh/main.swift` |
| §4 启动前护栏 | `windows/src-tauri/src/preflight.rs` | `Sources/DSHShellCore/Services/Preflight.swift` |
| §5 生命周期与所有权 | `windows/src-tauri/src/process.rs` | `Sources/DSHShellCore/Services/DSHProcessManager.swift` |
| §6 配置向后兼容 | `windows/src-tauri/src/config.rs` | `Sources/DSHShellCore/Models/LaunchMode.swift` |
| §7 桌面宿主契约 | `windows/src-tauri/platform_adapt.js` | `Sources/DSHShell/Bridge/bridge.js` |
| §8 安全规则 | `windows/AGENTS.md` | 本文件 §9 |

---

## 1. 总契约

> **App 退出 → dsh 死掉 → 端口被释放。**

这是整个仓库唯一不可让步的不变量。dsh 是 Node 进程，壳是它的宿主；一个带着端口活着的 dsh 在用户看来等于"删不掉的东西"。

---

## 2. 端点解析

`dsh web` 会在 **stdout** 上打印恰好一行有用的信息，且**只在其插件 Loader 完全就绪之后**——比套接字绑定晚几秒到几十秒：

```
dsh web: http://127.0.0.1:3080/?token=<launchToken>
```

### 2.1 四条接受规则

每一条都是用一次真实故障换来的。两侧必须**同时**实现全部四条。

| # | 规则 | 拒绝的东西，以及为什么 |
|---|---|---|
| 1 | 必须以 `dsh web:` 开头（大小写不敏感、允许前导空白与多空格） | stderr 上有**不是 UI 的 loopback URL**：`bili: attaching to running proxy at http://127.0.0.1:18787` 是 dsh 的内部 HTTP 代理。本仓库曾经就栽在这里：宽泛的"任意 loopback URL"正则会把 webview 指到代理上，表现为白屏。 |
| 2 | host 必须是 loopback（`127.0.0.1` / `localhost` / `::1` / `[::1]`） | dsh 只绑 loopback。任何其他地址都不是我们的服务器。 |
| 3 | 端口必须等于我们请求的端口 | 代理、或一个残留的 dsh，会在别的端口上应答。`preferredPort == 0` 表示由系统分配，此时任意 loopback 端口均可。 |
| 4 | `?token=` 必须存在且非空 | `dsh-client-connection` 的 `authorizeIndex` 对既无有效 token query、也无 `dsh-auth-` cookie 的请求返回 **401**。无 token 的 URL 永远加载不出 SPA。 |

### 2.2 token 围栏的实测行为

在真实 dsh 上验证过（`docs/dsh-desktop-contract.md` §1）：

| 请求 | 结果 |
|---|---|
| 带 `?token=` 的 URL | `303` → `Location: ./` + `dsh-auth-` cookie |
| 带 cookie 的干净 URL | `200`，返回 SPA |
| 无 token 无 cookie | `401` |

**因此 tokenized URL 是一次性凭证**：dsh 把 query 换成 cookie 后重定向到 `./`。把 `?token=` 留在地址栏会一直 303 循环。

### 2.3 端口探测只能用于日志

因为 §2.2 的 401，**"端口有应答，就用它"这种策略永远不可能成功**。端口探测的唯一合法用途是日志：

```
port 3080 is listening (HTTP 401); still waiting for the authenticated URL line
```

这句话是"dsh 慢"与"dsh 坏了"的分界。

> **已修正的偏差**：macOS 侧此前用探针 URL 作为**兜底采纳**路径（`probeFixedPort` / `adoptByProbe` / `AttachProbe`）。它产出无 token 的 URL，对着当前 dsh 必然 401 —— 该功能要么无效、要么只在无 token 的 dsh 上生效，行为随 dsh 版本漂移。已删除，端口探测降级为纯日志。

### 2.4 输出尾部

每个可诊断的错误都应携带 dsh 最后 40 行输出。release 构建没有控制台，**尾部是原因唯一可能存在的地方**。

macOS 侧当前实现是 `lastLogLines`（200 行上限），Windows 侧是 `endpoint::OutputTail`（40 行）。**语义一致，行数上限不同是可接受的差异。**

---

## 3. 测试替身 `stub-dsh`

两侧各有一个 std-only 的替身，**绝不打真 harness**（无 API key、无 session、无 LLM 调用）。行为表是共享契约。

| 模式 | 复现的行为 | 断言它��测试 |
|---|---|---|
| `ok` | stdout 打 URL 行（含 LAN 后缀），带 303+cookie 围栏 | 解析出的 URL 带 token、端口正确、LAN 后缀未混入 |
| `tokenless` | URL 行**没有** `?token=` | 解析器拒绝；壳超时并给出解释 token 的错误信息 |
| `no-url-line` | 永远不宣布 URL | 壳超时；错误信息不含按名字 kill 的建议 |
| `die-early` | 启动途中退出（exit 3） | 壳报错，端口仍被释放 |
| `crash-after-ready` | 宣布 URL 后 500ms 退出（exit 1） | 壳自动重启；预算耗尽才报错，端口仍被释放 |
| 慢 Loader（`--url-delay-ms 2500`） | 套接字先绑、URL 后打 | 壳等 URL 行，**不是**采纳端口 |
| stderr decoy | `bili: … http://127.0.0.1:18787` | 解析出的端口不是 18787 |

**每次生命周期测试都以"端口可再绑定"收尾。** 这是 macOS 侧此前完全缺失的东西——它的测试从不 spawn 进程，因此"关掉窗口 dsh 死掉"这条不变量从未被验证过。

> 替身自带存活上限（macOS 120s / Windows 同），但**壳不得依赖它**：测试必须证明是壳自己回收了子进程。

---

## 4. 启动前护栏（preflight）

只在 `spawn` 前运行。`attach` 不 fork 任何东西，不会碰撞，因此两项都豁免。

### 4.1 嵌套 session

`dsh-shell-env` 会在**清空环境中的 `DSH_*` 之后**注入会话快照，这正是这些变量成为**可靠信号**而非猜测的原因。

标记：`DSH_SESSION_ID`、`DSH_PROFILE`、`DSH_PROFILE_DIR`、`DSH_WEB_URL`

判定：

```
DSH_SESSION_ID 存在        → 嵌套（单独即可定论）
任意两个标记同时存在        → 嵌套
仅有一个 DSH_PROFILE 等    → 歧义，不算（用户可能在普通终端里 export 过）
```

在 harness session 内再起一个 dsh 会争抢同样的端口、代理与 session store，**损害落在外层 session 上**。

> **不得**为了标记我们自己的子进程而设置任何 `DSH_*` 变量：让标记可信的那套清洗，会在我们设的值被 dsh 看到之前就把它剥掉。Windows 侧的 `AGENTS.md` 曾记录过一个不存在的 `DSH_SHELL_CHILD` 变量，原因即此。

### 4.2 端口归属

**用 bind 探测，不 scrape `netstat`/`lsof`**，以观察 dsh 自己的 bind 会观察到的东西。macOS 侧额外设置 `SO_REUSEADDR`：不带它时，上一轮连接留下的 `TIME_WAIT` socket 会让严格 bind 在监听早已消失之后仍然报"占用"，于是**第二次之后的每次启动都会被拒绝**。

行为：**先回收可证明的孤儿，再拒绝其余。**

- 占用者同时满足三个条件时——（1）监听本 App 配置的端口，（2）命令行里是本 App 配置的 `dshBinaryPath`，（3）**无人监管**——判定为本 App 上一轮留下的孤儿，自动关闭（macOS：`SIGTERM`，5 秒宽限后 `SIGKILL`；Windows：整棵进程树）然后照常启动。Windows 侧对应 `orphan::reclaim_orphan(AtStartup)`，且在**每次** spawn 之前都跑一次，不只是启动时。这一步必须**先于** `wait_for_port_release`：等待一个永远不会释放的端口只会白白耗尽重启预算。
- 条件（3）的**判定机制按平台不同，规则相同**：
  - macOS：父进程为 PID 1。dsh 是 `#!/usr/bin/env node` 脚本，内核直接以 `node` 运行它，父进程就是启动它的 shell，shell 一死父进程即变成 1。
  - Windows：沿**整条祖先链**上溯，任一环节存活即算"有人监管"。Windows 的 `dsh.cmd` 是 npm 的批处理 shim，壳 spawn 的是 `cmd.exe`，而占着端口的 `node.exe` 是它的**子进程**——那个 `cmd.exe` 只要 dsh 还活着就一直活着（它在等 node），所以"父进程是否存活"对每一个真孤儿都为真。
  - 两种机制下，终端里启动的 dsh 都在链上有活着的终端，因此都被拒绝；本 App 刚退出、尚未被 reap 的子进程同理。
- 任一条件不成立即为 `notOrphan`，拒绝启动，附证据点名"不杀"的理由，并在错误信息里点名 `attach`。

> **已修正的偏差**：macOS 侧曾用 `lsof` 找到端口占用者并**无条件杀掉**，且识别条件是"对无认证请求返回 200 + SPA 签名"——带 token 围栏的 dsh 对这种请求返回 401，所以它在真正的孤儿上从未触发，却可能误杀用户手工起的 dsh。其后一度改成纯"拒绝并指路"，结果一个真实孤儿把每次自动重启都变成 `EADDRINUSE`（三次尝试、30 余秒，最终只剩错误页）。现在的规则是两者的交集：**只关闭能证明是自己留下的东西**，其余一律拒绝并给出证据。

### 4.3 顺序

嵌套优先于端口。嵌套更危险。

---

## 5. 生命周期与所有权

### 5.1 PID 所有权记录

> 不变式：**当我们拥有、或即将拥有一个 dsh 时，它的 PID 是被记录的。**

`Command::spawn` / `Process.run()` 返回之后，到 `launch`/`start` 返回之前，存在一段**数秒**的空窗（等待 URL 行）。在这段空窗里关掉窗口，没有任何 `Drop`/`stop` 可执行，dsh 会带着端口活下来。**这是被观察到的，不是理论上的。**

因此 PID 必须在 spawn 成功的**那一刻**记录，**而不是**在 `start()` 返回时清除。Windows 侧对应 `AppState::starting_pid`，在 `point_at_dsh` 里、**存好 `DshProcess` 之后**才清除；提前清除会重新打开同一道漏口，而代码看起来是对的——退出路径既找不到 `DshProcess` 也没有 PID，于是判定"没什么可回收的"并退出。

### 5.2 teardown 必须幂等且不留状态

- 先杀子进程，再取消读管道任务，最后结束事件流。
- **不能**在没有子进程时提前返回：那会跳过读任务取消与监听器拆除，导致事件流永不结束，任何 `for await` 永久挂起。
- 杀完必须把 `process` 置 nil，否则复用同一个 manager 会抛 `alreadyRunning`。
- PID 记录在子进程确认消失**之后**才清除。

### 5.3 app 退出路径

`applicationWillTerminate` 之后进程立刻退出，Swift 并发运行时正在拆除，非结构化与 detached `Task` 都不可靠地执行 `stop()`（**实测：stop 从未执行，子 dsh 被孤立**）。因此 macOS 侧用裸 `kill`/`waitpid` 同步信号化，并在之后才尝试 actor 清理。

Windows 侧对应 `RunEvent::ExitRequested` → `prevent_exit()` → 在异步运行时上关 dsh → `exit(0)`，配一个重入标志让第二次 `ExitRequested` 放行，15s 死锁上限确保卡死的子进程不会卡死 App。

### 5.4 崩溃

- **必须通知用户。** dsh 自己死掉时，窗口不能继续停在最后一次成功的 URL 上显示死页——"会撒谎的窗口"是本仓库要消灭的失败模式之一。
- 自动重启必须有界。两侧一致：最多 3 次、指数退避（2/4/8 秒，封顶 30 秒）。
- **端口重连前要确认端口已释放，而不是释放之后。** respawn 前有界等待（10 秒、200ms 轮询）端口重新可绑定；等不到才让 preflight 明确失败。把"端口还没释放完"误报成"端口被别人占用"正是 macOS 侧曾经在选择页上给用户一个手动 Retry 按钮的直接原因。
- **重启前先回收孤儿，再等待端口。** 真实事件：一个无人监管的 `dsh web` 占着端口，三次 respawn 全部因 `EADDRINUSE` 死亡。判定规则见 §4.2；不先回收，等待与重试都不会改变结果。回收在**每次** spawn 之前进行，不只是启动时。
- **单次 respawn 失败不等于放弃。** 失败应消耗一次预算并继续退避，而不是终止整条梯队。首次 spawn 失败仍可直接报错——那时还没有梯队可爬。
- **预算重置的条件是"活得够久"，不是"解析到 URL"。** 运行满 60 秒（Windows `HEALTHY_AFTER`）才算一次新的故障；URL 一出现就清零会放过"宣布端点后立刻崩溃"的循环。重置发生在预算检查**之前**：活满一个阈值才崩溃的 dsh 不该被拿它早已付过的预算来质问。
- **预算耗尽时要让窗口说出来。** 不能再停在最后一次成功的 URL 上显示死页：Windows 侧对应 `ShellError::GaveUp`，页面显示失败原因与尝试次数。

### 5.5 attach 不得拥有进程

`attach` 采纳的实例**不是我们的**。关闭壳**不得**杀掉它。

---

## 6. 配置向后兼容

> **每一个字段都必须带默认值解码。**

这不是防御性编码，是硬要求。曾经两侧都是"全字段必填 + 解码失败静默兜底为默认值"，于是**未来版本新增任何一个字段，都会让所有存量配置文件解码失败，而用户会静默丢失 binary path、端口与启动模式**——屏幕上没有任何提示，日志里也没有（因为兜底路径不打日志）。

两侧对应的守卫：

| | 实现 | 测试 |
|---|---|---|
| Windows | `#[serde(default = "...")]` | `a_settings_file_without_zoom_still_loads` / `a_stored_zoom_survives_a_round_trip` |
| macOS | `init(from:)` 中全部 `decodeIfPresent` + 默认值 | `testAFileMissingEveryNewFieldStillLoads` |

附带要求：

- 单个字段类型错误**不应**丢弃其余字段。
- 未知字段**应**被忽略（让新版本写的文件能被旧版本打开）。
- 解码失败**必须**打日志。静默兜底让"配置坏了"与"首次启动"无法区分。
- 默认值不得写死某个开发者的家目录。macOS 侧曾把 `/Users/djx/.npm-global/bin/dsh` 作为默认值，现在改为运行时探测，找不到时回退到裸 `dsh`（它在 spawn 时对着重建后的 PATH 解析）。
  - `zoom_percent` 必须**双向**��缺省时回落 100%，且被写出时原样保存 —— 它是真实的缩放偏好，不是占位符。一旦它被降级为 `skip_serializing` 的墓碑，用户在菜单里选的档位就会在下一次保存时静默丢失（这正是它一度变成的样子，见 `windows/CHANGELOG.md`）。`a_stored_zoom_survives_a_round_trip` 守的就是这一半。

---

## 7. 桌面宿主契约（dsh 侧提供，壳侧消费）

dsh 0.2.0-rc.2 内置了桌面宿主契约。**实测结论见 `docs/dsh-desktop-contract.md`。**

### 7.1 Windows：只需两个属性

```js
document.documentElement.setAttribute('data-windows-titlebar', '')
document.documentElement.style.setProperty('--dsh-windows-titlebar-height', '32px')
```

dsh 随即自行完成：frame 顶部预留 caption 高度、绘制拖拽条、内容列左上角 16px 圆角、下发 `--dsh-frame-chrome-top`、全屏 modal overlay 顶部避让、全屏时 clearance 自动收敛。

> **这意味着 `platform_adapt.js` 的 `insetColumn` / `clearCorner` / `gutterTopRow` / `layoutSignature` 四套几何避让是冗余的**，应降级为"契约不成立时的兜底"。

### 7.2 macOS：`data-platform` 是运行时开关，不是 CSS 钩子

```js
runtime: document.documentElement.dataset.platform === undefined ? "web" : "desktop"
```

单独设置会让 Web UI **启动失败**（`ShortcutsService` 抛 `Desktop keyboard bridge unavailable`，级联导致 `ui-layout` 永久 pending、24 个条目无法激活）。必须同时提供 `window.dshDesktop` / `window.dshDesktopBoot` 预加载桥接，实测需要 **5 个入口**：`dshDesktopBoot.ready()`、`dshDesktop.keyboard.subscribe()`、`dshDesktop.shortcuts.get()`、`dshDesktop.shortcuts.subscribe()`、`dshDesktop.protocolVersion`。

### 7.3 两端共同

- **`-webkit-app-region` 在 WKWebView 中不被支持**（实测 `CSS.supports(...) === false`）。它是 Blink 属性，WebView2 支持，WKWebView 不支持。因此 dsh 的 `[data-window-drag]` 行在 macOS 下不会自拖，壳必须转发原生拖拽。
- **`dshDesktopBoot.ready()` 的 `streamBaseUrl` 必须是真实的 `location.origin`。** 读 shipped bundle 只会得到「该字段只写不读」的结论，据此返回空串会让 dsh **完全无法启动**（57 个条目未激活、`dsh-api-gateway: failed`、boot 屏永远停在 "Loading plugins…"）。消费方不在那个 bundle 里。一个属性，无论有没有人读它都要给对的值。
- **`data-platform` 与桥接必须原子地一起加载。** 属性设了而桥接没加载，dsh 会**完全无法启动**（`ShortcutsService` 抛 `Desktop keyboard bridge unavailable`，级联导致 `ui-layout` 永久 pending、24 个条目无法激活）。所以两者必须放在同一个注入脚本里：资源缺失 → 两者都不发生 → 自动退回 web 运行时。拆成两个来源就制造了一个「白屏且无提示」的故障模式。
- **契约只负责页面侧。** `ShellScene` 里 1.5 秒 `Timer` 重断言 `NSWindow.styleMask` 那个 workaround 修的是 AppKit 的窗口侧抖动，dsh 的任何 CSS 变量都影响不到它，**接入契约后依然保留**。详见 `dsh-desktop-contract.md` §4.4。
- 不设任何桌面契约时的基线：dsh 按**普通浏览器**渲染，不下发任何 `--dsh-frame-*` 变量，壳必须自行补偿。

---

## 8. 路由与窗口

- 外部链接交给系统默认浏览器，**绝不**在壳自己的 webview 里打开——那会用别人的网站替换掉 dsh，且没有标题栏、没有托盘、没有退路。
- 只有 `http(s)` 可以交给操作系统。其它 scheme 等于让对方以本进程的身份启动东西。
- dsh 原生拖拽落：不要在 AppKit 层拦截 drop。WKWebView 默认会把 drop 转成 DOM `dragover` + `drop`，页面拿到真正的 `File` 对象；早期的一个 `DroppableWebView` 子类抢走 drop 并只以文本形式传文件路径，把图片附件功能整个弄坏了。

---

## 9. 安全规则

> **绝不按名字杀进程。**

`pkill -f dsh`、`taskkill /IM node.exe`、`Stop-Process -Name dsh` 一律禁止。如果壳运行在某个 dsh session 内部，按名字杀 `node` 会杀掉承载它自己的 harness。**只 kill 自己从 `child.id()` / `process.processIdentifier` 捕获到的 PID。**

本仓库的前一个 agent 正是这样毁掉了自己的宿主进程。

其它：

- **自动化测试绝不打真 dsh。** 用 `stub-dsh`。
- 唯一会碰真 dsh 的测试必须双重门控（`#[ignore]` + 环境变量），且跑之前先记录已存在的 PID，跑完**按 PID**确认消失。
- 报错信息里**不要**建议用户 `pkill`——那与本节第一条直接矛盾，且会引导用户杀掉别人的 dsh。

---

## 10. 变更纪律

改本文件中的任何一条规则时：

1. 更新两侧实现。
2. 两侧各补/改一条测试（`docs/dsh-shell-contract.md` §3 的 fixture 表是测试的清单）。
3. 若规则来自一次真实故障，在两侧代码注释里都写明那个故障——**规则脱离它被买下的原因就会被简化掉**。本文件里的每条"为什么"都是这样累积起来的。
4. 确认 `cargo test` 与 `swift test` 都是绿的。
