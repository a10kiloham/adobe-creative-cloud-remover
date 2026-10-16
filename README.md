# Adobe Creative Cloud Complete Removal Tool

A PowerShell script that completely removes Adobe Creative Cloud, every Creative Cloud desktop app, Acrobat and all related services, scheduled tasks, registry keys and application data from Windows.

> **This is a fork** of [eugene8080/adobe-creative-cloud-remover](https://github.com/eugene8080/adobe-creative-cloud-remover).
> The original `Remove-Adobe.ps1` failed to parse on Windows PowerShell 5.1 and had several
> safety gaps. See [What changed in this fork](#what-changed-in-this-fork) below.

## The problem this solves

Trying to uninstall Creative Cloud usually ends with:

> "Adobe components are open. Please close all Adobe applications and try again."

Adobe runs a dozen or more hidden background processes and services that respawn each other, so neither the normal uninstaller nor Adobe's own Creative Cloud Cleaner Tool can get a clean run. This script kills everything Adobe, disables the services so nothing respawns, runs the official Cleaner Tool in that clean state, then sweeps up what is left.

## Files

| File | Purpose |
| --- | --- |
| `Remove-Adobe.ps1` | The removal script (plain ASCII, Windows PowerShell 5.1 and PowerShell 7 compatible) |
| `Run_Adobe_Remover.bat` | Double-click launcher. Self-elevates to Administrator and bypasses the execution policy |
| `adobe_complete_remover.py` | Legacy Python alternative from the original project. Untouched and untested in this fork |

## Quick start

1. Download the [Adobe Creative Cloud Cleaner Tool](https://helpx.adobe.com/creative-cloud/kb/cc-cleaner-tool-installation-problems.html) and put `AdobeCreativeCloudCleanerTool.exe` in the same folder as the script. The script also looks in `C:\AdobeCreativeCloudCleanerTool_Win`, your Downloads folder and your Desktop.
2. Back up anything you care about. Your `Creative Cloud Files` sync folder is **not** deleted unless you ask for it, but everything else Adobe-related is.
3. Double-click `Run_Adobe_Remover.bat`. Approve the UAC prompt, read the warning and type `YES`.
4. When the Cleaner Tool window opens, accept the EULA, choose **All**, tick **Clean All** and click **Cleanup Selected**. Close it when it finishes.
5. Restart Windows.

To preview what would happen without changing anything, open PowerShell in the folder and run:

```powershell
.\Remove-Adobe.ps1 -DryRun
```

## Command-line options

```powershell
.\Remove-Adobe.ps1 [-Force] [-DryRun] [-RemoveCreativeCloudFiles] [-SkipCleaner] [-SilentCleaner] [-CleanerPath <path>]
```

| Switch | Effect |
| --- | --- |
| `-DryRun` | Lists every process, service, task, product, key and folder it would touch. Changes nothing |
| `-Force` | No confirmation prompt and no "Press Enter" pause. Use for unattended runs |
| `-RemoveCreativeCloudFiles` | Also deletes each user's `Creative Cloud Files` folder. **This deletes your documents** |
| `-SkipCleaner` | Do not launch the Cleaner Tool |
| `-SilentCleaner` | Launches the Cleaner Tool with `--eulaAccepted=1 --removeAll=ALL`. These flags are only partly documented by Adobe; if the GUI appears anyway, follow it |
| `-CleanerPath` | Full path to `AdobeCreativeCloudCleanerTool.exe` if it is somewhere unusual |

The batch file passes any arguments through, so `Run_Adobe_Remover.bat -Force -SilentCleaner` works too.

A full transcript of every run is written to `%TEMP%\AdobeRemover\Remove-Adobe-<timestamp>.log`.

## What the script does

1. **Kills Adobe processes.** Matches a list of known Adobe executables plus any process running from an Adobe folder or signed by an Adobe company name. Sweeps three times because Creative Cloud respawns its helpers.
2. **Stops and disables Adobe services** (`AdobeUpdateService`, `AGSService`, `AGMService`, `AdobeARMservice` and anything else with Adobe in its name), whether or not they are currently running.
3. **Removes Adobe scheduled tasks** such as the Genuine Service invoker and Acrobat update task.
4. **Silently uninstalls MSI-based Adobe products** (Acrobat, Reader, older suites) with `msiexec /x /qn` so Programs & Features stays consistent.
5. **Runs the official Creative Cloud Cleaner Tool** to remove Creative Cloud and all CC apps.
6. **Cleans the registry**: `HKLM\SOFTWARE\Adobe`, the WOW6432Node copy, `HKCU\SOFTWARE\Adobe`, leftover uninstall entries in all three uninstall hives, and startup `Run` values that point at Adobe.
7. **Deletes Adobe folders** under Program Files, Program Files (x86), Common Files, ProgramData, Start Menu, plus `AppData\Local`, `LocalLow` and `Roaming` for **every user profile** on the machine, and Adobe desktop shortcuts.
8. **Final sweep**: Adobe temp folders and deletion of the now-orphaned service registrations.

Every deletion goes through a guard that refuses to remove any path that does not contain "Adobe" or "Creative Cloud", so a bad environment variable cannot turn into deleting a drive or a user profile.

## What changed in this fork

### The parse error

Running the original script produced:

```
Unexpected token '}' in expression or statement.
The string is missing the terminator: ".
```

The original file was saved as UTF-8 **without** a byte-order mark and contained emoji in its strings. Windows PowerShell 5.1 reads a BOM-less script using the system ANSI code page (Windows-1252 on most machines). The emoji byte sequences contain `0x93` and `0x94`, which in Windows-1252 are the curly quotes `“` and `”`. PowerShell treats curly quotes as string delimiters, so every emoji silently opened or closed a string and the parser lost track. That is also why the "no emojis" copy in the original repo worked.

The fix: the script is now plain ASCII, so it parses identically on Windows PowerShell 5.1 and PowerShell 7 regardless of code page. A `.gitattributes` file keeps the `.ps1` and `.bat` files CRLF so GitHub zip downloads open cleanly in Notepad.

### Safety fixes

- **User documents are no longer deleted by default.** The original removed `%USERPROFILE%\Creative Cloud Files`, the local copy of the user's own work, with no opt-out. It is now opt-in via `-RemoveCreativeCloudFiles`.
- **Errors were invisible.** Every `Remove-Item` used `-ErrorAction SilentlyContinue` inside a `try/catch`, so the `catch` could never fire and the script printed "Removed" even when nothing was removed. Deletions now use `-ErrorAction Stop`, verify with `Test-Path` afterwards and report partial removals and locked files in the summary.
- **Uninstall entries were deleted before uninstalling.** The original wiped every `*Adobe*` key from the Uninstall hive at the start, which orphans installed products and makes them impossible to remove through Programs & Features. MSI products are now uninstalled properly first; leftover entries are only cleared at the end.
- **A path guard** refuses to delete anything whose path does not mention Adobe or Creative Cloud.
- **`-DryRun`** lets you see the full plan before committing.
- **Self-elevation.** Both the batch file and the script relaunch themselves as Administrator instead of continuing without rights and failing on every step.
- **Transcript logging** of every run.

### Efficacy fixes

- Process names were wrong for several apps (`Premiere Pro` is actually `Adobe Premiere Pro`, Bridge is `Adobe Bridge`, Audition is `Adobe Audition`, and so on). The script now also matches on executable path and company name, so renamed or unlisted Adobe helpers are caught too.
- Processes are killed in repeated passes, because Creative Cloud respawns helpers within a second or two.
- Services that were stopped but still set to Automatic were never disabled. They are now disabled regardless of state and deleted at the end.
- Services and uninstall entries in the 32-bit `WOW6432Node` hive were missed. Both hives plus `HKCU` are now scanned.
- Scheduled tasks and startup `Run` entries, which Adobe uses to relaunch its services, were never removed. They are now.
- Only the current user's AppData was cleaned, and when elevated that is often the wrong profile. All profiles under `C:\Users` are now cleaned.
- The Cleaner Tool is searched for in several locations and can be pointed to with `-CleanerPath`, instead of a single hard-coded path.
- `Remove-Adobe-Working.ps1` was removed; it only existed as an emoji-free workaround for the parse bug.

## Troubleshooting

**"Running scripts is disabled on this system"**
Use the batch file, which passes `-ExecutionPolicy Bypass`, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Remove-Adobe.ps1
```

**"Items needing a retry" in the summary**
Some files were locked. Reboot and run the script again; the second pass normally clears them.

**The Cleaner Tool was not found**
Download it from Adobe's site and place it next to the script, or pass `-CleanerPath "C:\path\to\AdobeCreativeCloudCleanerTool.exe"`.

**Something Adobe is still listed in Programs & Features after a reboot**
Run the script a second time. If an entry persists, it is a non-MSI product whose uninstaller the Cleaner Tool skipped; uninstall it from Programs & Features and run the script once more to clear the leftovers.

## Verification done in this fork

- Parsed with the PowerShell 7.4 parser: no errors.
- Linted with PSScriptAnalyzer: no errors. Remaining warnings are style rules (`Write-Host` in an interactive console tool, plural nouns).
- Confirmed the file is pure ASCII.
- The deletion guard and the verified-delete helper were unit-tested on Linux.
- The full end-to-end run (process kill, services, registry, Cleaner Tool) requires a Windows machine with Creative Cloud installed and was **not** exercised here. Run `-DryRun` first.

## Legal and safety

- Uses only built-in Windows commands plus Adobe's own Cleaner Tool.
- Removes Adobe components only. The path guard prevents deleting anything else.
- Reversible by reinstalling Adobe products.
- Run at your own risk. Back up first.
