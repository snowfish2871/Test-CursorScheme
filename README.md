# Test-CursorScheme

> Windows 鼠标指针（游标）方案诊断与应用工具

一个零依赖的 PowerShell 脚本，用于排查Windows2026-08 预览更新 (KB5120998) (26200.9278) 导致的「自定义鼠标指针方案不生效」类问题。它读取当前用户注册表中配置的光标文件路径，逐项校验文件存在性、可加载性，并可选地将其应用到当前会话。

---

## 目录

- [背景](#背景)
- [特性](#特性)
- [环境要求](#环境要求)
- [安装](#安装)
- [快速开始](#快速开始)
- [参数说明](#参数说明)
- [输出对象](#输出对象)
- [状态码含义](#状态码含义)
- [光标角色对照表](#光标角色对照表)
- [工作原理](#工作原理)
- [常见场景](#常见场景)
- [故障排查](#故障排查)
- [已知限制](#已知限制)
- [如何持久化光标方案](#如何持久化光标方案)
- [常见问题](#常见问题)
- [许可](#许可)

---

## 背景

Windows 的鼠标指针方案存储在注册表 `HKEY_CURRENT_USER\Control Panel\Cursors` 下，每个「角色」（箭头、文本选择、忙碌……）对应一个 `.cur` 或 `.ani` 文件路径。

当自定义方案「设置了但不生效」时，可能的原因有很多：

- 注册表路径指向的文件已被删除或移动
- 路径中的环境变量无法展开
- 文件格式损坏，`LoadCursorFromFile` 拒绝加载
- 系统未收到刷新通知（未调用 `SPI_SETCURSORS`）
- 某些角色 ID 在当前系统上不受支持

图形界面（控制面板 → 鼠标）不会告诉你究竟卡在哪一步。本脚本把每个环节拆开，逐项给出明确结论和 Win32 错误码。

---

## 特性

- **默认只读**：不加参数时纯诊断，加载后立即释放句柄，不改动系统任何状态
- **结构化输出**：返回 `[pscustomobject]` 数组，可直接接 `Where-Object` / `Export-Csv` / `ConvertTo-Json`
- **错误码可读化**：通过 `Win32Exception` 把裸错误码翻译成人话
- **正确的句柄所有权处理**：`SetSystemCursor` 成功后不再 `DestroyCursor`，失败时才释放
- **StrictMode 安全**：注册表项缺失不会导致脚本中断
- **一键还原**：`-RestoreDefaults` 调用 `SPI_SETCURSORS` 撤销本次内存修改
- **无需管理员权限**：全程仅操作 `HKCU` 与当前会话
- **零外部依赖**：仅用内置 `Add-Type` 声明 user32 P/Invoke

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 7 / Server 2008 R2 及以上 |
| PowerShell | Windows PowerShell 5.1，或 PowerShell 7.x |
| 权限 | 普通用户即可（**不需要**管理员） |
| .NET | 随系统自带，无需额外安装 |

> **说明**：脚本使用 `Add-Type` 编译 C# 代码片段，需要系统上存在 .NET Framework 编译器（Windows 自带）。在受限的 Constrained Language Mode 下 `Add-Type` 会被阻止，此时脚本无法运行。

---

## 安装

直接下载单个脚本文件即可：

```powershell
# 方式一：手动保存
# 将脚本内容保存为 Test-CursorScheme.ps1

# 方式二：从仓库克隆
git clone https://github.com/snowfish2871/cursor-scheme-tools.git
cd cursor-scheme-tools
```

首次运行如遇执行策略限制：

```powershell
# 仅对当前会话放行（推荐，退出即失效）
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 或对当前用户永久放行
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

如果脚本是从网络下载的，可能带有 Zone.Identifier 标记，需解除锁定：

```powershell
Unblock-File .\Test-CursorScheme.ps1
```

---

## 快速开始

### 1. 只诊断，不改动系统

```powershell
.\Test-CursorScheme.ps1 | Format-Table Role, Status, ResolvedPath -AutoSize
```

输出示例：

```
Role        Status            ResolvedPath
----        ------            ------------
Arrow       LoadOk            C:\Windows\Cursors\aero_arrow.cur
IBeam       UsesSystemDefault
Wait        LoadOk            C:\Windows\Cursors\aero_working.ani
Crosshair   FileNotFound      D:\MyCursors\cross.cur
UpArrow     UsesSystemDefault
NWPen       LoadOk            C:\Windows\Cursors\aero_pen.cur
...
```

### 2. 只看有问题的项

```powershell
.\Test-CursorScheme.ps1 |
    Where-Object Status -notin 'LoadOk', 'UsesSystemDefault' |
    Format-List
```

### 3. 实际应用到当前会话

```powershell
.\Test-CursorScheme.ps1 -Apply
```

### 4. 应用后立即还原

```powershell
.\Test-CursorScheme.ps1 -Apply -RestoreDefaults
```

### 5. 导出诊断报告

```powershell
.\Test-CursorScheme.ps1 | Export-Csv -Path cursor-report.csv -NoTypeInformation -Encoding UTF8
```

---

## 参数说明

### `-Apply`

**类型**：`[switch]` &nbsp;&nbsp;**默认**：关闭

调用 `SetSystemCursor` 将加载成功的光标应用到当前会话。

省略时脚本仅做只读诊断：加载 → 验证 → 立即 `DestroyCursor` 释放，不触碰系统状态。

> ⚠️ **注意**：应用的修改**仅存在于当前会话内存中，不写注册表**。注销、重启，或任何程序调用 `SPI_SETCURSORS` 后都会恢复。参见[如何持久化光标方案](#如何持久化光标方案)。

### `-RestoreDefaults`

**类型**：`[switch]` &nbsp;&nbsp;**默认**：关闭

脚本执行完毕后调用 `SystemParametersInfo(SPI_SETCURSORS)`，让系统从注册表重新加载全部光标，撤销本次内存中的所有修改。

可单独使用（不带 `-Apply`），用于修复其他程序留下的异常光标状态：

```powershell
.\Test-CursorScheme.ps1 -RestoreDefaults
```

### `-Verbose`

标准通用参数。启用后输出每一项的处理进度：

```powershell
.\Test-CursorScheme.ps1 -Verbose
```

```
VERBOSE: 处理 Arrow (ID=32512)
VERBOSE: 处理 IBeam (ID=32513)
...
VERBOSE: 完成：共 17 项，失败 1 项。
```

---

## 输出对象

每个光标角色输出一个 `CursorScheme.Result` 类型的对象：

| 属性 | 类型 | 说明 |
|---|---|---|
| `Role` | `string` | 光标角色名，如 `Arrow`、`IBeam` |
| `CursorId` | `uint32` | 对应的 Win32 `OCR_*` 常量值 |
| `ConfiguredPath` | `string` | 注册表中的原始值（可能含环境变量） |
| `ResolvedPath` | `string` | 展开环境变量、去除引号后的实际路径 |
| `Status` | `string` | 处理结果，见[状态码含义](#状态码含义) |
| `Win32Error` | `int` | Win32 错误码，成功时为 `0` |
| `Message` | `string` | 人类可读的说明或错误描述 |

由于是标准对象，可以自由组合管道操作：

```powershell
# 转 JSON
.\Test-CursorScheme.ps1 | ConvertTo-Json -Depth 3

# 按状态分组统计
.\Test-CursorScheme.ps1 | Group-Object Status | Select-Object Name, Count

# 只提取失败项的路径
.\Test-CursorScheme.ps1 | Where-Object Status -eq 'FileNotFound' | Select-Object -Expand ResolvedPath
```

---

## 状态码含义

| Status | 含义 | 是否需要处理 |
|---|---|---|
| `UsesSystemDefault` | 注册表未配置该角色，使用系统内置光标 | 否，正常状态 |
| `LoadOk` | 文件存在且可正常加载（只读模式下的成功状态） | 否 |
| `Applied` | 已成功应用到当前会话（`-Apply` 模式） | 否 |
| `FileNotFound` | 注册表指向的文件不存在 | **是**，需修复路径或重装方案 |
| `LoadFailed` | 文件存在但 `LoadCursorFromFile` 失败 | **是**，文件可能损坏或格式不符 |
| `SetFailed` | 加载成功但 `SetSystemCursor` 失败 | **是**，查看 `Win32Error` |
| `SkippedUndocumentedId` | 未文档化的角色 ID 应用失败 | 否，预期内噪声 |

> `SkippedUndocumentedId` 专门用于 `Pin`（32671）和 `Person`（32672）。这两个值是 Windows 7 引入的**非公开** `OCR_` 常量，微软从未在文档中承认，`SetSystemCursor` 在多数系统上会直接返回 `FALSE`。这属于正常现象，不影响其他光标。

---

## 光标角色对照表

| 注册表键名 | OCR 常量 | 值 | 中文名称 | 文档化 |
|---|---|---:|---|:---:|
| `Arrow` | `OCR_NORMAL` | 32512 | 正常选择 | ✅ |
| `IBeam` | `OCR_IBEAM` | 32513 | 文本选择 | ✅ |
| `Wait` | `OCR_WAIT` | 32514 | 忙 | ✅ |
| `Crosshair` | `OCR_CROSS` | 32515 | 精确选择 | ✅ |
| `UpArrow` | `OCR_UP` | 32516 | 候选 | ✅ |
| `NWPen` | `OCR_HANDWRITING` | 32631 | 手写 | ✅ |
| `SizeNWSE` | `OCR_SIZENWSE` | 32642 | 沿对角线调整 1 | ✅ |
| `SizeNESW` | `OCR_SIZENESW` | 32643 | 沿对角线调整 2 | ✅ |
| `SizeWE` | `OCR_SIZEWE` | 32644 | 水平调整大小 | ✅ |
| `SizeNS` | `OCR_SIZENS` | 32645 | 垂直调整大小 | ✅ |
| `SizeAll` | `OCR_SIZEALL` | 32646 | 移动 | ✅ |
| `No` | `OCR_NO` | 32648 | 不可用 | ✅ |
| `Hand` | `OCR_HAND` | 32649 | 链接选择 | ✅ |
| `AppStarting` | `OCR_APPSTARTING` | 32650 | 后台运行 | ✅ |
| `Help` | `OCR_HELP` | 32651 | 帮助选择 | ✅ |
| `Pin` | — | 32671 | 位置选择 | ❌ |
| `Person` | — | 32672 | 人员选择 | ❌ |

---

## 工作原理

脚本对每个角色执行以下流水线：

```
读注册表值
    │
    ├─ 值缺失/空白 ──────────────────► UsesSystemDefault
    │
    ▼
展开环境变量 + 去除引号
    │
    ▼
Test-Path 校验文件
    │
    ├─ 不存在 ──────────────────────► FileNotFound
    │
    ▼
LoadCursorFromFile
    │
    ├─ 返回 NULL ───────────────────► LoadFailed（附 Win32 错误码）
    │
    ▼
是否指定 -Apply ?
    │
    ├─ 否 ──► DestroyCursor 释放 ───► LoadOk
    │
    ▼ 是
SetSystemCursor
    │
    ├─ 成功 ──► 不释放句柄 ─────────► Applied
    │
    └─ 失败 ──► DestroyCursor 释放 ──► SetFailed / SkippedUndocumentedId
```

### 关于句柄所有权

这是最容易写错的地方。根据 Win32 文档：

> `SetSystemCursor` 成功后，系统接管传入光标句柄的所有权。调用方**不得**再对该句柄调用 `DestroyCursor`。

因此脚本只在两种情况下释放句柄：

1. 只读模式（未指定 `-Apply`），加载验证完毕后主动释放
2. `SetSystemCursor` 返回失败，所有权未转移，必须自行释放

若在成功后错误地调用 `DestroyCursor`，轻则光标显示异常，重则触发访问违例。

### 关于 SPI_SETCURSORS

`SetSystemCursor` 是直接替换内存中的系统光标对象，立即生效但不落盘。

`SystemParametersInfo(SPI_SETCURSORS, ...)` 则相反：它让系统丢弃当前所有光标，从注册表重新加载。因此它既是「让注册表修改生效」的手段，也是「撤销 SetSystemCursor 修改」的手段。

脚本默认**不调用** `SPI_SETCURSORS`，这是有意为之——目的是隔离验证 `SetSystemCursor` 本身是否工作。如需刷新，显式使用 `-RestoreDefaults`。

---

## 常见场景

### 场景一：换了主题后某个光标变回默认

```powershell
.\Test-CursorScheme.ps1 | Where-Object Status -eq 'FileNotFound'
```

通常是主题包被卸载或移动，注册表仍指向旧路径。

### 场景二：整套方案完全不生效

```powershell
.\Test-CursorScheme.ps1 -Verbose
```

如果全部显示 `UsesSystemDefault`，说明注册表根本没写入 —— 问题出在设置光标的那一步，而非加载环节。

### 场景三：验证第三方工具是否正确写入了注册表

```powershell
# 运行第三方工具之前
.\Test-CursorScheme.ps1 | Export-Csv before.csv -NoTypeInformation

# 运行之后
.\Test-CursorScheme.ps1 | Export-Csv after.csv -NoTypeInformation

# 比对
Compare-Object (Import-Csv before.csv) (Import-Csv after.csv) -Property Role, ResolvedPath
```

### 场景四：光标显示异常，想恢复正常

```powershell
.\Test-CursorScheme.ps1 -RestoreDefaults
```

### 场景五：批量检查多台机器

```powershell
$machines = 'PC01', 'PC02', 'PC03'
Invoke-Command -ComputerName $machines -FilePath .\Test-CursorScheme.ps1 |
    Where-Object Status -in 'FileNotFound', 'LoadFailed' |
    Format-Table PSComputerName, Role, ResolvedPath, Message -AutoSize
```

> 远程执行时读取的是**远程会话用户**的 HKCU，通常不是交互登录用户的配置单元，结果可能与预期不符。

---

## 故障排查

### `LoadFailed`，Win32 错误 2（ERROR_FILE_NOT_FOUND）

文件在 `Test-Path` 阶段存在，但 API 找不到 —— 通常是路径含特殊字符，或存在符号链接/重解析点问题。尝试把文件复制到 `C:\Windows\Cursors\` 下并更新注册表。

### `LoadFailed`，Win32 错误 0（无错误码）

`LoadCursorFromFile` 在解析失败时不一定设置错误码。多半是文件内容不是合法的 `.cur`/`.ani` 格式 —— 例如把 `.png` 或 `.ico` 直接改了扩展名。用十六进制编辑器检查文件头：

- `.cur` 文件头应为 `00 00 02 00`
- `.ani` 文件头应为 `52 49 46 46`（`RIFF`）

### `SetFailed`，Win32 错误 87（ERROR_INVALID_PARAMETER）

传入的 `CursorId` 在当前系统上不受支持。若发生在 `Pin`/`Person` 上属正常；若发生在其他角色上，请提交 issue 并附上系统版本。

### `SetFailed`，Win32 错误 5（ERROR_ACCESS_DENIED）

罕见。可能是组策略限制了光标修改，检查：

```
HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Policies\System
```

### 脚本报错「无法加载类型 CursorSchemeNative」

处于 Constrained Language Mode，`Add-Type` 被禁用。检查：

```powershell
$ExecutionContext.SessionState.LanguageMode
```

若返回 `ConstrainedLanguage`，需在完整语言模式的会话中运行。

### 应用后光标又变回去了

这是设计行为。`SetSystemCursor` 只改内存。任何触发 `SPI_SETCURSORS` 的操作（切换主题、打开鼠标属性对话框、远程桌面重连、某些游戏启动）都会重置。参见下一节。

---

## 如何持久化光标方案

本脚本刻意不写注册表。若要让修改永久生效，标准做法是：

```powershell
# 1. 写入注册表
$cursorRoot = 'Registry::HKEY_CURRENT_USER\Control Panel\Cursors'
Set-ItemProperty -LiteralPath $cursorRoot -Name 'Arrow' `
    -Value 'C:\MyCursors\arrow.cur' -Type ExpandString

# 2. 可选：设置方案名
Set-ItemProperty -LiteralPath $cursorRoot -Name '(Default)' -Value 'MyScheme'

# 3. 通知系统重新加载并写回用户配置
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Spi {
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfo(
        uint action, uint param, IntPtr vparam, uint init);
}
'@

$SPI_SETCURSORS      = 0x0057
$SPIF_UPDATEINIFILE  = 0x01
$SPIF_SENDCHANGE     = 0x02

[void][Spi]::SystemParametersInfo(
    $SPI_SETCURSORS, 0, [IntPtr]::Zero,
    $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE)
```

要点：

- 注册表值类型应为 **`REG_EXPAND_SZ`**（PowerShell 中对应 `-Type ExpandString`），这样才支持 `%SystemRoot%` 之类的变量
- `SPIF_UPDATEINIFILE` 让修改写入用户配置文件
- `SPIF_SENDCHANGE` 向所有顶层窗口广播 `WM_SETTINGCHANGE`，使已运行的程序立即感知

写入后，可用本脚本验证配置是否正确：

```powershell
.\Test-CursorScheme.ps1
```

---

## 已知限制

**仅影响当前用户。** 脚本只读写 `HKCU`，不涉及 `HKLM` 或其他用户配置单元。

**仅影响当前会话。** `-Apply` 的修改不落盘，见上一节。

**不做 DPI 缩放。** `LoadCursorFromFile` 按文件原始尺寸加载。在高 DPI 显示器上，为 96 DPI 设计的光标会显得偏小。解决方案是准备对应尺寸的 `.cur` 文件，或改用 `LoadImage` 并显式指定 `cx`/`cy` 参数（本脚本未实现）。

**远程会话行为不确定。** 通过 PSRemoting 执行时，操作的是远程会话的用户上下文，且远程会话通常没有交互式桌面，`SetSystemCursor` 的效果不可见。

**不校验光标文件内容。** 只检查扩展名并给出警告，实际合法性交由 `LoadCursorFromFile` 判断。

**未文档化 ID 的行为可能随系统版本变化。** `Pin`/`Person` 在未来 Windows 版本中的表现不受保证。

---

## 常见问题

**Q：这个脚本会修改我的系统吗？**

不带参数运行时完全只读。只有显式指定 `-Apply` 才会调用 `SetSystemCursor`，且修改仅在当前会话内存中，重启即恢复。

**Q：需要管理员权限吗？**

不需要。所有操作都在当前用户上下文内。

**Q：会不会把光标弄坏导致无法操作？**

极端情况下如果某个 `.cur` 文件损坏但仍能被加载，可能出现光标不可见。此时运行 `.\Test-CursorScheme.ps1 -RestoreDefaults` 即可恢复；实在不行注销重登也会自动恢复。

**Q：为什么默认不调用 `SPI_SETCURSORS`？**

因为脚本的定位是诊断工具。调用它会掩盖 `SetSystemCursor` 本身的成败，无法区分「应用失败」和「应用成功但被刷新覆盖」。

**Q：`Pin` 和 `Person` 报错要紧吗？**

不要紧。这两个 ID 未被官方文档化，失败是预期行为，脚本会标

---

## 许可
**本项目使用MIT许可，鉴于项目特性，仅供学习，不保留所有权利**
