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
    <# The languages that have a language pack CAB in the repository, sorted by name. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [switch]$SkipInstalledCheck
    )
    $installed = @()
    if (-not $SkipInstalledCheck) { $installed = Get-LpiInstalledLanguageTag }

    $languages = foreach ($file in Get-ChildItem -LiteralPath $Repository -Filter 'Microsoft-Windows-*-Language-Pack_x64_*.cab' -File) {
        if ($file.Name -notmatch '^Microsoft-Windows-(Client|Lip)-Language-Pack_x64_(.+)\.cab$') { continue }
        $type = 'Full'
        if ($Matches[1] -eq 'Lip') { $type = 'Partial' }
        $tag = ConvertTo-LpiLanguageTag -Language $Matches[2]
        $displayName = $tag
        $nativeName = $tag
        try {
            $culture = [Globalization.CultureInfo]::GetCultureInfo($tag)
            $displayName = $culture.DisplayName
            $nativeName = $culture.NativeName
        }
        catch { }
        [pscustomobject]@{
            Tag         = $tag
            DisplayName = $displayName
            NativeName  = $nativeName
            Type        = $type
            PackagePath = $file.FullName
            Installed   = ($installed -contains $tag)
        }
    }
    return @($languages | Sort-Object -Property DisplayName)
}

#endregion

#region Prerequisites

function Test-LpiAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-LpiPrerequisite {
    <# Returns a list of problems that stop the installer from running; empty when all is well. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$UserScriptPath
    )
    $problems = New-Object System.Collections.Generic.List[string]

    if (-not (Test-LpiAdministrator)) {
        $problems.Add('The installer must run elevated (administrator or SYSTEM).')
    }
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
    if (-not (Test-Path -LiteralPath $Repository)) {
        $problems.Add("The language repository was not found: $Repository")
    }
    elseif (-not (Get-ChildItem -LiteralPath $Repository -Filter 'Microsoft-Windows-*-Language-Pack_x64_*.cab' -File)) {
        $problems.Add("The language repository contains no language pack CABs: $Repository")
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path -Path $Repository -ChildPath 'metadata'))) {
        $problems.Add("The language repository has no 'metadata' folder, which DISM needs to add language features: $Repository")
    }
    return , $problems.ToArray()
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

    if ($Language.Installed) {
        Write-LpiLog -Message "Language pack for $tag is already installed."
    }
    else {
        Write-LpiLog -Message "Adding language pack $(Split-Path -Path $Language.PackagePath -Leaf). This can take several minutes."
        $result = Add-WindowsPackage -Online -PackagePath $Language.PackagePath -NoRestart -LogPath $dismLog -ErrorAction Stop
        if (Test-LpiRestartNeeded -Result $result) { $restartNeeded = $true }
        Write-LpiLog -Message "Language pack for $tag added."
    }

    $capabilities = @($files | Where-Object { $_.Kind -in @('Feature', 'Font') })
    if (-not $capabilities) {
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
        }
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
    if ($attempted -eq 0) { Write-LpiLog -Message "No further $tag resources were needed for installed Features on Demand." }
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
    <# Stops Windows' LPRemove task from removing a language pack that no user has selected yet. #>
    Set-LpiRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Control Panel\International' `
        -Name 'BlockCleanupOfUnusedPreinstalledLangPacks' -Value 1 -Type DWord
    Write-LpiLog -Message 'Set BlockCleanupOfUnusedPreinstalledLangPacks so Windows does not remove unused language packs.'
}

#endregion

#region Display language (system and per-user)

function Publish-LpiUserScript {
    <#
        Copies Set-UserLanguage.ps1 to %ProgramData%\LanguagePackInstaller where standard users
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
    return $target
}

function Get-LpiUserScriptArgument {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Language,
        [switch]$SetRegionalFormat
    )
    $logs = Join-Path -Path $script:UserDataRoot -ChildPath 'Logs'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Language $Language -LogDirectory `"$logs`""
    if ($SetRegionalFormat) { $arguments += ' -SetRegionalFormat' }
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

function Register-LpiActiveSetup {
    <# Applies the per-user settings once to every other user at their next sign-in. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Arguments)
    $key = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\LanguagePackInstaller'
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-LpiRegistryValue -Path $key -Name '(Default)' -Value 'Language Pack Installer - user language settings'
    Set-LpiRegistryValue -Path $key -Name 'StubPath' -Value "`"$powershell`" $Arguments"
    # A higher version makes Active Setup run again for users who already ran an older one.
    Set-LpiRegistryValue -Path $key -Name 'Version' -Value (Get-Date -Format 'yyyy,MMdd,HHmm,ss')
    Set-LpiRegistryValue -Path $key -Name 'IsInstalled' -Value 1 -Type DWord
    Write-LpiLog -Message 'Registered Active Setup: other existing users get the language settings at their next sign-in.'
}

function Set-LpiDisplayLanguage {
    <#
        System part: system preferred UI language, Welcome screen and new-user defaults, and
        optionally the system locale. User part: the signed-in user(s), and optionally every
        other existing user at next sign-in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$UserScriptPath,
        [switch]$SetRegionalFormat,
        [switch]$ApplyToExistingUsers
    )
    $tag = ConvertTo-LpiLanguageTag -Language $Language

    Write-LpiLog -Message "Setting the system preferred UI language to $tag."
    Set-SystemPreferredUILanguage -Language $tag -ErrorAction Stop

    # Copy-UserInternationalSettingsToSystem copies the *running* account's settings, so set
    # them on this account first (SYSTEM under ConfigMgr). Run the copy from the package
    # source, not the user-writable ProgramData area, because this runs elevated.
    Write-LpiLog -Message "Applying $tag to the running account ($([Security.Principal.WindowsIdentity]::GetCurrent().Name))."
    $powershell = Join-Path -Path $env:windir -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-LpiUserScriptArgument -ScriptPath $UserScriptPath -Language $tag -SetRegionalFormat:$SetRegionalFormat
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "Applying the language to the running account failed (exit code $($process.ExitCode)). See the user logs in $(Join-Path $script:UserDataRoot 'Logs')."
    }

    Write-LpiLog -Message 'Copying the language settings to the Welcome screen and new user accounts.'
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop

    $publishedScript = Publish-LpiUserScript -UserScriptPath $UserScriptPath
    $userArguments = Get-LpiUserScriptArgument -ScriptPath $publishedScript -Language $tag -SetRegionalFormat:$SetRegionalFormat

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
                Write-LpiLog -Level Warning -Message "The user step for $user failed (exit code $exitCode). See the user logs in $(Join-Path $script:UserDataRoot 'Logs')."
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
        if (-not $entry) { throw "No language pack for $tag was found in $Repository." }

        if (Install-LpiLanguage -Repository $Repository -Language $entry) { $restartNeeded = $true }
        if (Install-LpiFodSatellite -Repository $Repository -Language $tag) { $restartNeeded = $true }
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
        Write-LpiLog -Message "$message Exit code $exitCode."
        return [pscustomobject]@{ ExitCode = $exitCode; RestartNeeded = $restartNeeded; Message = $message }
    }
    catch {
        Write-LpiLog -Level Error -Message "Installing $tag failed: $($_.Exception.Message)"
        return [pscustomobject]@{ ExitCode = $script:ExitFailure; RestartNeeded = $restartNeeded; Message = $_.Exception.Message }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-LpiLog'
    'Write-LpiLog'
    'ConvertTo-LpiLanguageTag'
    'Get-LpiInstalledLanguageTag'
    'Get-LpiLanguageFile'
    'Get-LpiRepositoryLanguage'
    'Test-LpiAdministrator'
    'Test-LpiPrerequisite'
    'Invoke-LpiInstall'
)
