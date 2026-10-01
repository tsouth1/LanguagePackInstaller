#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a language repository for Install-LanguagePack.ps1 from the Windows 11
    Languages and Optional Features (LOF) media.

.DESCRIPTION
    Copies only what the chosen languages need from the LanguagesAndOptionalFeatures folder:
      - the metadata folder (DISM needs it to add language features from the folder)
      - each language's language pack CAB (full or partial/LIP)
      - its language features (Basic, Handwriting, OCR, Speech, TextToSpeech) and script font
      - its satellite CABs for other Features on Demand (Notepad, Paint, RSAT...), unless
        -SkipFodSatellites is used

    The LOF media must match the Windows build it is installed on (26100 media for 24H2/25H2).

.PARAMETER Source
    The LanguagesAndOptionalFeatures folder from the LOF ISO, for example F:\LanguagesAndOptionalFeatures.

.PARAMETER Destination
    The repository folder to create or update, local or UNC.

.PARAMETER Language
    One or more language tags, for example de-DE, fr-FR, ja-JP.

.PARAMETER SkipFodSatellites
    Do not copy the per-language CABs for other Features on Demand.

.PARAMETER ListAvailable
    List the languages available in -Source and exit.

.EXAMPLE
    .\New-LanguageRepository.ps1 -Source F:\LanguagesAndOptionalFeatures -ListAvailable

.EXAMPLE
    .\New-LanguageRepository.ps1 -Source F:\LanguagesAndOptionalFeatures -Destination \\server\LangRepo -Language de-DE, fr-FR, ja-JP
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory, ParameterSetName = 'Build')][string]$Destination,
    [Parameter(Mandatory, ParameterSetName = 'Build')][string[]]$Language,
    [Parameter(ParameterSetName = 'Build')][switch]$SkipFodSatellites,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$ListAvailable
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'LanguagePackInstaller.psm1') -Force

if (-not (Test-Path -LiteralPath $Source)) { throw "Source folder not found: $Source" }
$metadata = Join-Path -Path $Source -ChildPath 'metadata'
if (-not (Test-Path -LiteralPath $metadata)) { throw "No 'metadata' folder in $Source. Point -Source at the LanguagesAndOptionalFeatures folder." }

$available = @(Get-LpiRepositoryLanguage -Repository $Source -SkipInstalledCheck)
if ($ListAvailable) {
    $available | Select-Object -Property Tag, DisplayName, NativeName, Type | Format-Table -AutoSize
    return
}

$tags = foreach ($item in $Language) { ConvertTo-LpiLanguageTag -Language $item }
$missing = @($tags | Where-Object { $available.Tag -notcontains $_ })
if ($missing) {
    throw "No language pack in $Source for: $($missing -join ', '). Use -ListAvailable to see what is there."
}

if (-not (Test-Path -LiteralPath $Destination)) { New-Item -Path $Destination -ItemType Directory -Force | Out-Null }
$destinationMetadata = Join-Path -Path $Destination -ChildPath 'metadata'
if (-not (Test-Path -LiteralPath $destinationMetadata)) { New-Item -Path $destinationMetadata -ItemType Directory -Force | Out-Null }

Write-Host "Copying metadata from $metadata"
Copy-Item -Path (Join-Path -Path $metadata -ChildPath '*') -Destination $destinationMetadata -Force

$sourceFiles = Get-ChildItem -LiteralPath $Source -Filter '*.cab' -File
$totalBytes = 0
foreach ($tag in $tags) {
    $entry = $available | Where-Object { $_.Tag -eq $tag } | Select-Object -First 1
    $files = Get-LpiLanguageFile -Path $Source -Language $tag -IncludeSatellites:(-not $SkipFodSatellites) -Files $sourceFiles
    $bytes = ($files | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    $totalBytes += $bytes
    $summary = ($files | Group-Object -Property Kind | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    Write-Host ('{0} ({1}): {2} files, {3:N0} MB [{4}]' -f $entry.DisplayName, $tag, $files.Count, ($bytes / 1MB), $summary)
    foreach ($item in $files) {
        Copy-Item -LiteralPath $item.File.FullName -Destination $Destination -Force
    }
}

# Files copied from an ISO are read-only; clear that so the repository can be updated later.
Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }

Write-Host ('Repository ready: {0} ({1:N0} MB of language files)' -f $Destination, ($totalBytes / 1MB))
