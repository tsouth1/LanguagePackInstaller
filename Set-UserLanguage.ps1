#Requires -Version 5.1
<#
.SYNOPSIS
    Applies a display language to the account that runs this script (HKCU only).

.DESCRIPTION
    The International cmdlets used here have no -User parameter: they always change the
    current account's hive. Install-LanguagePack.ps1 therefore runs this script:
      - as the running account (SYSTEM under ConfigMgr), before copying the settings to the
        Welcome screen and new users;
      - as each signed-in user, through a one-shot scheduled task;
      - optionally as every other existing user at next sign-in, through Active Setup.

    The language must already be installed. Changes take effect at the next sign-in.

.PARAMETER Language
    Language tag, for example de-DE.

.PARAMETER SetRegionalFormat
    Also set the regional format (dates, numbers, currency) and the country or region.

.PARAMETER LogDirectory
    Folder for the per-user log (User-<username>.log). Defaults to %TEMP%.

.EXAMPLE
    .\Set-UserLanguage.ps1 -Language fr-FR -SetRegionalFormat
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Language,
    [switch]$SetRegionalFormat,
    [string]$LogDirectory = $env:TEMP
)

$ErrorActionPreference = 'Stop'

$logFile = $null
try {
    if (-not (Test-Path -LiteralPath $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path -Path $LogDirectory -ChildPath "User-$env:USERNAME.log"
}
catch { }

function Write-UserLog {
    param([string]$Message, [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info')
    $now = Get-Date
    $type = @{ Info = 1; Warning = 2; Error = 3 }[$Level]
    $bias = -[int][TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $line = '<![LOG[{0}]LOG]!><time="{1}{2:+0;-0;+0}" date="{3}" component="Set-UserLanguage" context="{4}" type="{5}" thread="{6}" file="">' -f `
        $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'),
        [Security.Principal.WindowsIdentity]::GetCurrent().Name, $type, $PID
    if ($logFile) { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue }
    Write-Output $Message
}

try {
    $Language = [Globalization.CultureInfo]::GetCultureInfo($Language).Name
    Write-UserLog "Applying $Language for $([Security.Principal.WindowsIdentity]::GetCurrent().Name)."

    # Put the language first in the user's language list. Keep an existing entry (and its
    # keyboards) if there is one; every other language stays in the list.
    $list = Get-WinUserLanguageList
    $entry = $list | Where-Object { $_.LanguageTag -eq $Language } | Select-Object -First 1
    if ($entry) {
        [void]$list.Remove($entry)
    }
    else {
        $entry = (New-WinUserLanguageList -Language $Language)[0]
    }
    $list.Insert(0, $entry)
    Set-WinUserLanguageList -LanguageList $list -Force
    Write-UserLog "Language list is now: $(($list | ForEach-Object { $_.LanguageTag }) -join ', ')."

    Set-WinUILanguageOverride -Language $Language
    Write-UserLog "Display language override set to $Language."

    if ($SetRegionalFormat) {
        Set-Culture -CultureInfo $Language
        $region = New-Object Globalization.RegionInfo($Language)
        Set-WinHomeLocation -GeoId $region.GeoId
        Write-UserLog "Regional format set to $Language and country/region to $($region.EnglishName) (GeoId $($region.GeoId))."
    }

    Write-UserLog 'Done. The change takes effect at the next sign-in.'
    exit 0
}
catch {
    Write-UserLog -Level Error -Message "Failed: $($_.Exception.Message)"
    exit 1
}
