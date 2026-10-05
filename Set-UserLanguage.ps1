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

.PARAMETER RemoveLanguage
    A language being uninstalled: taken out of the account's language list (with its keyboards). Used when the
    display language is set back to the default before that language is removed.

.PARAMETER OnlyUsers
    Comma-separated SIDs. When given, the script does nothing for any other account (it exits 0, so Active Setup
    counts it as done). Install-LanguagePack.ps1 uses it to apply the language again after the restart, at the next
    sign-in, to the users who were signed in during the install - not to every user of the device.

.PARAMETER LogDirectory
    Folder for the per-user log (User-<username>.log). Defaults to %TEMP%.

.EXAMPLE
    .\Set-UserLanguage.ps1 -Language fr-FR -SetRegionalFormat
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Language,
    [switch]$SetRegionalFormat,
    [string]$RemoveLanguage,
    [string]$OnlyUsers,
    [string]$LogDirectory = $env:TEMP
)

$ErrorActionPreference = 'Stop'

if ($OnlyUsers -and (@($OnlyUsers -split '[,;\s]+') -notcontains [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
    exit 0   # not one of the users this run is for
}

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

    $override = $null
    try { $override = Get-WinUILanguageOverride } catch { }
    $list = Get-WinUserLanguageList
    Write-UserLog "Before: language list $(($list | ForEach-Object { $_.LanguageTag }) -join ', '); display language override $(if ($override) { $override } else { '(none)' })."

    # Put the language first in the user's language list. Keep an existing entry (and its keyboards) if there is one;
    # every other language stays in the list. Windows keeps some languages under its own tag - 'cs' for cs-CZ, 'ja'
    # for ja-JP (seen on Windows 11 25H2, 2026-10-04) - so an entry whose specific culture is this language counts too,
    # instead of adding a second entry next to it.
    $sameLanguage = {
        param($Tag)
        if ($Tag -eq $Language) { return $true }
        try { return ([Globalization.CultureInfo]::CreateSpecificCulture($Tag).Name -eq $Language) } catch { return $false }
    }
    $entry = $list | Where-Object { $_.LanguageTag -eq $Language } | Select-Object -First 1
    if (-not $entry) { $entry = $list | Where-Object { & $sameLanguage $_.LanguageTag } | Select-Object -First 1 }
    if ($entry) {
        [void]$list.Remove($entry)
    }
    else {
        $entry = (New-WinUserLanguageList -Language $Language)[0]
    }
    $list.Insert(0, $entry)
    if ($RemoveLanguage) {
        $RemoveLanguage = [Globalization.CultureInfo]::GetCultureInfo($RemoveLanguage).Name
        # also Windows' own tag for it ('ja' for ja-JP), never the language being set
        $removeTag = $RemoveLanguage
        $isRemoved = {
            param($Tag)
            if ($Tag -eq $removeTag) { return $true }
            try { return ([Globalization.CultureInfo]::CreateSpecificCulture($Tag).Name -eq $removeTag) } catch { return $false }
        }
        foreach ($old in @($list | Where-Object { (& $isRemoved $_.LanguageTag) -and -not [object]::ReferenceEquals($_, $entry) })) {
            [void]$list.Remove($old)
            Write-UserLog "Removed $($old.LanguageTag) from the language list ($RemoveLanguage is being uninstalled)."
        }
    }
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
