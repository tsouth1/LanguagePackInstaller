#Requires -Version 5.1
<#
.SYNOPSIS
    Finishes the system part of a display-language change after a restart.

.DESCRIPTION
    Install-LanguagePack.ps1 registers this script as a one-shot SYSTEM startup task when
    Windows refuses the system display-language settings straight after the language pack
    was added (typically "Value does not fall within the expected range" while the language
    pack is still pending a restart). It:
      1. applies the language to the SYSTEM account (Set-UserLanguage.ps1),
      2. sets the system preferred UI language,
      3. copies the settings to the Welcome screen and new user accounts,
    and removes its scheduled task once all three succeed. If a step still fails, the task
    stays and tries again at the next startup.

.PARAMETER Language
    Language tag, for example de-DE.

.PARAMETER SetRegionalFormat
    Also copy the regional format and country/region.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Language,
    [switch]$SetRegionalFormat
)

$ErrorActionPreference = 'Stop'
$taskName = 'LanguagePackInstaller-CompleteSystemLanguage'
$logDirectory = Join-Path -Path $env:windir -ChildPath 'Logs\LanguagePackInstaller'
if (-not (Test-Path -LiteralPath $logDirectory)) { New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null }
$logFile = Join-Path -Path $logDirectory -ChildPath 'LanguagePackInstaller.log'

function Write-CompleteLog {
    param([string]$Message, [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info')
    $now = Get-Date
    $type = @{ Info = 1; Warning = 2; Error = 3 }[$Level]
    $bias = -[int][TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $line = '<![LOG[{0}]LOG]!><time="{1}{2:+0;-0;+0}" date="{3}" component="Complete-SystemLanguage" context="{4}" type="{5}" thread="{6}" file="">' -f `
        $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'),
        [Security.Principal.WindowsIdentity]::GetCurrent().Name, $type, $PID
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

try {
    $Language = [Globalization.CultureInfo]::GetCultureInfo($Language).Name
    Write-CompleteLog "Finishing the system display language $Language after restart."

    $userScript = Join-Path -Path $PSScriptRoot -ChildPath 'Set-UserLanguage.ps1'
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$userScript`" -Language $Language -LogDirectory `"$(Join-Path $PSScriptRoot 'Logs')`""
    if ($SetRegionalFormat) { $arguments += ' -SetRegionalFormat' }
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "Applying $Language to the SYSTEM account failed (exit code $($process.ExitCode))." }

    Set-SystemPreferredUILanguage -Language $Language
    Write-CompleteLog "System preferred UI language set to $Language."

    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
    Write-CompleteLog 'Copied the language settings to the Welcome screen and new user accounts.'

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-CompleteLog 'Done; removed the startup task. Restart once more for the Welcome screen to show the new language.'
    exit 0
}
catch {
    Write-CompleteLog -Level Error -Message "Failed: $($_.Exception.Message). The task will try again at the next startup."
    exit 1
}
