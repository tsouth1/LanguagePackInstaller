# LanguagePackInstaller

Windows 11 Language Installer for SCCM. It installs a language from your own language
repository (CABs from the Languages and Optional Features ISO) and can make it the display
language. It has a Windows Forms GUI, and a silent mode for fixed-language deployments.

Supports **Windows 11 24H2 (build 26100) and later**, client editions only.

| File | Purpose |
|---|---|
| `Install-LanguagePack.ps1` | Entry point. GUI (language drop-down, "Set as display language") or `-Silent`. |
| `LanguagePackInstaller.psm1` | Core logic: repository discovery, DISM install, system settings, per-user hand-off. |
| `Set-UserLanguage.ps1` | Per-user (HKCU) settings. Runs as each user, never on behalf of one. |
| `New-LanguageRepository.ps1` | Builds a trimmed repository for chosen languages from the LOF ISO. |
| `languagecabs.csv` | Listing of the 24H2 LOF ISO `LanguagesAndOptionalFeatures` folder, for reference. |

## Why DISM and not `Install-Language`

`Install-Language` (LanguagePackManagement) has no source parameter: it always downloads from
Windows Update or the Store, which fails on WSUS- or ConfigMgr-managed devices. This installer
adds the CABs with DISM (`Add-WindowsPackage` / `Add-WindowsCapability -Source -LimitAccess`)
and uses LanguagePackManagement for the system settings afterwards (`Set-SystemPreferredUILanguage`).

## System-wide vs per-user settings

| Setting | Cmdlet | Scope | Stored in | Needs |
|---|---|---|---|---|
| Language pack, language features, fonts | `Add-WindowsPackage`, `Add-WindowsCapability` | **System** | Component store | Admin/SYSTEM, sometimes restart |
| Translated resources for installed FODs (Notepad, Paint, RSAT...) | `Add-WindowsPackage` | **System** | Component store | Admin/SYSTEM |
| System preferred UI language | `Set-SystemPreferredUILanguage` | **System** | HKLM | Admin, restart |
| Welcome screen and new-user defaults | `Copy-UserInternationalSettingsToSystem` | **System**, copied *from the running account* | HKLM, Default user hive | Admin |
| System locale (non-Unicode programs) | `Set-WinSystemLocale` | **System** | HKLM | Admin, restart |
| Keep unused language packs | `BlockCleanupOfUnusedPreinstalledLangPacks` policy | **System** | HKLM | Admin |
| Display language for a user | `Set-WinUILanguageOverride` | **User** | `HKCU\Control Panel\Desktop` | Sign-out |
| Language list and keyboards | `Set-WinUserLanguageList` | **User** | `HKCU\Control Panel\International\User Profile`, `HKCU\Keyboard Layout` | |
| Regional format | `Set-Culture` | **User** | `HKCU\Control Panel\International` | |
| Country or region | `Set-WinHomeLocation` | **User** | `HKCU\Control Panel\International\Geo` | |

The per-user cmdlets have no `-User` parameter. Run as SYSTEM, they change SYSTEM's own
settings and the actual user sees nothing. So the installer:

1. Applies the user settings to the **running account** (SYSTEM under ConfigMgr), then runs
   `Copy-UserInternationalSettingsToSystem`, so the **Welcome screen and new users** get them.
2. Runs `Set-UserLanguage.ps1` as **each signed-in user** through a one-shot scheduled task
   (`LogonType Interactive`, no password needed when SYSTEM registers it).
3. With `-ApplyToExistingUsers`, registers **Active Setup** so every other existing profile
   gets the settings once at its next sign-in.

PSAppDeployToolkit is not required. See [Using PSAppDeployToolkit 4.x](#using-psappdeploytoolkit-4x)
if you want to wrap it anyway.

## What a run does

1. Checks the prerequisites: elevated, 64-bit, build 26100 or later, client OS, LanguagePackManagement
   available, repository has language packs and `metadata`.
2. Adds the language pack CAB (skipped if already installed).
3. Adds the language features in order: Basic, script font (ja/ko/zh/ar/he/th), OCR,
   Handwriting, TextToSpeech, Speech. It uses `Add-WindowsCapability` and falls back to the CAB
   if that fails. Only a Basic failure stops the run.
4. Adds this language's satellite CABs for Features on Demand that are already installed.
5. Sets `BlockCleanupOfUnusedPreinstalledLangPacks`, so Windows' `LPRemove` task does not remove
   a language no one has selected yet (skip with `-AllowLanguageCleanup`).
6. If **Set as display language** is ticked: runs the system and per-user steps above.
   Optionally sets the regional format and country/region as well.
7. Writes `HKLM\SOFTWARE\LanguagePackInstaller\Languages\<tag>` (`InstalledOn`, `Source`) and, for
   the display language, `HKLM\SOFTWARE\LanguagePackInstaller\DisplayLanguage`.

## Building the repository

```powershell
# What is on the ISO?
.\New-LanguageRepository.ps1 -Source F:\LanguagesAndOptionalFeatures -ListAvailable

# Build or extend a repository (run again later to add languages)
.\New-LanguageRepository.ps1 -Source F:\LanguagesAndOptionalFeatures -Destination \\server\LangRepo -Language de-DE, fr-FR, ja-JP
```

It copies the `metadata` folder, plus each language's language pack, features, font and FOD
satellites (`-SkipFodSatellites` leaves the satellites out). Keep the repository out of Git
(`.gitignore` already excludes `Repository/` and `*.cab`).

The LOF media must match the OS build: 26100 media covers 24H2 and 25H2 (25H2 is an enablement
package on 26100). After you add languages, the next cumulative update brings their resources
up to date, so add languages before patching where you can.

Partial languages (ca-ES, eu-ES, gl-ES, id-ID, vi-VN) need a base language installed first. The
installer warns if none of the usual base languages is present.

## Running it

```powershell
# GUI (prompts for elevation if needed). The repository defaults to .\Repository
.\Install-LanguagePack.ps1 -Repository \\server\LangRepo

# Silent, fixed language
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LanguagePack.ps1 `
    -Repository \\server\LangRepo -Language de-DE -SetDisplayLanguage -Silent
```

| Parameter | Effect |
|---|---|
| `-Repository` | Repository folder or UNC path. Default: `Repository` next to the script. |
| `-Language` | Language tag. Required with `-Silent`; preselects it in the GUI. |
| `-SetDisplayLanguage` | System default + Welcome screen + new users + signed-in user(s). |
| `-SetRegionalFormat` | With `-SetDisplayLanguage`: regional format and country/region as well. |
| `-SetSystemLocale` | Language for non-Unicode programs (restart). |
| `-ApplyToExistingUsers` | With `-SetDisplayLanguage`: every other existing profile at its next sign-in (Active Setup). |
| `-AllowLanguageCleanup` | Don't set the policy that keeps unused language packs. |
| `-Silent` | No GUI. |
| `-LogPath` | Log folder. Default: `%windir%\Logs\LanguagePackInstaller`. |

**Exit codes:** `0` success, `3010` success with a restart needed (any display-language change
returns this), `1602` GUI closed without installing, `1603` failure.

**Logs** (CMTrace format):
- `%windir%\Logs\LanguagePackInstaller\LanguagePackInstaller.log`: main log.
- `%windir%\Logs\LanguagePackInstaller\LanguagePackInstaller-DISM.log`: DISM detail.
- `%ProgramData%\LanguagePackInstaller\Logs\User-<username>.log`: per-user steps.

## Deploying with ConfigMgr

Create an **Application** with a Script Installer deployment type:

- **Program:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-LanguagePack.ps1 -Repository \\server\LangRepo`
  (add `-Language xx-XX -SetDisplayLanguage -Silent` for a fixed-language app).
- **Installation behavior:** Install for system.
- **GUI version only:** Logon requirement "Only when a user is logged on" and tick **"Allow users
  to view and interact with the program installation"**. Otherwise the form, which runs as
  SYSTEM, is invisible.
- **Return codes:** keep the defaults: 3010 is a soft reboot and 1602 is a cancel.
- **Detection method:** registry key `HKLM\SOFTWARE\LanguagePackInstaller\Languages\<tag>` exists
  (fixed-language app), or `HKLM\SOFTWARE\LanguagePackInstaller\DisplayLanguage` equals `<tag>`.
  For the GUI version, which can install any language, any value you want to re-run on works.
- **Repository on a share:** SYSTEM reaches it as the computer account, so give **Domain
  Computers** read access to the share and NTFS. Alternatively, put the repository in the
  package content as `Repository\`. That's simpler but larger (a language with its features and
  satellites is typically 100-300 MB).

## Using PSAppDeployToolkit 4.x

Not needed, but if you standardise on it, call the script from the `Install` section of
`Invoke-AppDeployToolkit.ps1` and map its exit code:

```powershell
$result = Start-ADTProcess -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($adtSession.DirFiles)\Install-LanguagePack.ps1`" -Repository \\server\LangRepo -Language de-DE -SetDisplayLanguage -Silent" `
    -SuccessExitCodes 0 -RebootExitCodes 3010 -PassThru
```

PSADT's own dialogs show in the user session without the ConfigMgr "allow interaction" option,
but this script's WinForms GUI does not. Use `-Silent` under PSADT, or pick the language with
PSADT prompts. `Start-ADTProcessAsUser` is a drop-in alternative to the scheduled-task user step.

## Status

The repository discovery, CAB matching and FOD-satellite selection have been tested against the
24H2 LOF listing in `languagecabs.csv`. The DISM, LanguagePackManagement, scheduled-task and
WinForms parts still need testing on a real Windows 11 24H2 device. Start on a VM snapshot.
