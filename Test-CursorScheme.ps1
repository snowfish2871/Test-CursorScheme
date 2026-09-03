<#
.SYNOPSIS
    诊断并（可选）应用 HKCU 中配置的鼠标指针方案。

.DESCRIPTION
    读取 HKEY_CURRENT_USER\Control Panel\Cursors 下的光标文件路径，
    逐项校验文件是否存在、能否被 LoadCursorFromFile 加载，
    并在指定 -Apply 时通过 SetSystemCursor 应用到当前会话。

    注意：SetSystemCursor 的修改仅存在于当前会话，不写注册表。
    任何程序调用 SPI_SETCURSORS、注销或重启后都会恢复。

.PARAMETER Apply
    实际调用 SetSystemCursor。省略时仅做只读诊断（加载后立即释放句柄）。

.PARAMETER RestoreDefaults
    执行完毕后调用 SystemParametersInfo(SPI_SETCURSORS)，
    让系统从注册表重新加载全部光标，撤销本次内存中的修改。

.EXAMPLE
    .\Test-CursorScheme.ps1 | Format-Table -AutoSize

.EXAMPLE
    .\Test-CursorScheme.ps1 -Apply | Where-Object Status -ne 'Applied'
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$RestoreDefaults
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Native interop --------------------------------------------------------

if (-not ('CursorSchemeNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class CursorSchemeNative
{
    public const uint SPI_SETCURSORS = 0x0057;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadCursorFromFile(string fileName);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetSystemCursor(IntPtr cursor, uint cursorId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyCursor(IntPtr cursor);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfo(
        uint action, uint param, IntPtr vparam, uint init);
}
'@
}

#endregion

#region Cursor role table -----------------------------------------------------

# Optional = $true 表示该 OCR_* 值未被官方文档化（Win7 引入的私有值），
# 在部分系统上 SetSystemCursor 会返回失败，属预期内噪声。
$cursorMappings = @(
    [pscustomobject]@{ Role = 'Arrow';       CursorId = [uint32]32512; Optional = $false }
    [pscustomobject]@{ Role = 'IBeam';       CursorId = [uint32]32513; Optional = $false }
    [pscustomobject]@{ Role = 'Wait';        CursorId = [uint32]32514; Optional = $false }
    [pscustomobject]@{ Role = 'Crosshair';   CursorId = [uint32]32515; Optional = $false }
    [pscustomobject]@{ Role = 'UpArrow';     CursorId = [uint32]32516; Optional = $false }
    [pscustomobject]@{ Role = 'NWPen';       CursorId = [uint32]32631; Optional = $false }
    [pscustomobject]@{ Role = 'SizeNWSE';    CursorId = [uint32]32642; Optional = $false }
    [pscustomobject]@{ Role = 'SizeNESW';    CursorId = [uint32]32643; Optional = $false }
    [pscustomobject]@{ Role = 'SizeWE';      CursorId = [uint32]32644; Optional = $false }
    [pscustomobject]@{ Role = 'SizeNS';      CursorId = [uint32]32645; Optional = $false }
    [pscustomobject]@{ Role = 'SizeAll';     CursorId = [uint32]32646; Optional = $false }
    [pscustomobject]@{ Role = 'No';          CursorId = [uint32]32648; Optional = $false }
    [pscustomobject]@{ Role = 'Hand';        CursorId = [uint32]32649; Optional = $false }
    [pscustomobject]@{ Role = 'AppStarting'; CursorId = [uint32]32650; Optional = $false }
    [pscustomobject]@{ Role = 'Help';        CursorId = [uint32]32651; Optional = $false }
    [pscustomobject]@{ Role = 'Pin';         CursorId = [uint32]32671; Optional = $true  }
    [pscustomobject]@{ Role = 'Person';      CursorId = [uint32]32672; Optional = $true  }
)

#endregion

#region Helpers ---------------------------------------------------------------

function Get-PropertyOrNull {
    <#
        StrictMode 下直接访问不存在的属性会抛终止错误，
        因此统一走 PSObject.Properties 做存在性判断。
    #>
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function New-CursorResult {
    param(
        [string]$Role,
        [uint32]$CursorId,
        [string]$ConfiguredPath,
        [string]$ResolvedPath,
        [string]$Status,
        [int]$Win32Error = 0,
        [string]$Message = ''
    )
    [pscustomobject]@{
        PSTypeName     = 'CursorScheme.Result'
        Role           = $Role
        CursorId       = $CursorId
        ConfiguredPath = $ConfiguredPath
        ResolvedPath   = $ResolvedPath
        Status         = $Status
        Win32Error     = $Win32Error
        Message        = $Message
    }
}

#endregion

#region Main ------------------------------------------------------------------

$registryPath = 'Registry::HKEY_CURRENT_USER\Control Panel\Cursors'

try {
    $cursorSettings = Get-ItemProperty -LiteralPath $registryPath
}
catch {
    throw "无法读取注册表项 '$registryPath'：$($_.Exception.Message)"
}

$results = foreach ($mapping in $cursorMappings) {

    Write-Verbose "处理 $($mapping.Role) (ID=$($mapping.CursorId))"

    $configuredValue = Get-PropertyOrNull -InputObject $cursorSettings -Name $mapping.Role

    # 注册表值缺失或为空字符串，均表示"使用系统默认光标"，属正常状态而非错误。
    if ([string]::IsNullOrWhiteSpace([string]$configuredValue)) {
        New-CursorResult -Role $mapping.Role -CursorId $mapping.CursorId `
            -ConfiguredPath '' -ResolvedPath '' -Status 'UsesSystemDefault' `
            -Message '注册表未配置自定义光标文件。'
        continue
    }

    $configuredPath = [string]$configuredValue
    $resolvedPath = [Environment]::ExpandEnvironmentVariables($configuredPath).Trim('"').Trim()

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        New-CursorResult -Role $mapping.Role -CursorId $mapping.CursorId `
            -ConfiguredPath $configuredPath -ResolvedPath $resolvedPath `
            -Status 'FileNotFound' -Message '注册表指向的光标文件不存在。'
        continue
    }

    $extension = [IO.Path]::GetExtension($resolvedPath)
    if ($extension -notin '.cur', '.ani') {
        Write-Warning "$($mapping.Role): 扩展名 '$extension' 非 .cur/.ani，加载可能失败。"
    }

    # --- 加载 ---
    $cursorHandle = [CursorSchemeNative]::LoadCursorFromFile($resolvedPath)
    if ($cursorHandle -eq [IntPtr]::Zero) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        New-CursorResult -Role $mapping.Role -CursorId $mapping.CursorId `
            -ConfiguredPath $configuredPath -ResolvedPath $resolvedPath `
            -Status 'LoadFailed' -Win32Error $win32Error `
            -Message (New-Object ComponentModel.Win32Exception $win32Error).Message
        continue
    }

    # --- 只读诊断模式：验证完即释放，不改动系统 ---
    if (-not $Apply) {
        [void][CursorSchemeNative]::DestroyCursor($cursorHandle)
        New-CursorResult -Role $mapping.Role -CursorId $mapping.CursorId `
            -ConfiguredPath $configuredPath -ResolvedPath $resolvedPath `
            -Status 'LoadOk' -Message '文件可正常加载（未应用，指定 -Apply 以生效）。'
        continue
    }

    # --- 应用 ---
    if ([CursorSchemeNative]::SetSystemCursor($cursorHandle, $mapping.CursorId)) {
        # IMPORTANT: SetSystemCursor 成功后系统接管句柄所有权，
        #            此处不得调用 DestroyCursor。
        New-CursorResult -Role $mapping.Role -CursorId $mapping.CursorId `
            -ConfiguredPath $configuredPath -ResolvedPath $resolvedPath `
            -Status 'Applied'
    }
    else {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        [void][CursorSchemeNative]::DestroyCursor($cursorHandle)

        $status = if ($mapping.Optional) { 'SkippedUndocumentedId' } else { 'SetFailed' }
        New-CursorResult -Role $mapping.Role -CursorId $mapping.CursorId `
            -ConfiguredPath $configuredPath -ResolvedPath $resolvedPath `
            -Status $status -Win32Error $win32Error `
            -Message (New-Object ComponentModel.Win32Exception $win32Error).Message
    }
}

#endregion

#region Output & cleanup ------------------------------------------------------

$results

$failures = @($results | Where-Object { $_.Status -in 'FileNotFound', 'LoadFailed', 'SetFailed' })

Write-Verbose ('完成：共 {0} 项，失败 {1} 项。' -f $results.Count, $failures.Count)
if ($failures.Count -gt 0) {
    Write-Warning ('存在 {0} 项失败：{1}' -f $failures.Count, ($failures.Role -join ', '))
}

if ($RestoreDefaults) {
    Write-Verbose '调用 SPI_SETCURSORS，从注册表重新加载全部光标。'
    if (-not [CursorSchemeNative]::SystemParametersInfo(
            [CursorSchemeNative]::SPI_SETCURSORS, 0, [IntPtr]::Zero, 0)) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Warning "SPI_SETCURSORS 失败，Win32 错误 $win32Error。"
    }
}

#endregion
