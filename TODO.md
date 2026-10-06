# TODO - LanguagePackInstaller

Last updated: 2026-10-06.

| # | Item | Status |
|---|------|--------|
| [1](#1) | GUI: uninstall an installed language from the window (and reset the display language to the default) | Done 2026-10-04 (tested on a VM: fr-FR display language reset to en-US and uninstalled, then de-DE) |
| [2](#2) | GUI: easier-to-read colours and larger fonts for large, high-resolution screens | Built 2026-10-04 (tested on the real form at 100 %, 150 %/200 % simulated); check on a scaled screen |
| [3](#3) | Real tests still open: the corrected uninstall, a run as SYSTEM from ConfigMgr, the display-language path | Open; ConfigMgr run 2026-10-05: user display language fixed (PreferredUILanguages), Active Setup not running |
| [4](#4) | Feature-only languages (en-AU, de-CH, zh-HK, ...) | Built 2026-10-04 (mock-tested); test a real install on a VM |
| [5](#5) | GUI: Restart button in the "installed" message, with "Restart now? Click the Restart button below." | Built 2026-10-06 (tested on the real form, install and restart mocked); confirm on a real device |

---

<a id="1"></a>
## 1. GUI: uninstall an installed language from the window

**Asked 2026-10-04.** **Built 2026-10-04**, still to test on a real device (a VM snapshot: it changes the display language).

**Built:**
- Window: **Uninstall this language** for an installed language (greyed out, with the reason, for the language Windows was installed with); ticking it asks first (`Confirm-UninstallChoice`: restart required, and the display-language reset when it applies; Cancel unticks it); the button then reads **Uninstall** and the install options are greyed out; the uninstall runs in the background runspace like an install; choosing another language unticks it.
- `Uninstall-LpiLanguage -ResetDisplayLanguage -UserScriptPath` (also `Uninstall-LanguagePack.ps1 -ResetDisplayLanguage`): a display language (the system's, or the one this tool set - `Test-LpiDisplayLanguage`) is first set back to `Get-LpiInstallLanguageTag` by `Reset-LpiDisplayLanguage` (`Set-LpiDisplayLanguage` for the default language with `-RemoveLanguage`, Active Setup kept if it was used, `DisplayLanguage` value removed), then removed. If Windows will not remove its language pack yet, `Register-LpiUninstallTask` registers the one-shot SYSTEM startup task `LanguagePackInstaller-CompleteUninstall-<tag>` (running a copy in %ProgramData%; `-FromStartupTask` removes the task when done) and the result is 3010 with the registry entry kept.
- `Set-UserLanguage.ps1 -RemoveLanguage`: takes the removed language out of the user's language list.
- Tests: 8 more uninstall checks (28, PS 5.1 and 7; `Set-UserLanguage.ps1` with the language-list cmdlets replaced) and `Test-Gui.ps1` (7 checks on the real form) in `LanguagePackInstaller-Tests`.

**Wanted (as asked):**
- When the language picked in the drop-down is already installed (`[installed]`), show a check box **Uninstall this language**.
- Ticking it switches the window to uninstalling: the install options (Set as display language, regional format) are greyed out and the Install button reads **Uninstall**.
- If the language is the display language, uninstalling it **also sets the display language back to the default** first.
- When the user ticks Uninstall, show a message that **a restart will be required** (with OK / Cancel; Cancel unticks it). After the uninstall, the result message says to restart (exit code 3010).

**Design notes (to settle while building):**
- **The default display language** = the language Windows was installed with (`Get-LpiInstallLanguageTag`, from `Nls\Language\InstallLanguage`; en-US on the test PC). Never offer Uninstall for that language itself: show the check box greyed out with "Windows was installed with this language; it cannot be removed".
- **Resetting the display language** is the display-language install in reverse, for the default language: the system preferred UI language (`Set-SystemPreferredUILanguage`), the Welcome screen and new users (`Copy-UserInternationalSettingsToSystem`), each signed-in user (`Set-UserLanguage.ps1` through the one-shot scheduled task), the Active Setup entry (removed or pointed at the default language), and `HKLM\SOFTWARE\LanguagePackInstaller\DisplayLanguage`.
- **Today `Uninstall-LpiLanguage` refuses** the system display language and the display language this tool set (1603). It needs an option (for example `-ResetDisplayLanguage`, also on `Uninstall-LanguagePack.ps1` for silent use) that resets first, then removes.
- **Order to test on a VM:** Windows may refuse to remove the language pack of the language still in use until the restart that applies the default. If so: reset now, register a one-shot SYSTEM startup task (as `Complete-SystemLanguage.ps1` does) that removes the language after the restart, and say so in the message.
- Per-user language lists keep the removed language until each user removes it (as the uninstall already notes); the reset should at least take it out of the signed-in users' lists.
- Tests: the GUI wiring on a real form (as the screenshot harness does), and the reset + removal order with DISM and the language cmdlets mocked.

---

<a id="2"></a>
## 2. GUI: easier-to-read colours and larger fonts

**Asked 2026-10-04.** Assume a large, high-resolution screen. **Built 2026-10-04**; still to see on a real 150 %/200 % screen (the test PC is 3440x1440 at 100 %).

**Built:**
- `Enable-DpiAwareness` (`SetProcessDPIAware`) before any window, `AutoScaleMode = Dpi` (designed at 96 DPI).
- Fixed colours: background `#F3F4F6`, white header / fields / log, text `#111827`, hints `#4B5563`, flat blue main button `#0F6CBD` with white text (light grey `#D1D5DB` while busy), flat white Close button with a grey border.
- Fonts: Segoe UI 11 pt (hints 10 pt), title Segoe UI Semibold 15 pt, log Consolas 10.5 pt. Window 680x604 with a header ("Install a language from the language repository, or uninstall one.").
- Controls named (`LanguageList`, `DisplayLanguage`, `Uninstall`, `UninstallReason`, `Log`, `Install`, `Close`).
- Tests: `Test-Gui.ps1` now 13 checks (fonts, colours, the busy button colour, DPI setup, no overlap or clipping at 100 % and simulated 150 %/200 %), PS 5.1 and 7. Screenshot retaken.

**Wanted:**
- Colours that are easier to read: clear contrast between text, input fields, the log box and the buttons (for example dark text on white fields over a light neutral background, one accent colour for the main button, a clearly readable log box).
- Slightly larger fonts: Segoe UI about 10.5-11 pt for the window (9 pt today), Consolas about 10 pt for the log (8.5 pt today), with the window and controls sized to fit.

**Design notes:**
- **DPI awareness:** WinForms in Windows PowerShell 5.1 is not DPI-aware, so on a high-resolution screen with scaling Windows stretches the window as a bitmap and the text looks blurry. Make the form DPI-aware before it is created (`SetProcessDPIAware` / per-monitor awareness, `AutoScaleMode = Dpi`) so text is drawn sharp at the real resolution, then check the layout at 100 %, 150 % and 200 % scaling.
- The window runs as SYSTEM in the user's session (ConfigMgr "allow users to interact"); colours should not depend on the user's theme. Keep the message boxes as they are (system dialogs).
- Update `images/installer-gui.png` and the README screenshot afterwards.

---

<a id="3"></a>
## 3. Real tests still open

- **The corrected uninstall** (2026-10-04, removal order): run `Uninstall-LanguagePack.ps1 -Language de-DE` once more on the test PC to remove the leftover `Language.Basic~~~de-DE` (expected exit 0), then a full install + uninstall from a clean start.
- **A run as SYSTEM from a ConfigMgr application** (the administrator checks were removed for this): install and uninstall programs, exit codes 0 / 3010 / 1603, the detection method, the repository on a share (computer-account access).
- **The display-language path** (`-SetDisplayLanguage`): the system part and the restart task (`LanguagePackInstaller-CompleteSystemLanguage`) passed on a VM 2026-10-04 (fr-FR); still open: another signed-in user, Active Setup for other profiles.
- **ConfigMgr run as SYSTEM, es-ES on a domain-joined Windows 11 device (2026-10-05, logs uploaded with 4b9748d):** install exit 3010, the restart task set the system language and the Welcome screen came up in Spanish. **The signed-in user stayed English** after the restart and after another sign-out: their language list (`es-ES, en-US`) and override (es-ES) were set, but `HKCU\Control Panel\Desktop\PreferredUILanguages` still held `en-US`, and Windows signs in with that value. Setting it to es-ES by hand and signing out/in gave Spanish. **Fixed:** `Set-UserLanguage.ps1` now writes `PreferredUILanguages` as well (and removes a stale `PreferredUILanguagesPending`), logs the value it found, and logs a line when `-OnlyUsers` skips an account instead of exiting silently (4 new checks in `Test-DisplayLanguage.ps1`, which also had a quoting bug in its `-OnlyUsers` check; 16 + 28 checks pass on PS 5.1 and 7). **To confirm:** a fresh install on that device or another domain profile.
- **Open: the Active Setup entry never ran for the signed-in user** (same device). The HKLM entry is correct (StubPath, `-OnlyUsers` with the user's SID, Version `2026,1005,1234,35`, IsInstalled 1), but there is no HKCU Version for it after two sign-ins, while 6 other Active Setup entries have run for that user. Next: compare our HKLM entry with those that run (value types, key name, Version format).

---

<a id="4"></a>
## 4. Feature-only languages

The Languages and Optional Features media has 92 language variants with language features but no language pack (for example en-AU, en-CA, en-IN, de-CH, fr-BE, fr-CH, es-US, zh-HK, hi-IN). Windows uses them as additional languages (keyboard, spelling, speech, regional format) on top of a display language.

**Built 2026-10-04:**
- `Get-LpiRepositoryLanguage` lists them after the language-pack languages (Type `Features`); the window marks them `[features only]` and greys out the display options with the reason. `-SetDisplayLanguage` with one fails (1603) before anything is added.
- `Install-LpiLanguage` adds only their features (Basic first, Speech after TextToSpeech, as the metadata's dependencies require) and their script font; 25 of them need one (from `DesktopTargetCompDB_Conditions`: Deva, Beng, Arab, Hant, ...), added to `$script:FontScripts`. No satellites (the media has none for them). Fails only when none of their features could be added.
- Installed detection from their feature packages (`Get-LpiInstalledFeatureLanguageTag`); the uninstall works unchanged and keeps a script font another installed language still uses.
- Names for the three tags Windows PowerShell 5.1 has none for (fj-FJ, kok-Deva-IN, sco-Latn). `New-LanguageRepository.ps1` copies them too.
- Tests: `Test-FeatureOnly.ps1` (19 checks on the real folder with DISM mocked) and 2 more window checks (`Test-Gui.ps1`, 21), PS 5.1 and 7.

**Still to test:** a real install and uninstall of a feature-only language with a font (hi-IN or zh-HK) on a VM; adding it in Settings afterwards without a download.

---

<a id="5"></a>
## 5. GUI: Restart button in the "installed" message

**Asked 2026-10-06.** **Built 2026-10-06** (tested on the real form with the install and the restart mocked); confirm on a real device.

**Wanted:**
- The message that says the language pack is installed gets a **Restart** button.
- Its text gains **"Restart now? Click the Restart button below."**

**Built:**
- `Show-RestartPrompt`: a small dialog in the window's theme (a `MessageBox` cannot name its buttons) with the result message, "A restart is required to finish." and "Restart now? Click the Restart button below.", a blue **Restart** button and **Close**. Close has the focus and is the Esc / title-bar X answer, so Enter never restarts by accident. Sized by a table layout, so it fits the text at any DPI.
- Shown whenever the run ends with 3010 - an install and also an uninstall (both say to restart). Exit code 0 keeps the plain OK message.
- **Restart** (`Start-LpiRestart`): `shutdown.exe /r /t 15 /d p:4:2` (Application: Installation, planned), logged, and the window closes, so the script still exits with 3010 before the restart (ConfigMgr records the result). If shutdown.exe fails, a warning says to restart from the Start menu. **Close**: logged, the window's log says "Restart the device later to finish.", nothing else changes.
- Silent runs (`-Silent`) never show it; ConfigMgr still gets 3010 and handles the restart itself.
- Tests: `Test-Gui.ps1` 10 more checks (31; PS 5.1 and 7): the dialog's text, buttons, colours, focus and layout; Restart returns true, Close and X false; on the window, through a fake install module - 3010 shows the dialog over the window in its theme, Restart restarts once (mocked) and closes with 3010, Close leaves the window open, exit 0 shows the plain message and no dialog.

**To confirm on a real device:** an install that needs a restart from the window - press Close once (window stays), then a second install or uninstall and press Restart: the device restarts after about 15 seconds and the log ends with `finished with exit code 3010`.

---

## Done

- 2026-10-06: item 5 built - Restart button in the "restart needed" message (install and uninstall), delayed restart so the exit code still reaches ConfigMgr. `Test-Gui.ps1` 31 checks.

- 2026-10-04: item 4 built - feature-only languages (install their features and font; no display language). `-LightTheme` switch; Windows postponing the system display language until the restart is now logged as information, not a warning.

- 2026-10-04: dark theme, the default, with a **Light theme** / **Dark theme** button in the header that switches to the original (light) colours and back. Dark title bar (DWM) and log scroll bar (`DarkMode_Explorer`); greyed-out check boxes redrawn in plain grey (Windows draws them embossed, unreadable on dark). `Test-Gui.ps1` 17 checks; screenshots of both themes.

- 2026-10-04: item 1 tested on a VM - fr-FR (display language) reset to en-US and uninstalled, de-DE uninstalled, 3010 each, no DISM errors.
- 2026-10-04: item 2 built - DPI-aware window, larger fonts, fixed high-contrast colours; README screenshot retaken.
- 2026-10-04: item 1 built - uninstall from the window, with the display language set back to the default first (`-ResetDisplayLanguage`); README screenshot retaken. Windows allows, final check, refusals, cleanup policy only when this tool set it); administrator checks removed (runs as SYSTEM); `New-LanguageRepository.ps1` takes several languages from `powershell.exe -File`; README screenshot; merged to `main` (#2, #3).
- 2026-10-03: validated against the real `LanguagesAndOptionalFeatures` folder on Windows 11 25H2 (43 languages, 82 FOD satellites each).
