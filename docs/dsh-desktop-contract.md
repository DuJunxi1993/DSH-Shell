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

全屏态收敛（`html[data-fullscreen]`）：Windows 模式 `--dsh-frame-chrome-top` 由 `32px` → `0px`，`--dsh-frame-overlay-top` 由 `calc(32px + 20px)` → `20px`；darwin 模式同样收敛。**契约在进入全屏时自动处理，壳无需干预。**

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

全屏 modal overlay 同样 `[data-windows-titlebar] .overlay{padding-top:var(--dsh-windows-titlebar-height)}`，一并被覆盖。

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
| dsh 自留 48px 顶部 | `ShellScene.swift` 里 1.5 秒 `Timer` 轮询重断言 `fullSizeContentView` 的整段 workaround 可以退休——它当初是在和 AppKit 打架，而 dsh 那边本来就有答案 |
| macOS vibrancy 侧栏样式 | dsh 自己的 `[data-platform=darwin]` 侧栏渐变 |
| 原生快捷键走 dsh 的命令注册表 | 与 DOM 固定动作分层，`⌘`-family 键不再和浏览器冲突 |
| `shell.leading` seat | 侧栏折叠时 dsh 自己挂载窗口 chrome 位（本次四轮侧栏均展开，未观测到挂载） |

### 4.3 桥接**不能**解决的

**`-webkit-app-region` 在 WKWebView 中不被支持**（五种模式实测全部 `false`），它是 Blink 属性。因此 dsh 的 `[data-window-drag]` 行在 macOS 下**不会自拖**，壳必须自己把 `mousedown` 转发到 `NSWindow.performDragOperation(_:)`。这是采用桌面契约后 macOS 侧唯一的新增工作，也是它与 Windows 侧的根本差异。

## 五、对现有实现的直接影响

| 位置 | 现状 | 依据本报告 |
|---|---|---|
| `windows/src-tauri/platform_adapt.js`（1565 行） | 自建 32px DOM 标题栏 + 四套几何避让 + `chrome_report` 几何自检 | 设置两个属性后，`insetColumn` / `clearCorner` / `gutterTopRow` / `layoutSignature` 变冗余；标题栏按钮簇仍需保留（dsh 不提供按钮，只提供拖拽条） |
| `macos/Sources/DSHShell/Bridge/bridge.js:100` | `paddingTop: 20px` 打在 `#root [data-dsh-frame] > [data-pane="sidebar"]` | **该选择器在 dsh 0.2.0-rc.2 全包树中不存在**，此补丁从未生效 |
| `macos/Sources/DSHShell/Views/ShellScene.swift:96-165` | 1.5 秒 `Timer` 轮询重断言 `fullSizeContentView` | 若走 D 路线（接入桌面运行时），dsh 自己处理顶条与 vibrancy，该 workaround 的存在理由消失 |
| `macos/Sources/DSHShellCore/Services/DSHProcessManager.swift:213-243`、`HealthProbe.swift:64-92` | 探针兜底 / attach 产出无 token URL | §1 已证明必然 401，链路失效 |

---

## 六、未覆盖 / 待补测

1. **WebView2 上的实测（最高优先级）。** C 模式的预留与圆角结论可迁移，但两点不可迁移：`-webkit-app-region` 在 WebView2 上是否生效，以及 wry 的无边框窗口边缘命中测试是否与之冲突。另外 Windows 侧走的是 `window.eval`（`initialization_script` 到不了远程 origin，受 dsh CSP 所限），也就是契约在**页面加载后**才声明，而本测量用 `WKUserScript(.atDocumentStart)`——需要实机确认没有可见跳变。
2. **侧栏折叠态**。五轮测量中侧栏均为展开态，`shell.leading` seat（仅折叠时挂载）与 `--dsh-frame-leading-clearance`（160px / 全屏 84px）未观测到。
3. **`injections` 的实际内容**。E 模式返回空数组，未验证真实注入行会加载什么（`global` / `script` / `script-src` / `style` / `html` 五种 kind）。
4. **`protocolVersion` 协商语义**。只观测到被读取，未确认版本不匹配时的降级行为；E 模式返回 `1`。
5. **原生拖拽的手感**。§4.3 的结论是机制层面的：`performDragOperation(_:)` 可用。未验证的是双击标题栏最大化、按住时的光标反馈、以及拖拽与页面文本选择的冲突消解——这些只能靠手测。
6. **`shortcuts.edit` 与 `recording`**。E 模式提供了实现但未验证往返；真实宿主需要写入 `keybindings.json`（dsh 侧称之为 device-local `userData`）。
7. **DSH 版本绑定**。全部结论基于 `0.2.0-rc.2`。dsh 为 pre-1.0，契约可能变更；建议将本工具纳入回归。

---

## 七、复现方式

```bash
cd tools/dsh-probe
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swiftc -O main.swift -o dsh-probe -framework AppKit -framework WebKit
./dsh-probe --port 3080 --out /tmp/dsh-probe-out
```

工具自建隔离 `DSH_HOME`（不触碰 `~/.dsh`），自行 spawn `dsh web`，**只 kill 自己捕获的 PID**，结束时断言端口释放。

> **安全约束**：本仓库任何代码都不得按名字杀进程。`windows/AGENTS.md` 规则 1 记录了前一个 agent 用 `pkill -f dsh` 杀掉自己所在宿主进程的事故。实测前须确认无其他 dsh 在运行——`bili` 代理（端口 18787）是机器级共享的，第二个 dsh 会 attach 到已有的那个而非失败，会静默改变本次行为。