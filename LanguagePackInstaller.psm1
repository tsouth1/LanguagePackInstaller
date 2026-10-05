#Requires -Version 5.1
<#
    LanguagePackInstaller core module.

    Installs a Windows 11 (24H2 and later) language from a local or UNC language
    repository with DISM, then applies the display-language settings with the
    LanguagePackManagement and International modules.

    System-wide work runs in the calling process (SYSTEM under ConfigMgr).
    Per-user work (HKCU) runs Set-UserLanguage.ps1 as each signed-in user through
    a one-shot scheduled task, because the International cmdlets only ever write
    the hive of the account that runs them.

    Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#>

Set-StrictMode -Version 2.0

#region Constants

# Order the language features are added in. Basic must come first; the others depend on it.
$script:FeatureOrder = @{
    'Basic'        = 1
    'OCR'          = 3
    'Handwriting'  = 4
    'TextToSpeech' = 5
    'Speech'       = 6
}

# Languages that need a script-specific font capability (Language.Fonts.<Script>).
$script:FontScripts = @{
    'ar-SA' = 'Arab'
    'he-IL' = 'Hebr'
    'ja-JP' = 'Jpan'
    'ko-KR' = 'Kore'
    'th-TH' = 'Thai'
    'zh-CN' = 'Hans'
    'zh-TW' = 'Hant'
    # Feature-only languages (no language pack), from the LOF metadata (DesktopTargetCompDB_Conditions: the font
    # Windows adds when a user's language is one of these).
    'am-ET' = 'Ethi'; 'ar-EG' = 'Arab'; 'as-IN' = 'Beng'; 'bn-BD' = 'Beng'; 'bn-IN' = 'Beng'; 'fa-IR' = 'Arab'
    'gu-IN' = 'Gujr'; 'hi-IN' = 'Deva'; 'km-KH' = 'Khmr'; 'kn-IN' = 'Knda'; 'lo-LA' = 'Laoo'; 'ml-IN' = 'Mlym'
    'mr-IN' = 'Deva'; 'ne-NP' = 'Deva'; 'or-IN' = 'Orya'; 'pa-Arab-PK' = 'Arab'; 'pa-IN' = 'Guru'; 'ps-AF' = 'Arab'
    'sd-Arab-PK' = 'Arab'; 'si-LK' = 'Sinh'; 'ta-IN' = 'Taml'; 'te-IN' = 'Telu'; 'ug-CN' = 'Arab'; 'ur-PK' = 'Arab'
    'zh-HK' = 'Hant'
}

# Names for the few repository tags Windows has no display name for.
$script:LanguageNames = @{
    'fj-FJ'       = 'Fijian (Fiji)'
    'kok-Deva-IN' = 'Konkani (Devanagari, India)'
    'sco-Latn'    = 'Scots'
}

# Partial (LIP) languages and the full languages Windows accepts as their base.
$script:LipParents = @{
    'ca-ES' = @('es-ES', 'fr-FR', 'en-US')
    'eu-ES' = @('es-ES', 'en-US')
    'gl-ES' = @('es-ES', 'en-US')
    'id-ID' = @('en-US')
    'vi-VN' = @('en-US')
}

$script:ExitSuccess = 0
$script:ExitReboot = 3010
$script:ExitFailure = 1603

$script:RegistryRoot = 'HKLM:\SOFTWARE\LanguagePackInstaller'
$script:UserDataRoot = Join-Path -Path $env:ProgramData -ChildPath 'LanguagePackInstaller'
$script:CleanupPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Control Panel\International'
$script:ActiveSetupKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\LanguagePackInstaller'

$script:LogFile = $null
$script:LogDirectory = $null
$script:LogQueue = $null
$script:PackageCache = $null

#endregion

#region Logging

function Initialize-LpiLog {
    <# Sets the log folder and, for the GUI, the queue that log lines are mirrored to. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
    $script:LogDirectory = $Path
    $script:LogFile = Join-Path -Path $Path -ChildPath 'LanguagePackInstaller.log'
    $script:LogQueue = $Queue
}

function Write-LpiLog {
    <# Writes a CMTrace-format line to the log file and echoes it to the GUI or console. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $now = Get-Date
    if ($script:LogFile) {
        $type = @{ Info = 1; Warning = 2; Error = 3 }[$Level]
        $bias = -[int][TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
        $line = '<![LOG[{0}]LOG]!><time="{1}{2:+0;-0;+0}" date="{3}" component="LanguagePackInstaller" context="{4}" type="{5}" thread="{6}" file="">' -f `
            $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'),
            [Security.Principal.WindowsIdentity]::GetCurrent().Name, $type, [Threading.Thread]::CurrentThread.ManagedThreadId
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    $prefix = ''
    if ($Level -ne 'Info') { $prefix = $Level.ToUpper() + ': ' }
    $display = '{0}  {1}{2}' -f $now.ToString('HH:mm:ss'), $prefix, $Message
    if ($script:LogQueue) {
        $script:LogQueue.Enqueue($display)
    }
    else {
        Write-Host $display
    }
}

#endregion

#region Language and repository discovery

function ConvertTo-LpiLanguageTag {
    <# Normalises a tag such as 'de-de' or 'sr-latn-rs' to 'de-DE' / 'sr-Latn-RS'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Language)
    try {
        $name = [Globalization.CultureInfo]::GetCultureInfo($Language).Name
        if ($name) { return $name }
    }
    catch { }
    return $Language
}

function Get-LpiInstalledPackage {
    <# Installed and install-pending DISM packages, cached because the query is slow. #>
    [CmdletBinding()]
    param([switch]$Refresh)
    if ($Refresh -or $null -eq $script:PackageCache) {
        $script:PackageCache = @(Get-WindowsPackage -Online | Where-Object {
                "$($_.PackageState)" -in @('Installed', 'InstallPending')
            })
    }
    return $script:PackageCache
}

function Get-LpiInstalledLanguageTag {
    <# Tags of the languages whose language pack (full or LIP) is installed. #>
    [CmdletBinding()]
    param([switch]$Refresh)
    $tags = New-Object System.Collections.Generic.List[string]
    foreach ($package in Get-LpiInstalledPackage -Refresh:$Refresh) {
        if ($package.PackageName -match '^Microsoft-Windows-(Client|Lip)-LanguagePack-Package~[^~]*~[^~]*~([^~]+)~') {
            $tags.Add((ConvertTo-LpiLanguageTag -Language $Matches[2]))
        }
    }
    try {
        foreach ($language in Get-InstalledLanguage -ErrorAction Stop) {
            if ($language.LanguageId -and "$($language.LanguagePacks)" -match 'LpCab|LXP') {
                $tags.Add((ConvertTo-LpiLanguageTag -Language $language.LanguageId))
            }
        }
    }
    catch { }
    return @($tags | Sort-Object -Unique)
}

function Get-LpiInstalledFeatureLanguageTag {
    <# Tags of the languages with at least one installed language feature (Basic, OCR, ...), with or without a language pack. #>
    [CmdletBinding()]
    param([switch]$Refresh)
    $tags = foreach ($package in Get-LpiInstalledPackage -Refresh:$Refresh) {
        if ($package.PackageName -match '^Microsoft-Windows-LanguageFeatures-(Basic|Handwriting|OCR|Speech|TextToSpeech)-(.+?)-Package~') {
            ConvertTo-LpiLanguageTag -Language $Matches[2]
        }
    }
    return @($tags | Sort-Object -Unique)
}

function Get-LpiLanguageFile {
    <#
        The CABs in a LanguagesAndOptionalFeatures-style folder that belong to one
        language: its language pack, its language features (with capability names),
        its script font and, optionally, its satellite packages for other FODs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Language,
        [switch]$IncludeSatellites,
        [System.IO.FileInfo[]]$Files
    )
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    $escaped = [regex]::Escape($tag)
    if (-not $Files) { $Files = Get-ChildItem -LiteralPath $Path -Filter '*.cab' -File }

    $fontScript = $script:FontScripts[$tag]
    $fontName = $null
    if ($fontScript) { $fontName = "Microsoft-Windows-LanguageFeatures-Fonts-$fontScript-Package~31bf3856ad364e35~amd64~~.cab" }

    $result = foreach ($file in $Files) {
        $name = $file.Name
        if ($name -match "^Microsoft-Windows-(Client|Lip)-Language-Pack_x64_$escaped\.cab$") {
            [pscustomobject]@{ Kind = 'LanguagePack'; Order = 0; Capability = $null; File = $file }
        }
        elseif ($name -match "^Microsoft-Windows-LanguageFeatures-(Basic|Handwriting|OCR|Speech|TextToSpeech)-$escaped-Package~.*~amd64~~\.cab$") {
            $feature = $Matches[1]
            [pscustomobject]@{
                Kind       = 'Feature'
                Order      = $script:FeatureOrder[$feature]
                Capability = "Language.$feature~~~$tag~0.0.1.0"
                File       = $file
            }
        }
        elseif ($fontName -and $name -eq $fontName) {
            [pscustomobject]@{
                Kind       = 'Font'
                Order      = 2
                Capability = "Language.Fonts.$fontScript~~~und-$($fontScript.ToUpper())~0.0.1.0"
                File       = $file
            }
        }
        elseif ($IncludeSatellites -and $name -match "~(amd64|wow64)~$escaped~\.cab$") {
            [pscustomobject]@{ Kind = 'Satellite'; Order = 9; Capability = $null; File = $file }
        }
    }
    return @($result | Sort-Object -Property Order, @{ Expression = { $_.File.Name } })
}

function Get-LpiRepositoryLanguage {
    <#
        The languages in the repository: those with a language pack CAB (Type Full or Partial), sorted by name, then
        the feature-only languages (Type Features: language features such as spelling or speech, but no language pack,
        for example en-AU, de-CH, hi-IN), sorted by name. A feature-only language cannot be a display language.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [switch]$SkipInstalledCheck
    )
    $installed = @()
    $installedFeatures = @()
    if (-not $SkipInstalledCheck) {
        $installed = Get-LpiInstalledLanguageTag
        $installedFeatures = Get-LpiInstalledFeatureLanguageTag
    }
    $newEntry = {
        param([string]$Tag, [string]$Type, [string]$PackagePath, [bool]$Installed)
        $displayName = $Tag
        $nativeName = $Tag
        try {
            $culture = [Globalization.CultureInfo]::GetCultureInfo($Tag)
            $displayName = $culture.DisplayName
            $nativeName = $culture.NativeName
        }
        catch { }
        if ($script:LanguageNames[$Tag] -and ($displayName -eq $Tag -or $displayName -match '^Unknown')) {
            $displayName = $script:LanguageNames[$Tag]
            $nativeName = $script:LanguageNames[$Tag]
        }
        [pscustomobject]@{
            Tag         = $Tag
            DisplayName = $displayName
            NativeName  = $nativeName
            Type        = $Type
            PackagePath = $PackagePath
            Installed   = $Installed
        }
    }

    $languages = foreach ($file in Get-ChildItem -LiteralPath $Repository -Filter 'Microsoft-Windows-*-Language-Pack_x64_*.cab' -File) {
        if ($file.Name -notmatch '^Microsoft-Windows-(Client|Lip)-Language-Pack_x64_(.+)\.cab$') { continue }
        $type = 'Full'
        if ($Matches[1] -eq 'Lip') { $type = 'Partial' }
        $tag = ConvertTo-LpiLanguageTag -Language $Matches[2]
        & $newEntry $tag $type $file.FullName ($installed -contains $tag)
    }
    $languages = @($languages | Sort-Object -Property DisplayName)

    $withPack = @($languages | ForEach-Object { $_.Tag })
    $featureTags = foreach ($file in Get-ChildItem -LiteralPath $Repository -Filter 'Microsoft-Windows-LanguageFeatures-*-Package~*.cab' -File) {
        if ($file.Name -match '^Microsoft-Windows-LanguageFeatures-(Basic|Handwriting|OCR|Speech|TextToSpeech)-(.+?)-Package~') {
            ConvertTo-LpiLanguageTag -Language $Matches[2]
        }
    }
    $featureOnly = foreach ($tag in @($featureTags | Sort-Object -Unique)) {
        if ($withPack -contains $tag) { continue }
        & $newEntry $tag 'Features' $null ($installedFeatures -contains $tag)
    }
    return @($languages) + @($featureOnly | Sort-Object -Property DisplayName)
}

#endregion

#region Prerequisites

function Test-LpiPrerequisite {
    <# Returns a list of problems that stop the installer from running; empty when all is well. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$UserScriptPath
    )
    $problems = New-Object System.Collections.Generic.List[string]

    # No administrator check: the installer runs as SYSTEM from a ConfigMgr application deployment.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 26100) {
        $problems.Add("Windows 11 24H2 (build 26100) or later is required; this device is build $($os.BuildNumber).")
    }
    if ($os.ProductType -ne 1) {
        $problems.Add('This installer supports Windows 11 client editions only, not Windows Server.')
    }
    if (-not (Get-Module -ListAvailable -Name LanguagePackManagement)) {
        $problems.Add('The LanguagePackManagement PowerShell module is not available on this device.')
    }
    if (-not (Test-Path -LiteralPath $UserScriptPath)) {
        $problems.Add("The per-user script was not found: $UserScriptPath")
    }
    $completeScript = Join-Path -Path (Split-Path -Path $UserScriptPath -Parent) -ChildPath 'Complete-SystemLanguage.ps1'
    if (-not (Test-Path -LiteralPath $completeScript)) {
        $problems.Add("The completion script was not found: $completeScript")
    }
    if (-not (Test-Path -LiteralPath $Repository)) {
        $problems.Add("The language repository was not found: $Repository")
    }
    elseif (-not (Get-ChildItem -LiteralPath $Repository -Filter 'Microsoft-Windows-*-Language-Pack_x64_*.cab' -File) -and
        -not (Get-ChildItem -LiteralPath $Repository -Filter 'Microsoft-Windows-LanguageFeatures-*-Package~*.cab' -File)) {
        $problems.Add("The language repository contains no language pack or language feature CABs: $Repository")
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path -Path $Repository -ChildPath 'metadata'))) {
        $problems.Add("The language repository has no 'metadata' folder, which DISM needs to add language features: $Repository")
    }
    return $problems.ToArray()
}

#endregion

#region System-wide installation

function Get-LpiDismLogPath {
    if ($script:LogDirectory) { return Join-Path -Path $script:LogDirectory -ChildPath 'LanguagePackInstaller-DISM.log' }
    return Join-Path -Path $env:windir -ChildPath 'Logs\DISM\dism.log'
}

function Test-LpiRestartNeeded {
    <# True when a DISM cmdlet result reports RestartNeeded (checked defensively under strict mode). #>
    param($Result)
    foreach ($item in @($Result)) {
        if ($null -ne $item -and $item.PSObject.Properties['RestartNeeded'] -and $item.RestartNeeded) { return $true }
    }
    return $false
}

function Install-LpiLanguage {
    <#
        Adds the language pack, its language features and its font from the repository.
        Returns $true when DISM reports that a restart is needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][psobject]$Language
    )
    $tag = $Language.Tag
    $dismLog = Get-LpiDismLogPath
    $restartNeeded = $false

    if ($Language.Type -eq 'Partial') {
        $parents = $script:LipParents[$tag]
        $installedTags = Get-LpiInstalledLanguageTag
        if ($parents -and -not ($parents | Where-Object { $installedTags -contains $_ })) {
            Write-LpiLog -Level Warning -Message "$tag is a partial language. Windows normally needs one of these installed first: $($parents -join ', '). DISM may reject it."
        }
    }

    $files = Get-LpiLanguageFile -Path $Repository -Language $tag

    if ($Language.Type -eq 'Features') {
        Write-LpiLog -Message "$tag has no language pack (Windows is not translated into it); adding its language features only."
    }
    elseif ($Language.Installed) {
        Write-LpiLog -Message "Language pack for $tag is already installed."
    }
    else {
        Write-LpiLog -Message "Adding language pack $(Split-Path -Path $Language.PackagePath -Leaf). This can take several minutes."
        $result = Add-WindowsPackage -Online -PackagePath $Language.PackagePath -NoRestart -LogPath $dismLog -ErrorAction Stop
        if (Test-LpiRestartNeeded -Result $result) { $restartNeeded = $true }
        Write-LpiLog -Message "Language pack for $tag added (DISM restart needed: $(Test-LpiRestartNeeded -Result $result))."
    }

    $capabilities = @($files | Where-Object { $_.Kind -in @('Feature', 'Font') })
    $failed = 0
    if (-not $capabilities) {
        if ($Language.Type -eq 'Features') { throw "No language feature CABs for $tag were found in the repository." }
        Write-LpiLog -Level Warning -Message "No language feature CABs for $tag were found in the repository."
    }
    foreach ($item in $capabilities) {
        $state = $null
        try { $state = "$((Get-WindowsCapability -Online -Name $item.Capability -LimitAccess -ErrorAction Stop).State)" } catch { }
        if ($state -eq 'Installed') {
            Write-LpiLog -Message "$($item.Capability) is already installed."
            continue
        }
        Write-LpiLog -Message "Adding $($item.Capability)"
        try {
            try {
                $result = Add-WindowsCapability -Online -Name $item.Capability -Source $Repository -LimitAccess -LogPath $dismLog -ErrorAction Stop
            }
            catch {
                Write-LpiLog -Level Warning -Message "Add-WindowsCapability failed ($($_.Exception.Message)). Adding $($item.File.Name) directly."
                $result = Add-WindowsPackage -Online -PackagePath $item.File.FullName -NoRestart -LogPath $dismLog -ErrorAction Stop
            }
            if (Test-LpiRestartNeeded -Result $result) { $restartNeeded = $true }
        }
        catch {
            # Without the Basic feature (spelling, typing) the language is not usable, so stop.
            if ($item.Capability -like 'Language.Basic~*') { throw }
            Write-LpiLog -Level Warning -Message "Could not add $($item.Capability): $($_.Exception.Message)"
            if ($item.Kind -eq 'Feature') { $failed++ }
        }
    }
    # A feature-only language is nothing but its features: when none could be added, the install failed.
    if ($Language.Type -eq 'Features' -and $capabilities -and $failed -ge @($capabilities | Where-Object { $_.Kind -eq 'Feature' }).Count) {
        throw "None of the language features of $tag could be added; see the DISM log."
    }

    Get-LpiInstalledPackage -Refresh | Out-Null
    return $restartNeeded
}

function Install-LpiFodSatellite {
    <#
        Adds this language's resources for Features on Demand that are already installed
        (Notepad, Paint, Snipping Tool, RSAT...), so those apps appear translated too.
        Returns $true when DISM reports that a restart is needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Language
    )
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    $dismLog = Get-LpiDismLogPath
    $restartNeeded = $false

    # Index installed packages by "name~arch~language" (language is empty for neutral packages).
    $installed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($package in Get-LpiInstalledPackage) {
        $parts = $package.PackageName -split '~'
        if ($parts.Count -ge 4) { [void]$installed.Add("$($parts[0])~$($parts[2])~$($parts[3])") }
    }

    $satellites = Get-LpiLanguageFile -Path $Repository -Language $tag -IncludeSatellites | Where-Object { $_.Kind -eq 'Satellite' }
    $attempted = 0
    foreach ($item in $satellites) {
        # Satellite CAB: <name>~<token>~<arch>~<language>~.cab
        $parts = $item.File.BaseName -split '~'
        if ($parts.Count -lt 4) { continue }
        if (-not $installed.Contains("$($parts[0])~$($parts[2])~")) { continue }  # base feature not installed
        if ($installed.Contains("$($parts[0])~$($parts[2])~$tag")) { continue }    # already localised

        Write-LpiLog -Message "Adding $tag resources for $($parts[0]) ($($parts[2]))"
        $attempted++
        try {
            $result = Add-WindowsPackage -Online -PackagePath $item.File.FullName -NoRestart -LogPath $dismLog -ErrorAction Stop
            if (Test-LpiRestartNeeded -Result $result) { $restartNeeded = $true }
        }
        catch {
            Write-LpiLog -Level Warning -Message "Could not add $($item.File.Name): $($_.Exception.Message)"
        }
    }
    $neutral = @($installed | Where-Object { $_.EndsWith('~') }).Count
    Write-LpiLog -Message "FOD resources: $(@($satellites).Count) $tag satellite CABs in the repository, $neutral installed neutral packages, $attempted added."
    return $restartNeeded
}

function Set-LpiRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'String'
    )
    # Never New-Item -Force an existing registry key: that recreates it and drops its values.
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Disable-LpiLanguageCleanup {
    <#
        Stops Windows' LPRemove task from removing a language pack that no user has selected yet.
        Records in HKLM\SOFTWARE\LanguagePackInstaller when it set the policy itself (it was not already 1), so
        Uninstall-LanguagePack.ps1 removes only a policy this installer set, never one set by Group Policy.
    #>
    $policyKey = $script:CleanupPolicyKey
    $current = $null
    try { $current = (Get-ItemProperty -LiteralPath $policyKey -Name 'BlockCleanupOfUnusedPreinstalledLangPacks' -ErrorAction Stop).BlockCleanupOfUnusedPreinstalledLangPacks } catch { }
    if ($current -eq 1) {
        Write-LpiLog -Message 'BlockCleanupOfUnusedPreinstalledLangPacks is already set.'
        return
    }
    Set-LpiRegistryValue -Path $policyKey -Name 'BlockCleanupOfUnusedPreinstalledLangPacks' -Value 1 -Type DWord
    Set-LpiRegistryValue -Path $script:RegistryRoot -Name 'CleanupPolicySet' -Value 1 -Type DWord
    Write-LpiLog -Message 'Set BlockCleanupOfUnusedPreinstalledLangPacks so Windows does not remove unused language packs.'
}

#endregion

#region Display language (system and per-user)

function Publish-LpiUserScript {
    <#
        Copies Set-UserLanguage.ps1 (and Complete-SystemLanguage.ps1) to %ProgramData%\LanguagePackInstaller where standard users
        can read and run it (the ConfigMgr cache is admin-only). Users get read/execute on the
        script and modify on the Logs folder only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserScriptPath)

    $root = $script:UserDataRoot
    $logs = Join-Path -Path $root -ChildPath 'Logs'
    foreach ($folder in @($root, $logs)) {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
    }
    # SYSTEM and Administrators: full control. Users: read and execute; modify on Logs only.
    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    & icacls.exe $logs /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null

    $target = Join-Path -Path $root -ChildPath 'Set-UserLanguage.ps1'
    Copy-Item -LiteralPath $UserScriptPath -Destination $target -Force
    $completeScript = Join-Path -Path (Split-Path -Path $UserScriptPath -Parent) -ChildPath 'Complete-SystemLanguage.ps1'
    Copy-Item -LiteralPath $completeScript -Destination $root -Force
    return $target
}

function Get-LpiUserScriptArgument {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Language,
        [switch]$SetRegionalFormat,
        [string]$RemoveLanguage,
        [string[]]$OnlyUsers
    )
    $logs = Join-Path -Path $script:UserDataRoot -ChildPath 'Logs'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Language $Language -LogDirectory `"$logs`""
    if ($SetRegionalFormat) { $arguments += ' -SetRegionalFormat' }
    if ($RemoveLanguage) { $arguments += " -RemoveLanguage $RemoveLanguage" }
    if ($OnlyUsers) { $arguments += " -OnlyUsers $($OnlyUsers -join ',')" }
    return $arguments
}

function Get-LpiLoggedOnUser {
    <# DOMAIN\user for every account with an interactive desktop (an explorer.exe process). #>
    $users = foreach ($process in Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'") {
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner
        if ($owner.ReturnValue -eq 0 -and $owner.User) { "$($owner.Domain)\$($owner.User)" }
    }
    return @($users | Sort-Object -Unique)
}

function Invoke-LpiAsUser {
    <#
        Runs powershell.exe with the given arguments in a signed-in user's session through a
        one-shot scheduled task (no password needed when registered by SYSTEM or an admin).
        Returns the process exit code, or $null if it did not finish in time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Arguments,
        [int]$TimeoutSeconds = 300
    )
    $taskName = 'LanguagePackInstaller-User-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $Arguments
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds)

    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName -TaskPath '\'
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 15)
        do {
            Start-Sleep -Seconds 1
            $state = "$((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State)"
            $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
            # 267011 (0x41303) = the task has not run yet; 267009 (0x41301) = it is running.
            $pending = ($state -in @('Running', 'Queued')) -or ($info.LastTaskResult -in @(267011, 267009))
        } while ($pending -and (Get-Date) -lt $deadline)
        if ($pending) { return $null }
        return [int]$info.LastTaskResult
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Get-LpiUserSid {
    <# SID of a DOMAIN\user account name, or $null when it cannot be resolved. #>
    param([Parameter(Mandatory)][string]$UserName)
    try { return (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
    catch { return $null }
}

function Register-LpiActiveSetup {
    <#
        Applies the per-user settings once at each user's next sign-in (Active Setup): to every user, or - when the
        arguments carry -OnlyUsers - only to those accounts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Arguments)
    $key = $script:ActiveSetupKey
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-LpiRegistryValue -Path $key -Name '(Default)' -Value 'Language Pack Installer - user language settings'
    Set-LpiRegistryValue -Path $key -Name 'StubPath' -Value "`"$powershell`" $Arguments"
    # A higher version makes Active Setup run again for users who already ran an older one.
    Set-LpiRegistryValue -Path $key -Name 'Version' -Value (Get-Date -Format 'yyyy,MMdd,HHmm,ss')
    Set-LpiRegistryValue -Path $key -Name 'IsInstalled' -Value 1 -Type DWord
    if ($Arguments -match '-OnlyUsers ') {
        Write-LpiLog -Message 'Registered Active Setup: the signed-in users get the language settings again at their next sign-in, after the restart.'
    }
    else {
        Write-LpiLog -Message 'Registered Active Setup: other existing users get the language settings at their next sign-in.'
    }
}

function Register-LpiCompleteTask {
    <#
        One-shot SYSTEM startup task that finishes the system part of a display-language change
        (Complete-SystemLanguage.ps1) once the language pack is no longer pending a restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Language,
        [switch]$SetRegionalFormat
    )
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Language $Language"
    if ($SetRegionalFormat) { $arguments += ' -SetRegionalFormat' }
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName 'LanguagePackInstaller-CompleteSystemLanguage' -TaskPath '\' -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-LpiLog -Message 'Registered a startup task that finishes the system display language after the restart.'
}

function Set-LpiDisplayLanguage {
    <#
        System part: system preferred UI language, Welcome screen and new-user defaults.
        User part: the signed-in user(s), and optionally every other existing user at next
        sign-in. Windows can refuse the system part until the restart that completes the
        language pack; then a startup task finishes it, and the run still succeeds (3010).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$UserScriptPath,
        [switch]$SetRegionalFormat,
        [switch]$ApplyToExistingUsers,
        # a language being uninstalled: taken out of each user's language list as well
        [string]$RemoveLanguage
    )
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    $publishedScript = Publish-LpiUserScript -UserScriptPath $UserScriptPath
    $userLogs = Join-Path -Path $script:UserDataRoot -ChildPath 'Logs'
    $systemDone = $true

    # Copy-UserInternationalSettingsToSystem copies the *running* account's settings, so set
    # them on this account first (SYSTEM under ConfigMgr). Run the copy from the package
    # source, not the user-writable ProgramData area, because this runs elevated.
    Write-LpiLog -Message "Applying $tag to the running account ($([Security.Principal.WindowsIdentity]::GetCurrent().Name))."
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-LpiUserScriptArgument -ScriptPath $UserScriptPath -Language $tag -SetRegionalFormat:$SetRegionalFormat -RemoveLanguage $RemoveLanguage
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        Write-LpiLog -Level Warning -Message "Applying $tag to the running account failed (exit code $($process.ExitCode)); see $userLogs."
        $systemDone = $false
    }

    if ($systemDone) {
        Write-LpiLog -Message "Setting the system preferred UI language to $tag."
        try {
            Set-SystemPreferredUILanguage -Language $tag -ErrorAction Stop
        }
        catch {
            # Expected right after the language pack is added: Windows takes the new language only after a restart.
            Write-LpiLog -Message "Windows applies the system preferred UI language after the restart (it answered: $($_.Exception.Message))."
            $systemDone = $false
        }
    }

    if ($systemDone) {
        Write-LpiLog -Message 'Copying the language settings to the Welcome screen and new user accounts.'
        try {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop
        }
        catch {
            Write-LpiLog -Message "Windows copies the settings to the Welcome screen and new users after the restart (it answered: $($_.Exception.Message))."
            $systemDone = $false
        }
    }

    if (-not $systemDone) {
        $completeScript = Join-Path -Path $script:UserDataRoot -ChildPath 'Complete-SystemLanguage.ps1'
        Register-LpiCompleteTask -ScriptPath $completeScript -Language $tag -SetRegionalFormat:$SetRegionalFormat
    }

    $userArguments = Get-LpiUserScriptArgument -ScriptPath $publishedScript -Language $tag -SetRegionalFormat:$SetRegionalFormat -RemoveLanguage $RemoveLanguage
    $self = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $users = @(Get-LpiLoggedOnUser | Where-Object { $_ -ne $self })
    if (-not $users) {
        Write-LpiLog -Message 'No other signed-in user was found.'
    }
    foreach ($user in $users) {
        Write-LpiLog -Message "Applying $tag for signed-in user $user."
        try {
            $exitCode = Invoke-LpiAsUser -UserName $user -Arguments $userArguments
            if ($null -eq $exitCode) {
                Write-LpiLog -Level Warning -Message "The user step for $user did not finish in time."
            }
            elseif ($exitCode -ne 0) {
                Write-LpiLog -Level Warning -Message "The user step for $user failed (exit code $exitCode); see $userLogs."
            }
            else {
                Write-LpiLog -Message "Applied $tag for $user. It takes effect when they sign out and back in."
            }
        }
        catch {
            Write-LpiLog -Level Warning -Message "Could not run the user step for ${user}: $($_.Exception.Message)"
        }
    }

    if ($ApplyToExistingUsers) {
        Register-LpiActiveSetup -Arguments $userArguments
    }
    elseif (-not $systemDone) {
        # Windows postponed the system part: the language pack is still waiting for the restart. At the sign-in after
        # it, Windows rewrites the language list of an account that was given the language now (seen on Windows 11
        # 25H2, 2026-10-04: cs-CZ replaced by 'cs' further down the list, the display language back to en-US), so
        # apply it again then - to the users signed in now, and the running account when that is a user, not SYSTEM.
        $again = @($users)
        if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { $again += $self }
        $sids = @($again | ForEach-Object { Get-LpiUserSid -UserName $_ } | Where-Object { $_ } | Sort-Object -Unique)
        if ($sids) {
            Register-LpiActiveSetup -Arguments (Get-LpiUserScriptArgument -ScriptPath $publishedScript -Language $tag -SetRegionalFormat:$SetRegionalFormat -RemoveLanguage $RemoveLanguage -OnlyUsers $sids)
        }
    }
}

#endregion

#region Orchestration

function Invoke-LpiInstall {
    <#
        Installs one language from the repository and optionally makes it the display language.
        Returns an object with ExitCode (0, 3010 or 1603), RestartNeeded and Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$UserScriptPath,
        [string]$LogPath,
        [switch]$SetDisplayLanguage,
        [switch]$SetRegionalFormat,
        [switch]$SetSystemLocale,
        [switch]$ApplyToExistingUsers,
        [switch]$AllowLanguageCleanup
    )
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    $restartNeeded = $false
    try {
        Write-LpiLog -Message "Installing $tag from $Repository (display language: $([bool]$SetDisplayLanguage), regional format: $([bool]$SetRegionalFormat), system locale: $([bool]$SetSystemLocale))."

        $entry = Get-LpiRepositoryLanguage -Repository $Repository | Where-Object { $_.Tag -eq $tag } | Select-Object -First 1
        if (-not $entry) { throw "No language pack or language features for $tag were found in $Repository." }
        $featuresOnly = ($entry.Type -eq 'Features')
        if ($featuresOnly -and $SetDisplayLanguage) {
            throw "$tag has no language pack, so it cannot be the display language. Install it without -SetDisplayLanguage to add its language features (spelling, typing, speech)."
        }

        if (Install-LpiLanguage -Repository $Repository -Language $entry) { $restartNeeded = $true }
        if (-not $featuresOnly -and (Install-LpiFodSatellite -Repository $Repository -Language $tag)) { $restartNeeded = $true }
        if (-not $AllowLanguageCleanup) { Disable-LpiLanguageCleanup }

        if ($SetDisplayLanguage) {
            Set-LpiDisplayLanguage -Language $tag -UserScriptPath $UserScriptPath `
                -SetRegionalFormat:$SetRegionalFormat -ApplyToExistingUsers:$ApplyToExistingUsers
            $restartNeeded = $true
        }
        elseif ($SetRegionalFormat -or $ApplyToExistingUsers) {
            Write-LpiLog -Level Warning -Message 'Regional format and existing-user options only apply together with the display language option; skipped.'
        }

        if ($SetSystemLocale) {
            Write-LpiLog -Message "Setting the system locale (language for non-Unicode programs) to $tag."
            Set-WinSystemLocale -SystemLocale $tag -ErrorAction Stop
            $restartNeeded = $true
        }

        $marker = Join-Path -Path $script:RegistryRoot -ChildPath "Languages\$tag"
        Set-LpiRegistryValue -Path $marker -Name 'InstalledOn' -Value (Get-Date -Format 's')
        Set-LpiRegistryValue -Path $marker -Name 'Source' -Value $Repository
        if ($SetDisplayLanguage) {
            Set-LpiRegistryValue -Path $script:RegistryRoot -Name 'DisplayLanguage' -Value $tag
        }

        $exitCode = $script:ExitSuccess
        $message = "$tag was installed."
        if ($restartNeeded) {
            $exitCode = $script:ExitReboot
            $message = "$tag was installed. Restart the device (or sign out) to finish."
        }
        if ($featuresOnly) {
            $message = $message.Replace("$tag was installed.", "The $tag language features were installed.")
            $message += " Users add $tag in Settings > Time & language > Language & region; its features are already on the device."
        }
        Write-LpiLog -Message "$message Exit code $exitCode."
        return [pscustomobject]@{ ExitCode = $exitCode; RestartNeeded = $restartNeeded; Message = $message }
    }
    catch {
        Write-LpiLog -Level Error -Message "Installing $tag failed: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = $script:ExitFailure; RestartNeeded = $restartNeeded; Message = $_.Exception.Message }
    }
}

#endregion

#region Uninstall

function Get-LpiInstallLanguageTag {
    <# The language Windows was installed with (Nls InstallLanguage, a hex LCID), as a tag, or $null. #>
    try {
        $lcid = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Language' -Name 'InstallLanguage' -ErrorAction Stop).InstallLanguage
        return [Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($lcid, 16)).Name
    }
    catch { return $null }
}

function Remove-LpiEmptyKey {
    <# Removes a registry key when it holds no values and no subkeys. #>
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and $item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
        Remove-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Test-LpiDisplayLanguage {
    <# True when $Language is the system display language or the display language this installer set. #>
    param([Parameter(Mandatory)][string]$Language)
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    $systemUi = $null
    try { $systemUi = ConvertTo-LpiLanguageTag -Language "$(Get-SystemPreferredUILanguage -ErrorAction Stop)" } catch { }
    $setDisplay = $null
    try { $setDisplay = (Get-ItemProperty -LiteralPath $script:RegistryRoot -Name 'DisplayLanguage' -ErrorAction Stop).DisplayLanguage } catch { }
    return [bool](($systemUi -eq $tag) -or ($setDisplay -and (ConvertTo-LpiLanguageTag -Language $setDisplay) -eq $tag))
}

function Reset-LpiDisplayLanguage {
    <#
        Sets the display language back to the default - the language Windows was installed with - because $Language is
        being uninstalled: the system, the Welcome screen and new users, the signed-in users and (when an Active Setup
        entry exists) every other user at next sign-in; $Language is taken out of those users' language lists.
        Returns the default language tag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$UserScriptPath
    )
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    $default = Get-LpiInstallLanguageTag
    if (-not $default) { throw 'The language Windows was installed with could not be read, so the display language cannot be set back to it.' }
    if ($default -eq $tag) { throw "$tag is the language Windows was installed with; it cannot be removed." }
    # Every user gets the default language again at next sign-in only when the language was applied to every user
    # (-ApplyToExistingUsers); not for an Active Setup entry limited to the users signed in during the install.
    $stub = $null
    try { $stub = (Get-ItemProperty -LiteralPath $script:ActiveSetupKey -Name 'StubPath' -ErrorAction Stop).StubPath } catch { }
    $hadActiveSetup = [bool]($stub -and $stub -notmatch '-OnlyUsers ')
    Write-LpiLog -Message "$tag is the display language; setting the display language back to the default, $default, before uninstalling it."
    Set-LpiDisplayLanguage -Language $default -UserScriptPath $UserScriptPath -RemoveLanguage $tag -ApplyToExistingUsers:$hadActiveSetup
    Remove-ItemProperty -LiteralPath $script:RegistryRoot -Name 'DisplayLanguage' -ErrorAction SilentlyContinue
    return $default
}

function Register-LpiUninstallTask {
    <#
        One-shot SYSTEM startup task that finishes an uninstall after the restart, when Windows would not remove the
        language pack of a display language that was only just switched back to the default. It runs a copy of
        Uninstall-LanguagePack.ps1 (with this module) in %ProgramData%\LanguagePackInstaller, where only SYSTEM and
        Administrators can write, and removes itself once the uninstall succeeds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$SourceDirectory
    )
    $root = $script:UserDataRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -ItemType Directory -Force | Out-Null }
    foreach ($file in 'Uninstall-LanguagePack.ps1', 'LanguagePackInstaller.psm1', 'Set-UserLanguage.ps1') {
        Copy-Item -LiteralPath (Join-Path -Path $SourceDirectory -ChildPath $file) -Destination $root -Force
    }
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path -Path $root -ChildPath 'Uninstall-LanguagePack.ps1')`" -Language $Language -FromStartupTask"
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName "LanguagePackInstaller-CompleteUninstall-$Language" -TaskPath '\' -Action $action `
        -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-LpiLog -Message "Registered a startup task that finishes uninstalling $Language after the restart."
}

function Remove-LpiCapability {
    <# Removes one capability, logging the result; returns $true when DISM reports that a restart is needed. #>
    param([Parameter(Mandatory)][string]$Name)
    Write-LpiLog -Message "Removing $Name"
    try {
        $result = Remove-WindowsCapability -Online -Name $Name -LogPath (Get-LpiDismLogPath) -ErrorAction Stop
        return (Test-LpiRestartNeeded -Result $result)
    }
    catch {
        Write-LpiLog -Level Warning -Message "Could not remove ${Name}: $($_.Exception.Message)"
        return $false
    }
}

function Uninstall-LpiLanguage {
    <#
        Removes one language: its language features and font, its satellite packages for installed Features on
        Demand, then its language pack; then this installer's registry entries for it. Refuses (1603) to remove
        Windows' install language. A display language (the system's, or the one this installer set) is refused too,
        unless -ResetDisplayLanguage: then the display language is first set back to Windows' install language
        (Reset-LpiDisplayLanguage), and if Windows will not remove the language pack before the restart, a startup
        task finishes the uninstall after it (exit 3010).
        A language that is not installed is a success (0), so a deployment can run it again.
        Returns an object with ExitCode (0, 3010 or 1603), RestartNeeded and Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Language,
        [switch]$KeepCleanupPolicy,
        [switch]$ResetDisplayLanguage,
        [string]$UserScriptPath
    )
    $tag = ConvertTo-LpiLanguageTag -Language $Language
    $escaped = [regex]::Escape($tag)
    $dismLog = Get-LpiDismLogPath
    $restartNeeded = $false
    $wasDisplay = $false
    try {
        Write-LpiLog -Message "Uninstalling $tag$(if ($ResetDisplayLanguage) { ' (display language reset allowed)' })."

        # Never remove the language Windows was installed with; a display language only after setting it back.
        $installLanguage = Get-LpiInstallLanguageTag
        if ($installLanguage -eq $tag) { throw "$tag is the language Windows was installed with; it cannot be removed." }
        if (Test-LpiDisplayLanguage -Language $tag) {
            if (-not $ResetDisplayLanguage) { throw "$tag is the display language. Use -ResetDisplayLanguage to set the display language back to the default ($installLanguage) and uninstall it, or set another display language first (and restart)." }
            if (-not $UserScriptPath) { throw '-ResetDisplayLanguage needs -UserScriptPath (Set-UserLanguage.ps1).' }
            [void](Reset-LpiDisplayLanguage -Language $tag -UserScriptPath $UserScriptPath)
            $wasDisplay = $true
            $restartNeeded = $true
        }

        # The removal order matters (real test on Windows 11 25H2, 2026-10-04): Language.Basic is a permanent package
        # while the language pack is installed (0x800f0825), and the language pack's own localised parts (Notepad,
        # Media Player, ...) cannot be removed on their own - they go with the language pack. So: the other features,
        # then the language pack, then whatever of this language is still installed (satellites added on their own),
        # then Basic and the font, then a check that nothing is left.
        $featurePattern = "^Language\.(Basic|OCR|Handwriting|TextToSpeech|Speech)~~~$escaped~"
        $capabilities = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { "$($_.State)" -eq 'Installed' -and $_.Name -match $featurePattern })
        $basic = @($capabilities | Where-Object { $_.Name -like 'Language.Basic~*' })
        $features = @($capabilities | Where-Object { $_.Name -notlike 'Language.Basic~*' })
        $font = @()
        $fontScript = $script:FontScripts[$tag]
        if ($fontScript) {
            # languages with a language pack or with language features only (ar-SA and ar-EG share Arab, for example)
            $others = @(@(Get-LpiInstalledLanguageTag) + @(Get-LpiInstalledFeatureLanguageTag) | Sort-Object -Unique | Where-Object { $_ -ne $tag -and $script:FontScripts[$_] -eq $fontScript })
            $fontName = "Language.Fonts.$fontScript~~~und-$($fontScript.ToUpper())~0.0.1.0"
            if ($others) { Write-LpiLog -Message "Keeping ${fontName}: also used by $($others -join ', ')." }
            else { $font = @(Get-WindowsCapability -Online -Name $fontName -ErrorAction SilentlyContinue | Where-Object { "$($_.State)" -eq 'Installed' }) }
        }
        $packages = @(Get-LpiInstalledPackage -Refresh | Where-Object { $_.PackageName -match "(?i)~$escaped~" })
        $languagePacks = @($packages | Where-Object { $_.PackageName -match '^Microsoft-Windows-(Client|Lip)-LanguagePack-Package~' })
        if (-not $capabilities -and -not $packages -and -not $font) {
            Write-LpiLog -Message "$tag is not installed; nothing to remove."
        }

        # 1. The features that depend on Basic.
        foreach ($capability in $features) { if (Remove-LpiCapability -Name $capability.Name) { $restartNeeded = $true } }

        # 2. The language pack: it takes its own localised parts with it. It must go - except that a display language
        #    only just switched back to the default may still be in use until the restart: then the uninstall is
        #    finished by a startup task after the restart, and the registry entry stays until it is done.
        foreach ($package in $languagePacks) {
            Write-LpiLog -Message "Removing $($package.PackageName)"
            try {
                $result = Remove-WindowsPackage -Online -PackageName $package.PackageName -NoRestart -LogPath $dismLog -ErrorAction Stop
                if (Test-LpiRestartNeeded -Result $result) { $restartNeeded = $true }
            }
            catch {
                if (-not $wasDisplay) { throw }
                Write-LpiLog -Level Warning -Message "Windows will not remove the $tag language pack before the restart ($($_.Exception.Message))."
                Register-LpiUninstallTask -Language $tag -SourceDirectory (Split-Path -Path $UserScriptPath -Parent)
                $message = "The display language was set back to $installLanguage. $tag is removed after the restart."
                Write-LpiLog -Message "$message Exit code $($script:ExitReboot)."
                return [pscustomobject]@{ ExitCode = $script:ExitReboot; RestartNeeded = $true; Message = $message }
            }
        }

        # 3. What is still installed of this language now: satellites that were added on their own.
        $rest = @(Get-LpiInstalledPackage -Refresh | Where-Object { $_.PackageName -match "(?i)~$escaped~" -and $_.PackageName -notmatch '^Microsoft-Windows-(Client|Lip)-LanguagePack-Package~' })
        foreach ($package in $rest) {
            Write-LpiLog -Message "Removing $($package.PackageName)"
            try {
                $result = Remove-WindowsPackage -Online -PackageName $package.PackageName -NoRestart -LogPath $dismLog -ErrorAction Stop
                if (Test-LpiRestartNeeded -Result $result) { $restartNeeded = $true }
            }
            catch { Write-LpiLog -Level Warning -Message "Could not remove $($package.PackageName): $($_.Exception.Message)" }
        }

        # 4. Basic and the font, now that nothing depends on them.
        foreach ($capability in @($basic) + @($font)) { if (Remove-LpiCapability -Name $capability.Name) { $restartNeeded = $true } }

        # 5. Nothing of this language may be left installed; otherwise fail and keep the registry entry, so a
        #    deployment still sees the language as installed. (Removals waiting for the restart do not count.)
        $leftCapabilities = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
                "$($_.State)" -eq 'Installed' -and ($_.Name -match $featurePattern -or @($font | ForEach-Object { $_.Name }) -contains $_.Name)
            })
        $leftPackages = @(Get-LpiInstalledPackage -Refresh | Where-Object { $_.PackageName -match "(?i)~$escaped~" -and "$($_.PackageState)" -eq 'Installed' })
        if ($leftCapabilities -or $leftPackages) {
            throw "$tag was not removed completely; still installed: $(@(@($leftCapabilities | ForEach-Object { $_.Name }) + @($leftPackages | ForEach-Object { $_.PackageName })) -join ', '). The registry entry is kept, so a deployment still sees $tag as installed. Restart and run the uninstall again; see the DISM log."
        }

        # 3. This installer's registry entries: the language's marker, then the cleanup policy if this installer
        #    set it and no language it installed is left, then its key if empty.
        $marker = Join-Path -Path $script:RegistryRoot -ChildPath "Languages\$tag"
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Recurse -Force; Write-LpiLog -Message "Removed $marker." }
        [void](Remove-LpiEmptyKey -Path (Join-Path -Path $script:RegistryRoot -ChildPath 'Languages'))
        $remaining = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:RegistryRoot -ChildPath 'Languages') -ErrorAction SilentlyContinue)
        $policySetByUs = $false
        try { $policySetByUs = [bool](Get-ItemProperty -LiteralPath $script:RegistryRoot -Name 'CleanupPolicySet' -ErrorAction Stop).CleanupPolicySet } catch { }
        if ($policySetByUs -and -not $remaining -and -not $KeepCleanupPolicy) {
            $policyKey = $script:CleanupPolicyKey
            Remove-ItemProperty -LiteralPath $policyKey -Name 'BlockCleanupOfUnusedPreinstalledLangPacks' -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $script:RegistryRoot -Name 'CleanupPolicySet' -ErrorAction SilentlyContinue
            foreach ($key in @($policyKey, (Split-Path -Path $policyKey -Parent))) { [void](Remove-LpiEmptyKey -Path $key) }
            Write-LpiLog -Message 'Removed BlockCleanupOfUnusedPreinstalledLangPacks: this installer set it and no language it installed is left.'
        }
        elseif ($remaining) {
            Write-LpiLog -Message "Kept BlockCleanupOfUnusedPreinstalledLangPacks: languages installed by this installer remain ($(@($remaining | ForEach-Object { $_.PSChildName }) -join ', '))."
        }
        [void](Remove-LpiEmptyKey -Path $script:RegistryRoot)

        # Per-user Active Setup left for this language (from an earlier display-language install) would add it again.
        $activeSetup = $script:ActiveSetupKey
        $stub = $null
        try { $stub = (Get-ItemProperty -LiteralPath $activeSetup -Name 'StubPath' -ErrorAction Stop).StubPath } catch { }
        if ($stub -and $stub -match "-Language $escaped(\s|$)") {
            Remove-Item -LiteralPath $activeSetup -Recurse -Force
            Write-LpiLog -Message "Removed the Active Setup entry that applied $tag to users."
        }

        $exitCode = $script:ExitSuccess
        $message = "$tag was uninstalled."
        if ($restartNeeded) { $exitCode = $script:ExitReboot; $message = "$tag was uninstalled. Restart the device to finish." }
        if ($wasDisplay) { $message = "$tag was uninstalled and the display language was set back to $installLanguage. Restart the device to finish." }
        Write-LpiLog -Message "$message Exit code $exitCode."
        Write-LpiLog -Message "Users who had $tag in their own language list keep the entry until they remove it in Settings > Time & language."
        return [pscustomobject]@{ ExitCode = $exitCode; RestartNeeded = $restartNeeded; Message = $message }
    }
    catch {
        Write-LpiLog -Level Error -Message "Uninstalling $tag failed: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = $script:ExitFailure; RestartNeeded = $restartNeeded; Message = $_.Exception.Message }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-LpiLog'
    'Write-LpiLog'
    'ConvertTo-LpiLanguageTag'
    'Get-LpiInstalledLanguageTag'
    'Get-LpiInstalledFeatureLanguageTag'
    'Get-LpiLanguageFile'
    'Get-LpiRepositoryLanguage'
    'Test-LpiPrerequisite'
    'Invoke-LpiInstall'
    'Uninstall-LpiLanguage'
    'Get-LpiInstallLanguageTag'
    'Test-LpiDisplayLanguage'
)
