#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Language Installer: installs a language from a local language repository and
    optionally makes it the display language.

.DESCRIPTION
    Shows a Windows Forms dialog (language drop-down, "Set as display language" check box)
    unless -Silent is used. Supports Windows 11 24H2 (build 26100) and later.

    System-wide (runs as SYSTEM/admin):
      - language pack, language features, fonts and FOD satellites, added with DISM from the
        repository (Install-Language cannot use a local source)
      - system preferred UI language, Welcome screen and new-user defaults
      - optional system locale
    Per-user (runs as the user, see Set-UserLanguage.ps1):
      - display language override, language list and keyboards, optional regional format

.PARAMETER Repository
    Folder or UNC path with the language CABs and the 'metadata' folder, as built by
    New-LanguageRepository.ps1. Defaults to the 'Repository' folder next to this script. A relative path is
    relative to this script's folder (for example -Repository LangRepo in the ConfigMgr content).

.PARAMETER Language
    Language tag to install (for example de-DE). Required with -Silent; preselects it in the GUI.

.PARAMETER SetDisplayLanguage
    Make the language the display language for the system defaults and the signed-in user(s).

.PARAMETER SetRegionalFormat
    With -SetDisplayLanguage: also set regional format and country/region for those users.

.PARAMETER SetSystemLocale
    Also set the system locale (language for non-Unicode programs). Requires a restart.

.PARAMETER ApplyToExistingUsers
    With -SetDisplayLanguage: apply the user settings to every other existing user at their
    next sign-in (Active Setup). Without it, only signed-in users and new users get them.

.PARAMETER AllowLanguageCleanup
    Do not set BlockCleanupOfUnusedPreinstalledLangPacks. By default it is set so Windows does
    not remove a language pack that no user has selected yet.

.PARAMETER Silent
    No GUI. Use for ConfigMgr deployments of a fixed language.

.PARAMETER LightTheme
    Open the window in the light theme instead of the dark one (the Theme button still switches it).

.PARAMETER LogPath
    Log folder. Defaults to %windir%\Logs\LanguagePackInstaller.

.EXAMPLE
    .\Install-LanguagePack.ps1 -Repository \\server\LangRepo

.EXAMPLE
    .\Install-LanguagePack.ps1 -Repository \\server\LangRepo -Language de-DE -SetDisplayLanguage -Silent

.NOTES
    Exit codes: 0 success, 3010 success but restart needed, 1602 cancelled, 1603 failure.
#>
[CmdletBinding()]
param(
    [string]$Repository = (Join-Path -Path $PSScriptRoot -ChildPath 'Repository'),
    [string]$Language,
    [switch]$SetDisplayLanguage,
    [switch]$SetRegionalFormat,
    [switch]$SetSystemLocale,
    [switch]$ApplyToExistingUsers,
    [switch]$AllowLanguageCleanup,
    [switch]$Silent,
    [switch]$LightTheme,
    [string]$LogPath = (Join-Path -Path $env:windir -ChildPath 'Logs\LanguagePackInstaller')
)

$ErrorActionPreference = 'Stop'
$ExitCancelled = 1602
$ExitFailure = 1603
$BoundParameters = $PSBoundParameters

function Get-RelaunchArgument {
    <# Rebuilds this script's command line for a 64-bit relaunch. #>
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($parameter in $BoundParameters.GetEnumerator()) {
        if ($parameter.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($parameter.Value.IsPresent) { $arguments += "-$($parameter.Key)" }
        }
        else {
            # A trailing backslash would escape the closing quote, so double it.
            $value = "$($parameter.Value)"
            if ($value.EndsWith('\')) { $value += '\' }
            $arguments += "-$($parameter.Key)"
            $arguments += "`"$value`""
        }
    }
    return $arguments
}

# DISM and the language cmdlets must run in a 64-bit process.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $powershell64 = Join-Path -Path $env:windir -ChildPath 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $powershell64 -ArgumentList (Get-RelaunchArgument) -Wait -PassThru -NoNewWindow
    exit $process.ExitCode
}

# A relative -Repository (for example LangRepo in the ConfigMgr content) is relative to this script's folder, not to
# the current directory, so DISM and the window's background worker get the same full path.
if (-not [IO.Path]::IsPathRooted($Repository)) { $Repository = [IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath $Repository)) }

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'LanguagePackInstaller.psm1') -Force
# No administrator check: the script runs as SYSTEM from a ConfigMgr application deployment.

$UserScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-UserLanguage.ps1'
$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'LanguagePackInstaller.psm1'

Initialize-LpiLog -Path $LogPath
Write-LpiLog -Message "===== Windows 11 Language Installer started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) (silent: $([bool]$Silent)) ====="

#region GUI

function Enable-DpiAwareness {
    <#
        Makes this process DPI-aware before any window is created (TODO item 2), so on a high-resolution screen with
        scaling Windows does not stretch the window as a bitmap (blurry text); the form scales its own layout instead.
    #>
    try {
        if (-not ('LanguagePackInstaller.Dpi' -as [type])) {
            Add-Type -Namespace LanguagePackInstaller -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
        }
        [void][LanguagePackInstaller.Dpi]::SetProcessDPIAware()
    }
    catch { }
}

function Confirm-UninstallChoice {
    <# Asked when "Uninstall this language" is ticked: a restart is required (and the display language is reset). #>
    param($Owner, [Parameter(Mandatory)]$Entry, [bool]$IsDisplayLanguage, [string]$DefaultLanguage)
    $text = "Uninstalling $($Entry.DisplayName) ($($Entry.Tag)) requires a restart to finish."
    if ($IsDisplayLanguage) {
        $text += [Environment]::NewLine + [Environment]::NewLine + "$($Entry.Tag) is the display language now. It is first set back to the default, $DefaultLanguage, for the system, the Welcome screen, new users and the signed-in users."
    }
    $text += [Environment]::NewLine + [Environment]::NewLine + 'Continue?'
    $answer = [System.Windows.Forms.MessageBox]::Show($Owner, $text, 'Windows 11 Language Installer', 'OKCancel', 'Warning')
    return ($answer -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-InstallerForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Languages,
        [Parameter(Mandatory)][hashtable]$BaseParameters,
        [string]$Preselect,
        # the language Windows was installed with: never offered for uninstall
        [string]$InstallLanguage,
        # the theme the window opens in; the Theme button switches it
        [ValidateSet('Dark', 'Light')][string]$Theme = 'Dark'
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $state = @{ PowerShell = $null; Handle = $null; ExitCode = $null; Running = $false; Index = -1; Mode = $null; Confirming = $false }
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

    # Look (TODO item 2, 2026-10-04): easier to read on a large, high-resolution screen - fixed colours (the window runs
    # as SYSTEM, so it should not depend on a user's theme), larger fonts, and layout in 96-DPI units that the form
    # scales to the screen's DPI (AutoScaleMode Dpi; the process is made DPI-aware by Enable-DpiAwareness).
    # Two themes, dark by default; the Theme button in the header switches between them.
    $themes = @{
        Dark  = @{ Back = '#1F1F1F'; Panel = '#2B2B2B'; Text = '#F3F4F6'; Hint = '#B4BAC4'; Line = '#3D3D3D'; Accent = '#0F6CBD'
                   AccentDown = '#1A7FD4'; Disabled = '#3D3D3D'; Border = '#6B6B6B'; Hover = '#3A3A3A'; DisabledText = '#8A8F98' }
        Light = @{ Back = '#F3F4F6'; Panel = '#FFFFFF'; Text = '#111827'; Hint = '#4B5563'; Line = '#D1D5DB'; Accent = '#0F6CBD'
                   AccentDown = '#0C5598'; Disabled = '#D1D5DB'; Border = '#9CA3AF'; Hover = '#E5E7EB' }
    }
    foreach ($palette in @($themes.Values)) { foreach ($key in @($palette.Keys)) { $palette[$key] = [System.Drawing.ColorTranslator]::FromHtml($palette[$key]) } }
    $state.Theme = $Theme
    # Dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE) and dark log scroll bar, where Windows supports them.
    try {
        if (-not ('LanguagePackInstaller.Theme' -as [type])) {
            Add-Type -Namespace LanguagePackInstaller -Name Theme -ErrorAction Stop -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string appName, string idList);
'@
        }
    }
    catch { }
    $fontMain = New-Object System.Drawing.Font('Segoe UI', 11)
    $fontHint = New-Object System.Drawing.Font('Segoe UI', 10)
    $fontButton = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $point = { param([int]$X, [int]$Y) New-Object System.Drawing.Point($X, $Y) }
    $size = { param([int]$W, [int]$H) New-Object System.Drawing.Size($W, $H) }

    $form = New-Object System.Windows.Forms.Form
    $form.SuspendLayout()
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Text = 'Windows 11 Language Installer'
    $form.ClientSize = & $size 680 604
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Font = $fontMain

    $header = New-Object System.Windows.Forms.Panel
    $header.Location = & $point 0 0
    $header.Size = & $size 680 72
    $form.Controls.Add($header)
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Windows 11 Language Installer'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
    $title.Location = & $point 18 10
    $title.AutoSize = $true
    $header.Controls.Add($title)
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Install a language from the language repository, or uninstall one.'
    $subtitle.Font = $fontHint
    $subtitle.Location = & $point 20 44
    $subtitle.AutoSize = $true
    $header.Controls.Add($subtitle)
    $buttonTheme = New-Object System.Windows.Forms.Button
    $buttonTheme.Name = 'Theme'
    $buttonTheme.Location = & $point 548 19
    $buttonTheme.Size = & $size 112 34
    $buttonTheme.Font = $fontHint
    $buttonTheme.FlatStyle = 'Flat'
    $header.Controls.Add($buttonTheme)
    $headerLine = New-Object System.Windows.Forms.Panel
    $headerLine.Location = & $point 0 72
    $headerLine.Size = & $size 680 1
    $form.Controls.Add($headerLine)

    $labelLanguage = New-Object System.Windows.Forms.Label
    $labelLanguage.Text = 'Language'
    $labelLanguage.Location = & $point 18 88
    $labelLanguage.AutoSize = $true
    $form.Controls.Add($labelLanguage)

    $comboLanguage = New-Object System.Windows.Forms.ComboBox
    $comboLanguage.Name = 'LanguageList'
    $comboLanguage.DropDownStyle = 'DropDownList'
    $comboLanguage.Location = & $point 20 114
    $comboLanguage.Size = & $size 640 30
    $comboLanguage.MaxDropDownItems = 20
    $comboLanguage.FlatStyle = 'Flat'   # a themed (non-flat) drop-down list ignores BackColor, so it would stay white
    $form.Controls.Add($comboLanguage)
    $formatItem = {
        param($Entry)
        $text = '{0} - {1}  ({2})' -f $Entry.DisplayName, $Entry.NativeName, $Entry.Tag
        if ($Entry.Type -eq 'Partial') { $text += '  [partial]' }
        if ($Entry.Type -eq 'Features') { $text += '  [features only]' }
        if ($Entry.Installed) { $text += '  [installed]' }
        return $text
    }
    foreach ($entry in $Languages) { [void]$comboLanguage.Items.Add((& $formatItem $entry)) }
    $comboLanguage.SelectedIndex = 0
    if ($Preselect) {
        for ($i = 0; $i -lt $Languages.Count; $i++) {
            if ($Languages[$i].Tag -eq $Preselect) { $comboLanguage.SelectedIndex = $i; break }
        }
    }

    $checkDisplay = New-Object System.Windows.Forms.CheckBox
    $checkDisplay.Name = 'DisplayLanguage'
    $checkDisplay.Text = 'Set as display language'
    $checkDisplay.Location = & $point 20 160
    $checkDisplay.AutoSize = $true
    $checkDisplay.Checked = [bool]$BaseParameters['SetDisplayLanguage']
    $form.Controls.Add($checkDisplay)

    $labelDisplay = New-Object System.Windows.Forms.Label
    $labelDisplay.Text = 'Applies to the signed-in user, the Welcome screen and new user accounts. Takes effect after sign-out or restart.'
    $labelDisplay.Location = & $point 42 190
    $labelDisplay.Size = & $size 618 42
    $labelDisplay.Font = $fontHint
    $form.Controls.Add($labelDisplay)

    $checkRegional = New-Object System.Windows.Forms.CheckBox
    $checkRegional.Name = 'RegionalFormat'
    $checkRegional.Text = 'Also set regional format and country/region'
    $checkRegional.Location = & $point 40 236
    $checkRegional.AutoSize = $true
    $checkRegional.Checked = [bool]$BaseParameters['SetRegionalFormat']
    $checkRegional.Enabled = $checkDisplay.Checked
    $form.Controls.Add($checkRegional)

    # Shown when the selected language is installed (TODO item 1, 2026-10-04): uninstall it instead of installing.
    $checkUninstall = New-Object System.Windows.Forms.CheckBox
    $checkUninstall.Name = 'Uninstall'
    $checkUninstall.Text = 'Uninstall this language'
    $checkUninstall.Location = & $point 20 278
    $checkUninstall.AutoSize = $true
    $checkUninstall.Visible = $false
    $form.Controls.Add($checkUninstall)

    $labelUninstall = New-Object System.Windows.Forms.Label
    $labelUninstall.Name = 'UninstallReason'
    $labelUninstall.Location = & $point 240 281
    $labelUninstall.Size = & $size 420 24
    $labelUninstall.Font = $fontHint
    $form.Controls.Add($labelUninstall)

    $textLog = New-Object System.Windows.Forms.TextBox
    $textLog.Name = 'Log'
    $textLog.Multiline = $true
    $textLog.ReadOnly = $true
    $textLog.ScrollBars = 'Vertical'
    $textLog.WordWrap = $true
    $textLog.Location = & $point 20 318
    $textLog.Size = & $size 640 206
    $textLog.Font = New-Object System.Drawing.Font('Consolas', 10.5)
    $textLog.BorderStyle = 'FixedSingle'
    $form.Controls.Add($textLog)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = & $point 20 534
    $progress.Size = & $size 640 10
    $progress.Style = 'Blocks'
    $form.Controls.Add($progress)

    $buttonInstall = New-Object System.Windows.Forms.Button
    $buttonInstall.Name = 'Install'
    $buttonInstall.Text = 'Install'
    $buttonInstall.Location = & $point 432 556
    $buttonInstall.Size = & $size 110 36
    $buttonInstall.Font = $fontButton
    $buttonInstall.FlatStyle = 'Flat'
    $buttonInstall.FlatAppearance.BorderSize = 0
    $buttonInstall.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($buttonInstall)
    $form.AcceptButton = $buttonInstall
    # A disabled flat button keeps its blue with grey text, which is hard to read: grey while busy instead.
    $buttonInstall.Add_EnabledChanged({ $buttonInstall.BackColor = $(if ($buttonInstall.Enabled) { $themes[$state.Theme].Accent } else { $themes[$state.Theme].Disabled }) })

    $buttonClose = New-Object System.Windows.Forms.Button
    $buttonClose.Name = 'Close'
    $buttonClose.Text = 'Close'
    $buttonClose.Location = & $point 550 556
    $buttonClose.Size = & $size 110 36
    $buttonClose.Font = $fontMain
    $buttonClose.FlatStyle = 'Flat'
    $buttonClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($buttonClose)
    $form.CancelButton = $buttonClose

    $setNativeTheme = {
        # the title bar and the log's scroll bar are drawn by Windows, not by the form's colours
        if (-not ('LanguagePackInstaller.Theme' -as [type])) { return }
        $dark = [int]($state.Theme -eq 'Dark')
        try {
            if ($form.IsHandleCreated) { [void][LanguagePackInstaller.Theme]::DwmSetWindowAttribute($form.Handle, 20, [ref]$dark, 4) }
            if ($textLog.IsHandleCreated) {
                [void][LanguagePackInstaller.Theme]::SetWindowTheme($textLog.Handle, $(if ($dark) { 'DarkMode_Explorer' } else { 'Explorer' }), [NullString]::Value)
                $textLog.Invalidate()
            }
        }
        catch { }
    }
    $applyTheme = {
        param([string]$Name)
        $state.Theme = $Name
        $c = $themes[$Name]
        $form.BackColor = $c.Back
        $form.ForeColor = $c.Text
        $header.BackColor = $c.Panel
        $title.ForeColor = $c.Text
        $subtitle.ForeColor = $c.Hint
        $headerLine.BackColor = $c.Line
        $labelDisplay.ForeColor = $c.Hint
        $labelUninstall.ForeColor = $c.Hint
        foreach ($field in $comboLanguage, $textLog) { $field.BackColor = $c.Panel; $field.ForeColor = $c.Text }
        $buttonInstall.FlatAppearance.MouseOverBackColor = $c.AccentDown
        $buttonInstall.FlatAppearance.MouseDownBackColor = $c.AccentDown
        $buttonInstall.BackColor = $(if ($buttonInstall.Enabled) { $c.Accent } else { $c.Disabled })
        foreach ($button in $buttonClose, $buttonTheme) {
            $button.FlatAppearance.BorderColor = $c.Border
            $button.FlatAppearance.MouseOverBackColor = $c.Hover
            $button.FlatAppearance.MouseDownBackColor = $c.Hover
            $button.BackColor = $c.Panel
            $button.ForeColor = $c.Text
        }
        $buttonTheme.Text = $(if ($Name -eq 'Dark') { 'Light theme' } else { 'Dark theme' })
        & $setNativeTheme
    }
    # A greyed-out check box draws embossed text that is hard to read on a dark background: redraw it in plain grey.
    $paintDisabled = {
        param($sender, $e)
        if ($sender.Enabled -or $state.Theme -ne 'Dark') { return }
        $glyph = [System.Windows.Forms.CheckBoxRenderer]::GetGlyphSize($e.Graphics, [System.Windows.Forms.VisualStyles.CheckBoxState]::UncheckedDisabled).Width
        $x = $glyph + [int][Math]::Round(3 * $e.Graphics.DpiX / 96)
        $rect = New-Object System.Drawing.Rectangle($x, 0, ($sender.Width - $x), $sender.Height)
        $brush = New-Object System.Drawing.SolidBrush($sender.BackColor)
        $e.Graphics.FillRectangle($brush, $rect)
        $brush.Dispose()
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.Text, $sender.Font, $rect, $themes.Dark.DisabledText, [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine, NoPadding')
    }
    foreach ($check in $checkDisplay, $checkRegional, $checkUninstall) { $check.Add_Paint($paintDisabled) }
    & $applyTheme $state.Theme
    $form.Add_HandleCreated({ & $setNativeTheme })
    $textLog.Add_HandleCreated({ & $setNativeTheme })
    $buttonTheme.Add_Click({ & $applyTheme $(if ($state.Theme -eq 'Dark') { 'Light' } else { 'Dark' }) })
    $form.ResumeLayout($false)
    $form.PerformLayout()

    $setBusy = {
        param([bool]$Busy)
        $state.Running = $Busy
        $comboLanguage.Enabled = -not $Busy
        if ($Busy) { $checkDisplay.Enabled = $false; $checkRegional.Enabled = $false }   # back to the language's state by $applyMode
        $buttonInstall.Enabled = -not $Busy
        $buttonClose.Enabled = -not $Busy
        $checkUninstall.Enabled = -not $Busy
        if ($Busy) { $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30 }
        else { $progress.Style = 'Blocks'; $progress.MarqueeAnimationSpeed = 0; & $updateUninstall }
    }

    # Install or uninstall mode: with "Uninstall this language" ticked the install options do not apply.
    # A feature-only language (no language pack) cannot be the display language either.
    $displayHint = $labelDisplay.Text
    $featuresHint = 'No language pack: Windows cannot be shown in this language. Adds its spelling, typing and speech features; users then add the language in Settings.'
    $applyMode = {
        if ($state.Running) { return }
        $uninstalling = $checkUninstall.Visible -and $checkUninstall.Checked
        $featuresOnly = ($comboLanguage.SelectedIndex -ge 0) -and $Languages[$comboLanguage.SelectedIndex].Type -eq 'Features'
        $buttonInstall.Text = $(if ($uninstalling) { 'Uninstall' } else { 'Install' })
        $checkDisplay.Enabled = -not ($uninstalling -or $featuresOnly)
        $checkRegional.Enabled = $checkDisplay.Enabled -and $checkDisplay.Checked
        $labelDisplay.Text = $(if ($featuresOnly) { $featuresHint } else { $displayHint })
    }

    # The uninstall check box follows the selected language: shown for an installed language, greyed out for the
    # language Windows was installed with.
    $updateUninstall = {
        $entry = $null
        if ($comboLanguage.SelectedIndex -ge 0) { $entry = $Languages[$comboLanguage.SelectedIndex] }
        $state.Confirming = $true
        if ($entry -and $entry.Installed) {
            $checkUninstall.Visible = $true
            if ($InstallLanguage -and $entry.Tag -eq $InstallLanguage) {
                $checkUninstall.Checked = $false
                $checkUninstall.Enabled = $false
                $labelUninstall.Text = 'Windows was installed with this language; it cannot be removed.'
            }
            else {
                $checkUninstall.Enabled = -not $state.Running
                $labelUninstall.Text = ''
            }
        }
        else {
            $checkUninstall.Checked = $false
            $checkUninstall.Visible = $false
            $labelUninstall.Text = ''
        }
        $state.Confirming = $false
        & $applyMode
    }

    $drainQueue = {
        $line = $null
        while ($queue.TryDequeue([ref]$line)) { $textLog.AppendText($line + [Environment]::NewLine) }
    }

    $checkDisplay.Add_CheckedChanged({
            $checkRegional.Enabled = $checkDisplay.Checked
            if (-not $checkDisplay.Checked) { $checkRegional.Checked = $false }
        })

    $comboLanguage.Add_SelectedIndexChanged({ & $updateUninstall })

    # Ticking "Uninstall this language" asks first: a restart is required (and a display language is reset first).
    $checkUninstall.Add_CheckedChanged({
            if ($state.Confirming) { return }
            if ($checkUninstall.Checked) {
                $entry = $Languages[$comboLanguage.SelectedIndex]
                $isDisplay = $false
                try { $isDisplay = Test-LpiDisplayLanguage -Language $entry.Tag } catch { }
                if (-not (Confirm-UninstallChoice -Owner $form -Entry $entry -IsDisplayLanguage $isDisplay -DefaultLanguage $InstallLanguage)) {
                    $state.Confirming = $true
                    $checkUninstall.Checked = $false
                    $state.Confirming = $false
                }
            }
            & $applyMode
        })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
            & $drainQueue
            if (-not ($state.Handle -and $state.Handle.IsCompleted)) { return }
            $timer.Stop()

            $result = $null
            try {
                $result = $state.PowerShell.EndInvoke($state.Handle) | Select-Object -Last 1
                foreach ($errorRecord in $state.PowerShell.Streams.Error) {
                    $textLog.AppendText("ERROR: $errorRecord" + [Environment]::NewLine)
                }
            }
            catch {
                $textLog.AppendText("ERROR: $($_.Exception.Message)" + [Environment]::NewLine)
            }
            finally {
                $state.PowerShell.Runspace.Dispose()
                $state.PowerShell.Dispose()
                $state.PowerShell = $null
                $state.Handle = $null
            }
            & $drainQueue

            $code = $ExitFailure
            if ($result -and $result.PSObject.Properties['ExitCode']) { $code = [int]$result.ExitCode }
            # Overall exit code: any failure wins, then a pending restart, then success.
            if ($state.ExitCode -ne $ExitFailure) {
                if ($code -eq $ExitFailure -or $code -eq 3010 -or $null -eq $state.ExitCode) { $state.ExitCode = $code }
            }

            & $setBusy $false
            $progress.Value = 0
            if ($code -ne $ExitFailure) {
                $progress.Value = 100
                $entry = $Languages[$state.Index]
                if ($state.Mode -eq 'Uninstall') {
                    # "is removed after the restart": still installed until then, so keep it marked installed
                    if ("$($result.Message)" -notlike '*removed after the restart*') { $entry.Installed = $false }
                }
                else { $entry.Installed = $true }
                $comboLanguage.Items[$state.Index] = (& $formatItem $entry)
                & $updateUninstall
                $text = $result.Message
                if ($code -eq 3010) { $text += [Environment]::NewLine + [Environment]::NewLine + 'A restart is required to finish.' }
                [void][System.Windows.Forms.MessageBox]::Show($form, $text, $form.Text, 'OK', 'Information')
            }
            else {
                $text = $(if ($state.Mode -eq 'Uninstall') { 'The uninstall failed.' } else { 'The installation failed.' })
                if ($result -and $result.Message) { $text += [Environment]::NewLine + [Environment]::NewLine + $result.Message }
                $text += [Environment]::NewLine + [Environment]::NewLine + "Log: $(Join-Path $BaseParameters['LogPath'] 'LanguagePackInstaller.log')"
                [void][System.Windows.Forms.MessageBox]::Show($form, $text, $form.Text, 'OK', 'Error')
            }
        })

    $buttonInstall.Add_Click({
            if ($state.Running -or $comboLanguage.SelectedIndex -lt 0) { return }
            $state.Index = $comboLanguage.SelectedIndex
            $entry = $Languages[$state.Index]

            if ($checkUninstall.Visible -and $checkUninstall.Checked) {
                $state.Mode = 'Uninstall'
                $parameters = @{ Language = $entry.Tag; ResetDisplayLanguage = $true; UserScriptPath = $BaseParameters['UserScriptPath'] }
                $verb = 'Uninstalling'
            }
            else {
                $state.Mode = 'Install'
                $parameters = $BaseParameters.Clone()
                $parameters['Language'] = $entry.Tag
                $display = $checkDisplay.Checked -and $entry.Type -ne 'Features'
                $parameters['SetDisplayLanguage'] = $display
                $parameters['SetRegionalFormat'] = $display -and $checkRegional.Checked
                $verb = 'Installing'
            }

            & $setBusy $true
            $textLog.AppendText("$verb $($entry.DisplayName) ($($entry.Tag))..." + [Environment]::NewLine)

            # Run the install in a background runspace so the window stays responsive.
            $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $sessionState.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($sessionState)
            $runspace.Open()
            $worker = [System.Management.Automation.PowerShell]::Create()
            $worker.Runspace = $runspace
            [void]$worker.AddScript({
                    param($ModulePath, $Queue, $Parameters, $LogPath, $Mode)
                    $ErrorActionPreference = 'Stop'
                    Import-Module -Name $ModulePath -Force
                    Initialize-LpiLog -Path $LogPath -Queue $Queue
                    if ($Mode -eq 'Uninstall') { Uninstall-LpiLanguage @Parameters } else { Invoke-LpiInstall @Parameters }
                })
            [void]$worker.AddArgument($ModulePath).AddArgument($queue).AddArgument($parameters).AddArgument($BaseParameters['LogPath']).AddArgument($state.Mode)
            $state.PowerShell = $worker
            $state.Handle = $worker.BeginInvoke()
            $timer.Start()
        })

    $form.Add_FormClosing({
            param($sender, $eventArgs)
            if ($state.Running) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'An installation or uninstall is in progress. Wait for it to finish before closing.', $form.Text, 'OK', 'Warning')
                $eventArgs.Cancel = $true
            }
        })

    & $updateUninstall   # for the preselected language
    [void]$form.ShowDialog()
    $timer.Dispose()
    $form.Dispose()

    if ($null -eq $state.ExitCode) { return $ExitCancelled }
    return $state.ExitCode
}

#endregion

# Before any window (the problem message box below, or the form): sharp text on high-resolution screens.
if (-not $Silent) { Enable-DpiAwareness }

$problems = @(Test-LpiPrerequisite -Repository $Repository -UserScriptPath $UserScriptPath)
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-LpiLog -Level Error -Message $problem }
    if (-not $Silent) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(($problems -join [Environment]::NewLine), 'Windows 11 Language Installer', 'OK', 'Error')
    }
    exit $ExitFailure
}

$baseParameters = @{
    Repository           = $Repository
    UserScriptPath       = $UserScriptPath
    LogPath              = $LogPath
    SetDisplayLanguage   = [bool]$SetDisplayLanguage
    SetRegionalFormat    = [bool]$SetRegionalFormat
    SetSystemLocale      = [bool]$SetSystemLocale
    ApplyToExistingUsers = [bool]$ApplyToExistingUsers
    AllowLanguageCleanup = [bool]$AllowLanguageCleanup
}

if ($Silent) {
    if (-not $Language) {
        Write-LpiLog -Level Error -Message '-Language is required with -Silent.'
        exit $ExitFailure
    }
    $result = Invoke-LpiInstall @baseParameters -Language $Language
    exit $result.ExitCode
}

Write-LpiLog -Message 'Reading the language repository and the installed languages...'
$languages = @(Get-LpiRepositoryLanguage -Repository $Repository)
$preselect = $null
if ($Language) { $preselect = ConvertTo-LpiLanguageTag -Language $Language }
$exitCode = Show-InstallerForm -Languages $languages -BaseParameters $baseParameters -Preselect $preselect -InstallLanguage (Get-LpiInstallLanguageTag) -Theme $(if ($LightTheme) { 'Light' } else { 'Dark' }) | Select-Object -Last 1
Write-LpiLog -Message "===== Windows 11 Language Installer finished with exit code $exitCode ====="
exit $exitCode
