#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Language Installer: removes a language installed with Install-LanguagePack.ps1.

.DESCRIPTION
    Removes the language's features and font, its satellite packages for installed Features on Demand, and its
    language pack, then this installer's registry entries for it. The uninstall command of a ConfigMgr application.

    It refuses (exit code 1603) to remove:
      - the language Windows was installed with
      - the system display language, or the display language this installer set - unless -ResetDisplayLanguage,
        which first sets the display language back to the language Windows was installed with
    A script font is kept while another installed language uses it. The BlockCleanupOfUnusedPreinstalledLangPacks
    policy is removed only if this installer set it and no language it installed is left (-KeepCleanupPolicy keeps
    it). A language that is not installed is a success, so the uninstall can run again.

    Per-user language lists are not changed: a user who added the language keeps the entry until they remove it
    in Settings > Time & language.

.PARAMETER Language
    Language tag to remove, for example de-DE.

.PARAMETER KeepCleanupPolicy
    Keep BlockCleanupOfUnusedPreinstalledLangPacks even when no language installed by this installer is left.

.PARAMETER ResetDisplayLanguage
    If the language is the display language, set the display language back to the language Windows was installed
    with (system, Welcome screen, new users, signed-in users, and other users through Active Setup if it was set up),
    then uninstall it. If Windows will not remove the language pack before the restart, a startup task finishes the
    uninstall after it (exit code 3010).

.PARAMETER FromStartupTask
    Used by that startup task: when the uninstall succeeds, the task removes itself.

.PARAMETER LogPath
    Log folder. Defaults to %windir%\Logs\LanguagePackInstaller (the installer's log file is shared).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-LanguagePack.ps1 -Language de-DE

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-LanguagePack.ps1 -Language de-DE -ResetDisplayLanguage

.NOTES
    Exit codes: 0 success (also when the language was not installed), 3010 success but restart needed,
    1603 failure or refused.
    Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Language,
    [switch]$KeepCleanupPolicy,
    [switch]$ResetDisplayLanguage,
    [switch]$FromStartupTask,
    [string]$LogPath = (Join-Path -Path $env:windir -ChildPath 'Logs\LanguagePackInstaller')
)

$ErrorActionPreference = 'Stop'
$ExitFailure = 1603
$BoundParameters = $PSBoundParameters

# This script's folder. $PSScriptRoot was empty under a ConfigMgr deployment (2026-10-04), so fall back to the script's
# own path, then to the current directory (ConfigMgr starts a program in its content folder).
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot -and $MyInvocation.MyCommand.Path) { $ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location -PSProvider FileSystem).ProviderPath }
$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = Join-Path -Path $ScriptRoot -ChildPath 'Uninstall-LanguagePack.ps1' }

function Get-RelaunchArgument {
    <# Rebuilds this script's command line for a 64-bit relaunch. #>
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
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

Import-Module -Name (Join-Path -Path $ScriptRoot -ChildPath 'LanguagePackInstaller.psm1') -Force
# No administrator check: the script runs as SYSTEM from a ConfigMgr application deployment.

Initialize-LpiLog -Path $LogPath
Write-LpiLog -Message "===== Windows 11 Language Uninstaller started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) ====="

Write-LpiLog -Message "Script folder: $ScriptRoot$(if (-not $PSScriptRoot) { ' (PSScriptRoot was empty)' })."
$userScriptPath = Join-Path -Path $ScriptRoot -ChildPath 'Set-UserLanguage.ps1'
$result = Uninstall-LpiLanguage -Language $Language -KeepCleanupPolicy:$KeepCleanupPolicy -ResetDisplayLanguage:$ResetDisplayLanguage -UserScriptPath $userScriptPath
if ($FromStartupTask -and $result.ExitCode -ne 1603) {
    # The uninstall that finishes after the restart is done: remove its one-shot startup task (it retries otherwise).
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    Unregister-ScheduledTask -TaskName "LanguagePackInstaller-CompleteUninstall-$tag" -Confirm:$false -ErrorAction SilentlyContinue
    Write-LpiLog -Message "Removed the startup task LanguagePackInstaller-CompleteUninstall-$tag."
}
Write-LpiLog -Message "===== Windows 11 Language Uninstaller finished: exit code $($result.ExitCode) ====="
exit $result.ExitCode
