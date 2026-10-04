# TODO - LanguagePackInstaller

Last updated: 2026-10-04.

| # | Item | Status |
|---|------|--------|
| [1](#1) | GUI: uninstall an installed language from the window (and reset the display language to the default) | Built 2026-10-04 (mock-tested; the check box tested on the real form); test on a VM |
| [2](#2) | GUI: easier-to-read colours and larger fonts for large, high-resolution screens | Built 2026-10-04 (tested on the real form at 100 %, 150 %/200 % simulated); check on a scaled screen |
| [3](#3) | Real tests still open: the corrected uninstall, a run as SYSTEM from ConfigMgr, the display-language path | Open |
| [4](#4) | Feature-only languages (en-AU, de-CH, zh-HK, ...) cannot be added | Idea |

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
- **The display-language path** (`-SetDisplayLanguage`): the system part, the restart task (`LanguagePackInstaller-CompleteSystemLanguage`), the signed-in user step, Active Setup for other profiles. On a VM snapshot.

---

<a id="4"></a>
## 4. Feature-only languages

The Languages and Optional Features media has 92 language variants with language features but no language pack (for example en-AU, en-CA, en-IN, de-CH, fr-BE, fr-CH, es-US, zh-HK, hi-IN). The installer offers only languages with a language pack, so it cannot add them. Windows uses them as additional languages (keyboard, spelling, speech, regional format) on top of a display language. Possible addition: list them separately and install their features only.

---

## Done

- 2026-10-04: item 2 built - DPI-aware window, larger fonts, fixed high-contrast colours; README screenshot retaken.
- 2026-10-04: item 1 built - uninstall from the window, with the display language set back to the default first (`-ResetDisplayLanguage`); README screenshot retaken. Windows allows, final check, refusals, cleanup policy only when this tool set it); administrator checks removed (runs as SYSTEM); `New-LanguageRepository.ps1` takes several languages from `powershell.exe -File`; README screenshot; merged to `main` (#2, #3).
- 2026-10-03: validated against the real `LanguagesAndOptionalFeatures` folder on Windows 11 25H2 (43 languages, 82 FOD satellites each).
