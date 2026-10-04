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
    New-LanguageRepository.ps1. Defaults to the 'Repository' folder next to this script.

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

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'LanguagePackInstaller.psm1') -Force
# No administrator check: the script runs as SYSTEM from a ConfigMgr application deployment.

$UserScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-UserLanguage.ps1'
$ModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'LanguagePackInstaller.psm1'

Initialize-LpiLog -Path $LogPath
Write-LpiLog -Message "===== Windows 11 Language Installer started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) (silent: $([bool]$Silent)) ====="

#region GUI

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
        [string]$InstallLanguage
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $state = @{ PowerShell = $null; Handle = $null; ExitCode = $null; Running = $false; Index = -1; Mode = $null; Confirming = $false }
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Windows 11 Language Installer'
    $form.ClientSize = New-Object System.Drawing.Size(560, 470)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $labelLanguage = New-Object System.Windows.Forms.Label
    $labelLanguage.Text = 'Language:'
    $labelLanguage.Location = New-Object System.Drawing.Point(12, 14)
    $labelLanguage.AutoSize = $true
    $form.Controls.Add($labelLanguage)

    $comboLanguage = New-Object System.Windows.Forms.ComboBox
    $comboLanguage.DropDownStyle = 'DropDownList'
    $comboLanguage.Location = New-Object System.Drawing.Point(12, 34)
    $comboLanguage.Size = New-Object System.Drawing.Size(536, 24)
    $comboLanguage.MaxDropDownItems = 20
    $form.Controls.Add($comboLanguage)

    $formatItem = {
        param($Entry)
        $text = '{0} - {1}  ({2})' -f $Entry.DisplayName, $Entry.NativeName, $Entry.Tag
        if ($Entry.Type -eq 'Partial') { $text += '  [partial]' }
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
    $checkDisplay.Text = 'Set as display language'
    $checkDisplay.Location = New-Object System.Drawing.Point(12, 70)
    $checkDisplay.AutoSize = $true
    $checkDisplay.Checked = [bool]$BaseParameters['SetDisplayLanguage']
    $form.Controls.Add($checkDisplay)

    $labelDisplay = New-Object System.Windows.Forms.Label
    $labelDisplay.Text = 'Applies to the signed-in user, the Welcome screen and new user accounts. Takes effect after sign-out or restart.'
    $labelDisplay.Location = New-Object System.Drawing.Point(30, 92)
    $labelDisplay.Size = New-Object System.Drawing.Size(518, 32)
    $labelDisplay.ForeColor = [System.Drawing.SystemColors]::GrayText
    $form.Controls.Add($labelDisplay)

    $checkRegional = New-Object System.Windows.Forms.CheckBox
    $checkRegional.Text = 'Also set regional format and country/region'
    $checkRegional.Location = New-Object System.Drawing.Point(30, 126)
    $checkRegional.AutoSize = $true
    $checkRegional.Checked = [bool]$BaseParameters['SetRegionalFormat']
    $checkRegional.Enabled = $checkDisplay.Checked
    $form.Controls.Add($checkRegional)

    # Shown when the selected language is installed (TODO item 1, 2026-10-04): uninstall it instead of installing.
    $checkUninstall = New-Object System.Windows.Forms.CheckBox
    $checkUninstall.Text = 'Uninstall this language'
    $checkUninstall.Location = New-Object System.Drawing.Point(12, 156)
    $checkUninstall.AutoSize = $true
    $checkUninstall.Visible = $false
    $form.Controls.Add($checkUninstall)

    $labelUninstall = New-Object System.Windows.Forms.Label
    $labelUninstall.Location = New-Object System.Drawing.Point(200, 158)
    $labelUninstall.Size = New-Object System.Drawing.Size(348, 20)
    $labelUninstall.ForeColor = [System.Drawing.SystemColors]::GrayText
    $form.Controls.Add($labelUninstall)

    $textLog = New-Object System.Windows.Forms.TextBox
    $textLog.Multiline = $true
    $textLog.ReadOnly = $true
    $textLog.ScrollBars = 'Vertical'
    $textLog.WordWrap = $true
    $textLog.Location = New-Object System.Drawing.Point(12, 188)
    $textLog.Size = New-Object System.Drawing.Size(536, 210)
    $textLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $textLog.BackColor = [System.Drawing.SystemColors]::Window
    $form.Controls.Add($textLog)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(12, 406)
    $progress.Size = New-Object System.Drawing.Size(536, 12)
    $progress.Style = 'Blocks'
    $form.Controls.Add($progress)

    $buttonInstall = New-Object System.Windows.Forms.Button
    $buttonInstall.Text = 'Install'
    $buttonInstall.Location = New-Object System.Drawing.Point(366, 432)
    $buttonInstall.Size = New-Object System.Drawing.Size(88, 28)
    $form.Controls.Add($buttonInstall)
    $form.AcceptButton = $buttonInstall

    $buttonClose = New-Object System.Windows.Forms.Button
    $buttonClose.Text = 'Close'
    $buttonClose.Location = New-Object System.Drawing.Point(460, 432)
    $buttonClose.Size = New-Object System.Drawing.Size(88, 28)
    $buttonClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($buttonClose)
    $form.CancelButton = $buttonClose

    $setBusy = {
        param([bool]$Busy)
        $state.Running = $Busy
        $comboLanguage.Enabled = -not $Busy
        $checkDisplay.Enabled = -not $Busy
        $checkRegional.Enabled = (-not $Busy) -and $checkDisplay.Checked
        $buttonInstall.Enabled = -not $Busy
        $buttonClose.Enabled = -not $Busy
        $checkUninstall.Enabled = -not $Busy
        if ($Busy) { $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30 }
        else { $progress.Style = 'Blocks'; $progress.MarqueeAnimationSpeed = 0; & $updateUninstall }
    }

    # Install or uninstall mode: with "Uninstall this language" ticked the install options do not apply.
    $applyMode = {
        if ($state.Running) { return }
        $uninstalling = $checkUninstall.Visible -and $checkUninstall.Checked
        $buttonInstall.Text = $(if ($uninstalling) { 'Uninstall' } else { 'Install' })
        $checkDisplay.Enabled = -not $uninstalling
        $checkRegional.Enabled = (-not $uninstalling) -and $checkDisplay.Checked
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
                $parameters['SetDisplayLanguage'] = $checkDisplay.Checked
                $parameters['SetRegionalFormat'] = $checkDisplay.Checked -and $checkRegional.Checked
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
$exitCode = Show-InstallerForm -Languages $languages -BaseParameters $baseParameters -Preselect $preselect -InstallLanguage (Get-LpiInstallLanguageTag) | Select-Object -Last 1
Write-LpiLog -Message "===== Windows 11 Language Installer finished with exit code $exitCode ====="
exit $exitCode
