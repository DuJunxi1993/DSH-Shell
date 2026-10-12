# dsh 桌面契约实测报告

- **日期**：2026-10-12
- **对象**：`@deepseek-ai/dsh@0.2.0-rc.2`，Node v26.11.1，macOS 27.2 arm64
- **工具**：`tools/dsh-probe/main.swift`（单文件，`swiftc` 直编，不依赖 Xcode 工程）
- **原始数据**：`docs/probe/report.json`；截图 `docs/probe/{baseline,darwin,windows,darwinProxy}.png`
- **视口**：1280 × 800，`WKWebView`，`WKUserScript(.atDocumentStart, mainFrameOnly)`

---

## 结论摘要

1. **Windows 侧：现有的几何避让大部分是多余的。** 只需设置 `html[data-windows-titlebar]` 与 `--dsh-windows-titlebar-height` 两个属性，dsh 自己完成 caption 预留、拖拽条绘制、内容列左上角圆角、以及全屏 modal 的顶部避让。`platform_adapt.js` 中 `insetColumn` / `clearCorner` / `gutterTopRow` / `layoutSignature` 四套避让应降级为「契约不成立时的兜底」。
2. **macOS 侧：`data-platform` 不是 CSS 钩子，而是运行时开关。** 单独设置会让 dsh Web UI **启动失败**；必须同时提供 `window.dshDesktopBoot` 与 `window.dshDesktop` 预加载桥接。实测桥接面为 **5 个入口**，并已用手写实现验证：**Web UI 完整启动、48px 顶部预留生效、快捷键输入被 dsh 的真实 listener 接受、零页面错误**。工作量不是「设两个属性」，但也不是 Electron——是一个五个方法的小适配层。
3. **`-webkit-app-region` 在 WKWebView 中不受支持**（五种模式实测均为 `false`）。dsh 的 `data-window-drag` 行在 macOS 下不会自拖，壳必须转发原生拖拽。这是 macOS 侧采用桌面契约后的唯一新增工作。

---

## 一、端点解析规则复核

探测工具内建了与 `windows/src-tauri/src/endpoint.rs` 一致的四条接受规则，并用真实 dsh 验证：

```
dsh web: http://127.0.0.1:3080/?token=<token>
```

| 请求 | 实测结果 | 含义 |
|---|---|---|
| 带 `?token=` 的 URL | `303` → `Location: ./` + `dsh-auth-` cookie | token 被换取为 cookie，**303 才是成功** |
| 带 cookie 的干净 URL | `200`，34782 字节（SPA） | 索引页只在干净 URL + cookie 下提供 |
| 无 token 无 cookie | `401` | **无 token 的 URL 永远无法加载 SPA** |

据此确认：`port` 探测**不能**作为 URL 回退方案，只能作为日志行。macOS 侧当前的 `probeFixedPort` / `adoptByProbe` / `AttachProbe` 均产出无 token URL，对着当前 dsh 必然 401——该功能链是失效的。

> **本报告的一处工具修正**：端口释放断言最初使用严格 `bind()`（不带 `SO_REUSEADDR`），因已建立连接的 `TIME_WAIT` socket 而在 dsh 已退出后仍报「占用」。已改为 `SO_REUSEADDR`，与 node 服务端行为一致。

---

## 二、五模式实测结果

注入方式统一为 `WKUserScript(.atDocumentStart, mainFrameOnly: true)`。

### 2.1 汇总

| 指标 | A 基线 | B `data-platform=darwin` | C `data-windows-titlebar` | D darwin + Proxy 桩 | E darwin + 真实桥接 |
|---|---|---|---|---|---|
| **Web UI 启动成功** | ✅ | ❌ **启动失败** | ✅ | ✅ | ✅ |
| `--dsh-frame-top-clearance` | — | `48px` | `32px` | `48px` | `48px` |
| `--dsh-frame-overlay-top` | — | `calc(48px + 20px)` | `calc(32px + 20px)` | `calc(48px + 20px)` | `calc(48px + 20px)` |
| `--dsh-frame-chrome-top` | — | — | `32px` | — | — |
| **frame 自留顶部 padding** | 无 | 无（未渲染） | ✅ **`padding-top: 32px`** | 无（侧栏走 52px 顶条路径） | 无（同左） |
| **内容列左上圆角** | `0px` | `0px` | ✅ **`16px`** | `0px` | `0px` |
| 内容起始 y | ~0 | — | **32** | ~40（侧栏顶条） | ~40 |
| `[data-window-drag]` 元素数 | 3 | 0（未渲染） | 3 | **4** | **4** |
| `CSS.supports('-webkit-app-region','drag')` | **false** | **false** | **false** | **false** | **false** |
| `shell.leading` seat | 未挂载 | 未挂载 | 未挂载 | 未挂载 | 未挂载 |
| 快捷键输入被 dsh 的真实 listener 接受 | — | — | — | — | ✅ `Code+Meta` |
| 页面错误数 | 0 | 1 | 0 | 0 | **0** |

D 与 E 的截图**逐字节相同**：布局不取决于桩的保真度，只取决于 dsh 是否应答契约。

全屏态（`html[data-fullscreen]`）**只收敛两个变量**：Windows 模式 `--dsh-frame-chrome-top` 由 `32px` → `0px`，`--dsh-frame-overlay-top` 由 `calc(32px + 20px)` → `20px`；darwin 模式同样。

**`--dsh-frame-top-clearance` 不收敛**，全屏时仍是 `32px`。三个变量平时同源，全屏是它们唯一分岔的状态，实测：

```
chromeTop = 0px     ← 已复位
overlay   = 20px    ← 已复位
top       = 32px    ← 未复位
```

所以"壳无需干预"只在**读对变量**时成立：消费 `--dsh-frame-chrome-top`（窗口边缘避让）或 `--dsh-frame-overlay-top`（弹层避让）的地方都是自动的；任何读 `--dsh-frame-top-clearance` 的代码会在全屏时多留 32px。**读 `chrome-top`，不要读 `top-clearance`。**

### 2.2 A 基线（= 当前 macOS 壳的真实行为）

无任何变量下发，frame `padding-top` 为 `0px`，内容从窗口最顶端开始。dsh 按**普通浏览器**渲染。截图 `probe/baseline.png`：侧栏无顶部留白，底部为「⚙ 设置」。

### 2.3 C Windows 模式 —— **契约成立，避让多余**

注入：`documentElement.setAttribute('data-windows-titlebar','')` + `--dsh-windows-titlebar-height: 32px`

dsh 自行完成：

```
[data-windows-titlebar] .frame  { padding-top: var(--dsh-windows-titlebar-height) }
[data-windows-titlebar] .frame::before { height: var(--dsh-windows-titlebar-height);
                                          background: var(--dsw-specific-sidebar-fill);
                                          -webkit-app-region: drag }
[data-windows-titlebar] .centerCol { border-radius: var(--dsh-windows-content-radius) 0 0 0 }
html[data-windows-titlebar]       { --dsh-frame-top-clearance: var(--dsh-windows-titlebar-height);
                                    --dsh-frame-chrome-top: var(--dsh-windows-titlebar-height) }
```

实测确认：frame `padding-top` = `32px`；内容列 `border-top-left-radius` = `16px`；内容起始 y = 32。截图 `probe/windows.png` 可见白色内容面板从 y≈32 开始、左上角有明显圆角，侧栏侧色块铺满整列高度至窗口底部。

全屏 modal overlay 也被覆盖 —— 但**不是**靠某条 `[data-windows-titlebar] .overlay{padding-top:…}` 规则（dsh 里没有这条）。弹层的两层各自消费一个变量：

```
/* 遮罩层从标题栏下沿开始 */
._mask_o6lrb_18   { position:absolute; inset: var(--dsh-frame-chrome-top, 0px) 0 0; … }

/* 弹层本体的上下留白 */
._root_o6lrb_6    { padding: max(24px, var(--dsh-frame-overlay-top, 24px)) 24px; … }

/* 弹层内可滚动区的高度上限 */
._scrollable_4ub78_19 { max-height: calc(100vh - 12px - max(12px, var(--dsh-frame-overlay-top, 12px))); … }
```

三者都带 `var(…, <兜底值>)`，所以契约缺席时它们退回一个合理值而不是归零 —— 这也是为什么 A 基线（不下发任何变量）看起来仍然正常。

> **测量环境限制**：C 模式在 WKWebView 中测量，而非 WebView2。预留与圆角来自 dsh 的 React/CSS 代码，与引擎无关，结论可迁移。**唯一不可迁移的是 `-webkit-app-region`**：见 §3。

### 2.4 B / D darwin 模式 —— **`data-platform` 是运行时开关**

`@deepseek-ai/dsh-client-shortcuts/lib/client.js` 中：

```js
function detectEnvironment(document, navigator) {
  const desktop = document.documentElement.dataset.platform;
  const device  = desktop ?? navigator.platform;
  return {
    runtime:  desktop === void 0 ? "web" : "desktop",   // ← 属性存在即切换运行时
    platform: /darwin|mac|iphone|ipad/iu.test(device) ? "macos" : ...
  };
}
// ShortcutsService 构造函数：
const keyboard = environment.runtime === "desktop" ? window.dshDesktop?.keyboard : undefined;
if (environment.runtime === "desktop" && keyboard === undefined)
  throw new Error("Desktop keyboard bridge unavailable");
```

**B 模式（只设属性、不给桥接）的实测后果**：

```
BOOT CARD: HARNESS / Failed to load plugins
  @deepseek-ai/dsh-client-shortcuts            failed
  @deepseek-ai/dsh-client-ui-shortcuts         pending (waiting for service: shortcuts)
  @deepseek-ai/dsh-client-ui-layout            pending (waiting for service: shortcuts)
  @deepseek-ai/dsh-client-ui-open-in-app       pending (waiting for services: shortcuts, layout)
  web boot: 24 entries did not activate
```

等待 90 秒仍未启动完成（`bootWaitTimedOut: true`，87 次轮询）。`--dsh-frame-top-clearance: 48px` **确实下发了**，但因为 layout 包未激活，没有任何东西被渲染。级联链：`shortcuts` 抛错 → `ui-shortcuts` 与 **`ui-layout`** 永久 pending → 24 个条目无法激活。

**这不是可以靠「多等一会儿」解决的时序问题**——它是显式的配置失败。

**D 模式（`data-platform=darwin` + Proxy 桩桥接）**：Web UI **完整启动成功**，`--dsh-frame-top-clearance: 48px` 生效，`[data-window-drag]` 从 3 个增至 4 个（多出的是侧栏让位交通灯的顶条行），并渲染出 dsh 的 macOS 专属样式（侧栏 vibrancy 渐变、底部由「⚙ 设置」变为「⋯ 更多」）。见 `probe/darwinProxy.png`。

---

## 三、`-webkit-app-region`：macOS 的硬缺口

四种模式下 `CSS.supports('-webkit-app-region','drag')` 全部为 **`false`**，且拖拽行上 `getComputedStyle(...).webkitAppRegion` 为 `null`。

- `-webkit-app-region` 是 **Blink（Chromium）属性**。Windows 侧走 WebView2，因此 dsh 的 `[data-window-drag]` 行按 `ui-web base.css` 声明的规则**能自拖**。
- **WKWebView 不实现该属性**，所以 macOS 下 dsh 的拖拽行不会移动窗口。壳必须自行把拖拽转发到 `NSWindow.performDragOperation(_:)`。

> 这也意味着：即便 C 模式结论成立并删掉几何避让，**Windows 侧仍需保留拖拽条**（由 dsh 绘制 + `-webkit-app-region` 生效），**macOS 侧则必须补一套原生拖拽桥接**，这是新增工作量。

---

## 四、macOS 桌面宿主需要实现什么（实测枚举 + 真实实现验证）

D 模式用 Proxy 记录 dsh 对预加载的全部访问，67 次访问收敛为 **5 个入口**。
E 模式则按发布的类型声明手写实现，验证它不是「理论上可实现」而是**真的能跑**。

| # | 入口 | 实测调用 | 返回值形状 | 来源 |
|---|---|---|---|---|
| 1 | `dshDesktopBoot.ready()` | 1 | `Promise<{ injections: InjectionRow[], streamBaseUrl: string }>`；dsh 随后设 `window.__DSH_TRANSPORT__ = { ownsHost: true, streamBaseUrl }` 并应用注入行 | `dsh-web-frontend/dist/assets/index-*.js` |
| 2 | `dshDesktop.keyboard.subscribe(listener)` | 1 | 返回取消函数。`DesktopShortcutApi` 只有 `subscribe` 与 `closeWindow(revision)` 两个方法 | `dsh-client-shortcuts/lib/types/native.d.ts` |
| 3 | `dshDesktop.shortcuts.get(definitions)` | **28**（每条已注册命令一次） | `ShortcutPersistence` 快照：`{ revision: uuid, sequence, document: { schemaVersion, profiles }, status, error, usingDefaults }` | 同上 + `lib/client.js` |
| 4 | `dshDesktop.shortcuts.subscribe(...)` | 1 | 取消函数 | 同上 |
| 5 | `dshDesktop.protocolVersion` | 1 | 版本协商值 | 实测 |

E 模式结果：**Web UI 首次轮询即启动成功**（`attempts: 1`，未超时），零页面错误，`--dsh-frame-top-clearance: 48px` 生效，`[data-window-drag]` 由 3 增至 4，并合成一个 `Code+Meta` 的 `DesktopShortcutInput` 推过 dsh 真实注册的 listener，**未被拒绝**。

### 4.0 两次「读代码得出的结论被实测推翻」

这份报告里最贵的两条教训，都出在同一件事：**读 bundle 只能证明 bundle 读过什么。**

**其一：`streamBaseUrl` 不是「写而不读」。**
初始实现里 `dshDesktopBoot.ready()` 返回 `{ injections: [], streamBaseUrl: "" }`，理由是：全包搜索 `streamBaseUrl` 只有 2 处（解构 + 赋值），`__DSH_TRANSPORT__` 也只有 2 处引用，消费点只读 `loadBundle`。所以「宿主不需要代理事件流，空值无害」。

实测：**空值让 dsh 完全无法启动**——57 个条目未激活，`@deepseek-ai/dsh-api-gateway: failed`，boot 屏永远停在 "Loading plugins…"。改成 `location.origin` 立刻正常。

结论修正：`ownsHost` 确实只写不读（这部分成立），但 `streamBaseUrl` 的**取值有实际意义**，消费方不在那个 bundle 里。现在按真实 origin 提供——一个属性，无论有没有人读它都是对的。

**其二：探测脚本自己的语法错误，被我误判成桥接的 bug。**
第一次跑 `darwinAppBridge` 失败，我一度以为是桥接实现有问题。实际是探测脚本里注释用了 `;` 而不是 `//`，反引号被解析成模板字符串，整段脚本抛 `Script error.`，`dataset.platform` 都没设上。

代价是两轮误判。修法有两处，都留在代码里：
- `tools/dsh-probe` 的组合脚本在每次运行前用 `node --check` 校验
- 页面错误捕获器**必须在被测脚本之前**注入，否则脚本自己的异常捕获不到

这两条现在都是探测工具的硬性步骤，不是可选项。

### 4.1 一个必须记录的坑

第一次手写尝试定义了 `dshDesktop` 却**漏了 `dshDesktopBoot`**，Web UI 卡在启动屏 90 秒超时。真正抛错的是后者——dsh 在挂载任何东西之前先 `await` 它的 `ready()`，所以没有预加载桥接的文档根本不会启动完。

`DesktopShortcutInput` 的形状（实测由类型声明确认）：

```ts
{ revision } & (
  { kind: 'menu', commandId } |
  { kind: 'keyboard' | 'iframe' | 'webview',
    frameName, code, secondCode?, control, alt, shift, meta, repeat }
)
```

### 4.2 桥接能换来什么

| 能力 | 说明 |
|---|---|
| dsh 自留 48px 顶部 | 页面侧的顶部预留由 dsh 负责，壳不必再猜。**注意这不影响 `ShellScene` 的 Timer**，见下 |
| macOS vibrancy 侧栏样式 | dsh 自己的 `[data-platform=darwin]` 侧栏渐变 |
| 原生快捷键走 dsh 的命令注册表 | 与 DOM 固定动作分层，`⌘`-family 键不再和浏览器冲突 |
| `shell.leading` seat | 侧栏折叠时 dsh 自己挂载窗口 chrome 位（本次四轮侧栏均展开，未观测到挂载） |

### 4.3 桥接**不能**解决的

**`-webkit-app-region` 在 WKWebView 中不被支持**（五种模式实测全部 `false`），它是 Blink 属性。因此 dsh 的 `[data-window-drag]` 行在 macOS 下**不会自拖**，壳必须自己把 `mousedown` 转发到 `NSWindow.performDragOperation(_:)`。这是采用桌面契约后 macOS 侧唯一的新增工作，也是它与 Windows 侧的根本差异。

### 4.4 一处必须讲清的区分：页面侧 vs 窗口侧

本报告初稿曾断言「接入桌面契约后，`ShellScene` 里 1.5 秒 `Timer` 轮询重断言 `fullSizeContentView` 的 workaround 可以退休」。**那是错的。**

两者修的不是同一件事：

| | 负责什么 | 谁的问题 |
|---|---|---|
| **dsh 桌面契约** | 页面侧：顶部 48px 预留、左上角 clearance、vibrancy 样式 | 壳猜页面布局 |
| **`fullSizeContentView` Timer** | 窗口侧：`NSWindow.styleMask` 在 key-state 切换时被 AppKit 退回「内容在标题栏下方」，标题栏闪现不透明、页面缩一两帧 | AppKit 的已知抖动 |

Timer 重断言的是 `window.styleMask.insert(.fullSizeContentView)` + `titlebarAppearsTransparent` + `titleVisibility = .hidden`，全部是 `NSWindow` 的属性，**dsh 的任何 CSS 变量都影响不到它**。

所以接入契约之后：dsh 会自己把顶栏内容让出来，但窗口那个抖动仍然存在，Timer 必须保留。要不要改成事件驱动另说，但「因为接了契约所以可以删」这个理由是错的——若照它去删，会得到一个标题栏在每次窗口激活时闪一下的回归。

这个区分值得单独写下来，因为它正是「把一个正确的观察推广到它不覆盖的地方」这种错误最容易发生的地方。

### 4.5 快捷键：宿主**必须**自己算出 dsh 会吞掉哪些组合键

这是接入契约后最容易被做错、且错得最彻底的一处，因此单列。

dsh 的 `keyboard.subscribe(listener)` 把 listener 返回类型定成 `void`：**宿主无法从返回值判断某个组合键是否被消费**。于是只有两个选择，两个都是错的：

- **全部吞掉** —— `dispatch` 只要发现「有 listener」就返回 `true`，而 listener 在整个会话期间都在。所以包括 composer 在内的**每一个按键都会被吞掉，用户根本无法输入**。
- **全部不吞** —— dsh 的绑定会先触发一次，同一个组合键随后又走原生路径再来一次：⌘N 两次，⌘W 在 dsh 背后把窗口关掉。

正确答案不是猜，而是**用 dsh 自己给的数据把它自己的表算出来**：

1. `shortcuts.get(definitions)` 会把**实时的命令目录**交给宿主（实测 28 次，随模块激活递增，每次都是上一次的超集）。每条形如
   `{ id, defaults: { "desktop:macos": { code, modifiers } }, fixed? }`。
2. 宿主自己持有用户的覆盖（`document.profiles["desktop:macos"]`）。
3. 两者合成 `effectiveShortcuts` 的键集合，即 dsh 的 `bindings ∪ conflicts`。

关键事实来自 `@deepseek-ai/dsh-client-shortcuts/lib/client.js` 的 `dispatch`：命中 `bindings` 或 `conflicts` 时都会先 `consume()` 再返回（冲突是**先吞掉再拒绝执行**），未命中则返回 `pass`、完全不消费。所以「吞掉这个集合之外的一切」既是必要的也是充分的。

还有一条决定了实现方式的事实：`bindingIssue(binding, "desktop", "macos")` **恒返回 `null`**——桌面档没有任何保留组合。也就是说 dsh 会理直气壮地绑定 ⌘W / ⌘Q / ⌘B / ⌘R，并期待宿主让出来；而 ⌘C / ⌘V / ⌘X **不在**目录里，宿主不转发，原生剪贴板因此照常工作。这条无法从 macOS 的「保留键」常识推出来，只能从实现里读。

其余按真实契约落地的形状（均为 `@deepseek-ai/dsh-client-shortcuts/lib/types/` 的原文）：

| 事实 | 形状 | 说明 |
|---|---|---|
| `ShortcutEdit` | `{type:'set', id, binding}` / `{type:'reset', id}` / `{type:'reset-all'}` | 字段是 **`id` 不是 `commandId`**；`binding` 是**对象**不是字符串 |
| `profiles[profile][id]` | `ShortcutBinding \| null` | **`null` 是「显式解绑」**，与「缺省＝继承默认」是两种状态 |
| `ShortcutBinding.modifiers` | `['primary' \| 'control' \| 'alt' \| 'shift' \| 'meta']` | `primary` 在 macOS 上展开为 `meta`；规范化顺序固定为 `control, alt, shift, meta` |
| `bindingKey` | `[...modifiers, ...codes].join("+")` | 两端共用的匹配索引，逐字节一致才能匹配 |
| 文件内容 | **只有 document**，`JSON.stringify(document, null, 2) + "\n"` | `revision`/`sequence` 不落盘；`revision` 每次 accept 重新 `randomUUID()` |
| 桌面档 schema | 写盘时升到 **`schemaVersion: 2`** | 版本 1 无法表达双键 chord，读到 v1 里的 `secondCode` 判为损坏 |
| 写入前置校验 | 需 `definitions` 已注册该 `id` | 否则写入一个永远解析不到命令的绑定 |
| 冲突校验 | 编辑后重算 `effectiveShortcuts`，命中 issue/conflict 则 `status: "conflict"` | 冲突的组合键仍会被 dsh 吞掉 |

> 一个 Swift 特有的坑：`[String: ShortcutBinding?]` **无法表达「键存在且值为 nil」**——赋 nil 会删键。要区分「解绑」与「缺省」，必须用枚举（`ShortcutOverride`）而不是双层 Optional。踩这个坑的表现是：解绑后命令又变回默认绑定。

## 五、对现有实现的直接影响

| 位置 | 现状 | 依据本报告 |
|---|---|---|
| `windows/src-tauri/platform_adapt.js`（1565 行） | 自建 32px DOM 标题栏 + 四套几何避让 + `chrome_report` 几何自检 | 设置两个属性后，`insetColumn` / `clearCorner` / `gutterTopRow` / `layoutSignature` 变冗余；标题栏按钮簇仍需保留（dsh 不提供按钮，只提供拖拽条） |
| `macos/Sources/DSHShell/Bridge/bridge.js:100` | `paddingTop: 20px` 打在 `#root [data-dsh-frame] > [data-pane="sidebar"]` | **该选择器在 dsh 0.2.0-rc.2 全包树中不存在**，此补丁从未生效 |
| `macos/Sources/DSHShell/Views/ShellScene.swift:96-165` | 1.5 秒 `Timer` 轮询重断言 `fullSizeContentView` | **不变。** 它修的是窗口侧的 AppKit 抖动，与 dsh 契约无关（见下） |
| `macos/Sources/DSHShellCore/Services/DSHProcessManager.swift:213-243`、`HealthProbe.swift:64-92` | 探针兜底 / attach 产出无 token URL | §1 已证明必然 401，链路失效 |

---

## 六、未覆盖 / 待补测

1. **WebView2 上的实测（最高优先级）。** C 模式的预留与圆角结论可迁移，但两点不可迁移：`-webkit-app-region` 在 WebView2 上是否生效，以及 wry 的无边框窗口边缘命中测试是否与之冲突。另外 Windows 侧走的是 `window.eval`（`initialization_script` 到不了远程 origin，受 dsh CSP 所限），也就是契约在**页面加载后**才声明，而本测量用 `WKUserScript(.atDocumentStart)`——需要实机确认没有可见跳变。
2. **侧栏折叠态**。五轮测量中侧栏均为展开态，`shell.leading` seat（仅折叠时挂载）与 `--dsh-frame-leading-clearance`（160px / 全屏 84px）未观测到。
3. **`injections` 的实际内容**。E 模式返回空数组，未验证真实注入行会加载什么（`global` / `script` / `script-src` / `style` / `html` 五种 kind）。
4. **`protocolVersion` 协商语义**。只观测到被读取，未确认版本不匹配时的降级行为；E 模式返回 `1`。
5. **原生拖拽的手感**。机制层面已确认可用：`performWindowDragWithEvent:` 在本机存在（`responds(to:)` 与 `class_getInstanceMethod` 均成功，因为它在 category 里，`class_copyMethodList` 列不出来），4 个拖拽区已实测。仍未验证的是双击标题栏最大化、按住时的光标反馈、以及拖拽与页面文本选择的冲突消解——这些只能靠手测。
6. ~~**`shortcuts.edit` 与 `recording`**~~ —— **已按真实契约实现并单测覆盖**。见 §4.5。仍未验证的只有 `recording(active:)`：dsh 的录音 UI 在桌面档是否调用它，本次未观测到（`keyboard` 与 `shortcuts` 两个面上都只有 `subscribe/get/edit` 被调用）。
7. **DSH 版本绑定**。全部结论基于 `0.2.0-rc.2`。dsh 为 pre-1.0，契约可能变更；建议将本工具纳入回归。

---

## 七、复现方式

```bash
# 必须从 macos/ 运行：探测工具按 `#filePath` 向上定位
# Sources/DSHShell/Bridge/dsh_desktop_bridge.js，从别处运行会直接 FATAL。
cd macos
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swiftc -O tools/dsh-probe/main.swift -o /tmp/dsh-probe \
  -framework AppKit -framework WebKit
/tmp/dsh-probe --port 3080 --out /tmp/dsh-probe-out

# 只跑真实 App 桥接这一档
/tmp/dsh-probe --port 3080 --out /tmp/dsh-probe-out --only darwinAppBridge
```

`--only darwinAppBridge` 的消息序列（`report.json` → `modes.darwinAppBridge.desktopSurface.probeMessages`）是判断桥接是否健康的直接证据：

```
bridgeInstalled {"hasHost":true,"appRegion":false}
ready:called
ready:resolved
keyboardSubscribed {}
shortcutsGet {"id":"1","definitions":[]}
shortcutsGet {"id":"2","definitions":[{"id":"fixed.move",...}]}
...                                            ← 递增到 28 条
```

工具自建隔离 `DSH_HOME`（不触碰 `~/.dsh`），自行 spawn `dsh web`，**只 kill 自己捕获的 PID**，结束时断言端口释放。

> **安全约束**：本仓库任何代码都不得按名字杀进程。`windows/AGENTS.md` 规则 1 记录了前一个 agent 用 `pkill -f dsh` 杀掉自己所在宿主进程的事故。实测前须确认无其他 dsh 在运行——`bili` 代理（端口 18787）是机器级共享的，第二个 dsh 会 attach 到已有的那个而非失败，会静默改变本次行为。