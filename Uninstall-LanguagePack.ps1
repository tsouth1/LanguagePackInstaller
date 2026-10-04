#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Language Installer: removes a language installed with Install-LanguagePack.ps1.

.DESCRIPTION
    Removes the language's features and font, its satellite packages for installed Features on Demand, and its
    language pack, then this installer's registry entries for it. The uninstall command of a ConfigMgr application.

    It refuses (exit code 1603) to remove:
      - the system display language, or the display language this installer set (set another one first)
      - the language Windows was installed with
    A script font is kept while another installed language uses it. The BlockCleanupOfUnusedPreinstalledLangPacks
    policy is removed only if this installer set it and no language it installed is left (-KeepCleanupPolicy keeps
    it). A language that is not installed is a success, so the uninstall can run again.

    Per-user language lists are not changed: a user who added the language keeps the entry until they remove it
    in Settings > Time & language.

.PARAMETER Language
    Language tag to remove, for example de-DE.

.PARAMETER KeepCleanupPolicy
    Keep BlockCleanupOfUnusedPreinstalledLangPacks even when no language installed by this installer is left.

.PARAMETER LogPath
    Log folder. Defaults to %windir%\Logs\LanguagePackInstaller (the installer's log file is shared).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-LanguagePack.ps1 -Language de-DE

.NOTES
    Exit codes: 0 success (also when the language was not installed), 3010 success but restart needed,
    1603 failure or refused.
    Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Language,
    [switch]$KeepCleanupPolicy,
    [string]$LogPath = (Join-Path -Path $env:windir -ChildPath 'Logs\LanguagePackInstaller')
)

$ErrorActionPreference = 'Stop'
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

if (-not (Test-LpiAdministrator)) {
    # -ErrorAction Continue: under ErrorActionPreference Stop, Write-Error would end the script with exit code 1, not 1603.
    Write-Error 'The uninstaller must run elevated (administrator or SYSTEM).' -ErrorAction Continue
    exit $ExitFailure
}

Initialize-LpiLog -Path $LogPath
Write-LpiLog -Message "===== Windows 11 Language Uninstaller started as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) ====="

$result = Uninstall-LpiLanguage -Language $Language -KeepCleanupPolicy:$KeepCleanupPolicy
Write-LpiLog -Message "===== Windows 11 Language Uninstaller finished: exit code $($result.ExitCode) ====="
exit $result.ExitCode
