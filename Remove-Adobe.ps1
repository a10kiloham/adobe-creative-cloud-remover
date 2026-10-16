<#
.SYNOPSIS
    Completely removes Adobe Creative Cloud and all Adobe desktop applications from Windows.

.DESCRIPTION
    Kills Adobe processes, stops and disables Adobe services, silently uninstalls MSI-based
    Adobe products, runs Adobe's official Creative Cloud Cleaner Tool, then removes leftover
    registry keys, scheduled tasks, startup entries, folders and temp files.

    This file is intentionally plain ASCII. Windows PowerShell 5.1 reads scripts that have no
    byte-order mark using the system ANSI code page, and the emoji in the original version
    decoded to smart quotes that broke string parsing ("missing the terminator").

.PARAMETER Force
    Run unattended: no confirmation prompts and no "Press Enter" pause at the end.

.PARAMETER DryRun
    Report everything that would be stopped, uninstalled or deleted without changing anything.

.PARAMETER RemoveCreativeCloudFiles
    Also delete each user's "Creative Cloud Files" sync folder. This folder holds the user's own
    documents, so it is never touched unless this switch is given.

.PARAMETER SkipCleaner
    Do not launch the Adobe Creative Cloud Cleaner Tool.

.PARAMETER SilentCleaner
    Launch the Cleaner Tool with "--eulaAccepted=1 --removeAll=ALL" instead of interactively.
    These flags are only partly documented by Adobe; if the GUI appears anyway, follow it.

.PARAMETER CleanerPath
    Full path to AdobeCreativeCloudCleanerTool.exe. Default: search the script folder,
    C:\AdobeCreativeCloudCleanerTool_Win, Downloads and Desktop.

.PARAMETER NoElevate
    Internal. Prevents the script from relaunching itself as Administrator.

.EXAMPLE
    .\Remove-Adobe.ps1
.EXAMPLE
    .\Remove-Adobe.ps1 -DryRun
.EXAMPLE
    .\Remove-Adobe.ps1 -Force -SilentCleaner -RemoveCreativeCloudFiles
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun,
    [switch]$RemoveCreativeCloudFiles,
    [switch]$SkipCleaner,
    [switch]$SilentCleaner,
    [string]$CleanerPath,
    [switch]$NoElevate
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step  { param([string]$Text) Write-Host ""; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info  { param([string]$Text) Write-Host "  [INFO] $Text" -ForegroundColor Gray }
function Write-Warn  { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    if ($NoElevate) {
        Write-Warn "Not running as Administrator. Most removal steps will fail with Access Denied."
        if (-not $Force) {
            $answer = Read-Host "Continue anyway? (y/N)"
            if ($answer -notmatch '^[yY]') { exit 1 }
        }
    }
    else {
        Write-Host "Administrator rights are required. Requesting elevation..." -ForegroundColor Yellow
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-NoElevate')
        foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Key -eq 'NoElevate') { continue }
            if ($entry.Value -is [switch]) {
                if ($entry.Value.IsPresent) { $argList += ('-{0}' -f $entry.Key) }
            }
            else {
                $argList += ('-{0}' -f $entry.Key)
                $argList += ('"{0}"' -f $entry.Value)
            }
        }
        try {
            $hostExe = (Get-Process -Id $PID).Path
            Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
            exit 0
        }
        catch {
            Write-Fail "Elevation was refused or failed: $($_.Exception.Message)"
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$logDir  = Join-Path $env:TEMP 'AdobeRemover'
$logPath = Join-Path $logDir ('Remove-Adobe-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Start-Transcript -Path $logPath -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
}
catch {
    $transcriptStarted = $false
}

Write-Host ""
Write-Host "Adobe Creative Cloud Complete Removal Tool" -ForegroundColor Green
Write-Host ("=" * 50) -ForegroundColor Yellow
if ($transcriptStarted) { Write-Info "Log file: $logPath" }
if ($DryRun) { Write-Warn "DRY RUN - nothing will be changed." }

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if (-not $Force -and -not $DryRun) {
    Write-Host ""
    Write-Host "This will remove ALL Adobe Creative Cloud applications, Acrobat, Adobe services," -ForegroundColor Yellow
    Write-Host "registry keys and application data for every user on this computer." -ForegroundColor Yellow
    if ($RemoveCreativeCloudFiles) {
        Write-Host "It will ALSO DELETE every user's 'Creative Cloud Files' folder and its documents." -ForegroundColor Red
    }
    else {
        Write-Host "Your 'Creative Cloud Files' document folders will be left alone." -ForegroundColor Yellow
    }
    $answer = Read-Host "Type YES to continue"
    if ($answer -ne 'YES') {
        Write-Host "Aborted."
        if ($transcriptStarted) { Stop-Transcript | Out-Null }
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Shared data and helpers
# ---------------------------------------------------------------------------
$script:Stats = @{
    Processes  = 0
    Services   = 0
    Tasks      = 0
    Msi        = 0
    Registry   = 0
    Folders    = 0
    Failed     = 0
}

# Well-known Adobe process names (without .exe). Anything else running from an Adobe folder
# or with an Adobe company name is caught by the wildcard match below.
$adobeProcessNames = @(
    'Creative Cloud', 'Creative Cloud Helper', 'Creative Cloud UI Helper', 'CCXProcess', 'CCLibrary',
    'AdobeIPCBroker', 'Adobe Desktop Service', 'Adobe CEF Helper', 'Adobe Crash Processor',
    'AdobeUpdateService', 'AdobeCleanUpUtility', 'AdobeNotificationClient', 'AdobeCollabSync',
    'CoreSync', 'AdobeGCClient', 'AGSService', 'AGMService', 'armsvc', 'AdobeARM', 'acrotray',
    'Acrobat', 'AcroRd32', 'AcroCEF', 'RdrCEF', 'Photoshop', 'Illustrator', 'InDesign', 'InCopy',
    'AfterFX', 'Adobe Premiere Pro', 'Adobe Media Encoder', 'Adobe Bridge', 'Bridge', 'Lightroom',
    'Dreamweaver', 'Animate', 'Adobe Audition', 'Adobe Substance 3D Painter', 'Adobe XD',
    'dynamiclinkmanager', 'dynamiclinkmediaserver', 'PDApp', 'AAM Updates Notifier', 'LogTransport2',
    'Adobe Installer', 'Set-up', 'AdobeIPCBroker', 'Adobe QT32 Server'
)

$adobeServiceNames = @(
    'AdobeUpdateService', 'AGSService', 'AGMService', 'AdobeARMservice', 'armsvc',
    'Adobe Genuine Monitor Service', 'Adobe Genuine Software Integrity Service', 'Adobe LM Service',
    'AdobeDesktopService'
)

function Test-SafeDeletePath {
    # Refuse to delete anything that is not clearly an Adobe location.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $leafChain = $Path -replace '[\\/]+$', ''
    if ($leafChain.Length -lt 6) { return $false }          # e.g. "C:\" or "C:\X"
    if ($leafChain -match '^[A-Za-z]:$') { return $false }
    if ($leafChain -notmatch '(?i)adobe|creative cloud') { return $false }
    return $true
}

function Remove-Target {
    # Delete a file-system path safely and verify the result.
    param([string]$Path, [string]$Label)
    if (-not $Label) { $Label = $Path }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-SafeDeletePath $Path)) {
        Write-Warn "Refusing to delete non-Adobe path: $Path"
        return
    }
    if ($DryRun) { Write-Info "[DryRun] Would delete: $Label"; return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        # Fall through to the verification below; some files may be locked.
    }
    if (Test-Path -LiteralPath $Path) {
        $remaining = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue).Count
        Write-Warn ("Partially removed (locked files remain, {0} items): {1}" -f $remaining, $Label)
        $script:Stats.Failed++
    }
    else {
        Write-Ok "Deleted: $Label"
        $script:Stats.Folders++
    }
}

function Remove-RegistryKey {
    param([string]$Path, [string]$Label)
    if (-not $Label) { $Label = $Path }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($DryRun) { Write-Info "[DryRun] Would delete registry key: $Label"; return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Ok "Removed registry key: $Label"
        $script:Stats.Registry++
    }
    catch {
        Write-Warn "Could not remove registry key: $Label ($($_.Exception.Message))"
        $script:Stats.Failed++
    }
}

function Get-AdobeProcesses {
    $byName = @{}
    foreach ($n in $adobeProcessNames) { $byName[$n.ToLowerInvariant()] = $true }
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        if ($_.Id -eq $PID) { return $false }
        if ($byName.ContainsKey($_.ProcessName.ToLowerInvariant())) { return $true }
        $path = $null; $company = $null
        try { $path = $_.Path } catch { }
        try { $company = $_.Company } catch { }
        if ($path -and ($path -match '(?i)\\Adobe\\|\\Adobe |Creative Cloud')) { return $true }
        if ($company -and ($company -match '(?i)^Adobe')) { return $true }
        return $false
    }
}

function Stop-AdobeProcesses {
    param([int]$Passes = 3)
    for ($pass = 1; $pass -le $Passes; $pass++) {
        $procs = @(Get-AdobeProcesses)
        if ($procs.Count -eq 0) { break }
        foreach ($p in $procs) {
            if ($DryRun) { Write-Info ("[DryRun] Would kill: {0} (PID {1})" -f $p.ProcessName, $p.Id); continue }
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Ok ("Killed: {0} (PID {1})" -f $p.ProcessName, $p.Id)
                $script:Stats.Processes++
            }
            catch {
                Write-Warn ("Could not kill {0} (PID {1}): {2}" -f $p.ProcessName, $p.Id, $_.Exception.Message)
            }
        }
        if ($DryRun) { break }
        Start-Sleep -Seconds 2   # Adobe launchers respawn helpers; sweep again.
    }
}

function Get-AdobeServices {
    Get-Service -ErrorAction SilentlyContinue | Where-Object {
        ($adobeServiceNames -contains $_.Name) -or
        $_.Name -like 'Adobe*' -or
        $_.DisplayName -like '*Adobe*'
    }
}

function Get-AdobeUninstallEntries {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($hive in $hives) {
        if (-not (Test-Path $hive)) { continue }
        Get-ChildItem -Path $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { return }
            $displayName = ''; $publisher = ''; $uninstall = ''
            if ($props.PSObject.Properties['DisplayName'])     { $displayName = [string]$props.DisplayName }
            if ($props.PSObject.Properties['Publisher'])       { $publisher   = [string]$props.Publisher }
            if ($props.PSObject.Properties['UninstallString']) { $uninstall   = [string]$props.UninstallString }
            $isAdobe = ($publisher -match '(?i)^Adobe') -or ($displayName -match '(?i)^Adobe|Creative Cloud')
            if (-not $isAdobe) { return }
            [pscustomobject]@{
                KeyPath         = $_.PSPath
                KeyName         = $_.PSChildName
                DisplayName     = $displayName
                Publisher       = $publisher
                UninstallString = $uninstall
                IsMsi           = ($_.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') -or ($uninstall -match '(?i)msiexec')
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 1: Kill Adobe processes
# ---------------------------------------------------------------------------
Write-Step "Step 1/8: Stopping Adobe processes"
Stop-AdobeProcesses
if ($script:Stats.Processes -eq 0 -and -not $DryRun) { Write-Info "No Adobe processes were running." }

# ---------------------------------------------------------------------------
# Step 2: Stop and disable Adobe services
# ---------------------------------------------------------------------------
Write-Step "Step 2/8: Stopping and disabling Adobe services"
$adobeServices = @(Get-AdobeServices)
if ($adobeServices.Count -eq 0) { Write-Info "No Adobe services found." }
foreach ($svc in $adobeServices) {
    if ($DryRun) { Write-Info ("[DryRun] Would stop and disable service: {0} ({1})" -f $svc.Name, $svc.Status); continue }
    try {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $svc.Name -Force -ErrorAction Stop }
        Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
        Write-Ok "Stopped and disabled: $($svc.Name)"
        $script:Stats.Services++
    }
    catch {
        Write-Warn "Could not stop/disable $($svc.Name): $($_.Exception.Message)"
        $script:Stats.Failed++
    }
}

# ---------------------------------------------------------------------------
# Step 3: Remove Adobe scheduled tasks
# ---------------------------------------------------------------------------
Write-Step "Step 3/8: Removing Adobe scheduled tasks"
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like '*Adobe*' -or $_.TaskPath -like '*Adobe*' -or
        ($_.Actions | Where-Object { $_.PSObject.Properties['Execute'] -and $_.Execute -match '(?i)\\Adobe' })
    })
    if ($tasks.Count -eq 0) { Write-Info "No Adobe scheduled tasks found." }
    foreach ($task in $tasks) {
        if ($DryRun) { Write-Info "[DryRun] Would remove scheduled task: $($task.TaskPath)$($task.TaskName)"; continue }
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Ok "Removed scheduled task: $($task.TaskPath)$($task.TaskName)"
            $script:Stats.Tasks++
        }
        catch {
            Write-Warn "Could not remove task $($task.TaskName): $($_.Exception.Message)"
        }
    }
}
else {
    Write-Info "ScheduledTasks module not available; skipping."
}

# ---------------------------------------------------------------------------
# Step 4: Silently uninstall MSI-based Adobe products (Acrobat, Reader, etc.)
# ---------------------------------------------------------------------------
Write-Step "Step 4/8: Uninstalling MSI-based Adobe products"
$entries = @(Get-AdobeUninstallEntries)
$msiEntries = @($entries | Where-Object { $_.IsMsi -and $_.KeyName -match '^\{[0-9A-Fa-f\-]{36}\}$' })
if ($msiEntries.Count -eq 0) { Write-Info "No MSI-based Adobe products found." }
foreach ($entry in $msiEntries) {
    $label = if ($entry.DisplayName) { $entry.DisplayName } else { $entry.KeyName }
    if ($DryRun) { Write-Info "[DryRun] Would run: msiexec /x $($entry.KeyName) /qn /norestart  ($label)"; continue }
    Write-Info "Uninstalling $label ..."
    try {
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $entry.KeyName, '/qn', '/norestart') -Wait -PassThru -ErrorAction Stop
        switch ($p.ExitCode) {
            0    { Write-Ok "Uninstalled: $label"; $script:Stats.Msi++ }
            1605 { Write-Info "Already removed: $label" }
            3010 { Write-Ok "Uninstalled (reboot required): $label"; $script:Stats.Msi++ }
            default { Write-Warn "msiexec returned $($p.ExitCode) for $label"; $script:Stats.Failed++ }
        }
    }
    catch {
        Write-Warn "Could not run msiexec for ${label}: $($_.Exception.Message)"
        $script:Stats.Failed++
    }
}
$nonMsi = @($entries | Where-Object { -not $_.IsMsi })
if ($nonMsi.Count -gt 0) {
    Write-Info ("{0} Creative Cloud app(s) will be handled by the Cleaner Tool: {1}" -f $nonMsi.Count, (($nonMsi | ForEach-Object { $_.DisplayName }) -join ', '))
}

# ---------------------------------------------------------------------------
# Step 5: Run Adobe's Creative Cloud Cleaner Tool
# ---------------------------------------------------------------------------
Write-Step "Step 5/8: Running Adobe Creative Cloud Cleaner Tool"
if ($SkipCleaner) {
    Write-Info "Skipped (-SkipCleaner)."
}
else {
    $cleanerExe = $null
    if ($CleanerPath) {
        if (Test-Path -LiteralPath $CleanerPath) { $cleanerExe = $CleanerPath }
        else { Write-Warn "Cleaner not found at -CleanerPath: $CleanerPath" }
    }
    if (-not $cleanerExe) {
        $searchDirs = @(
            $PSScriptRoot,
            'C:\AdobeCreativeCloudCleanerTool_Win',
            (Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:PUBLIC 'Desktop')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        foreach ($dir in $searchDirs) {
            $hit = Get-ChildItem -LiteralPath $dir -Filter 'AdobeCreativeCloudCleanerTool.exe' -Recurse -Depth 1 -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $cleanerExe = $hit.FullName; break }
        }
    }

    if (-not $cleanerExe) {
        Write-Fail "AdobeCreativeCloudCleanerTool.exe was not found."
        Write-Host "    Download it from: https://helpx.adobe.com/creative-cloud/kb/cc-cleaner-tool-installation-problems.html" -ForegroundColor Yellow
        Write-Host "    Place it next to this script, or pass -CleanerPath <full path>." -ForegroundColor Yellow
        if (-not $Force -and -not $DryRun) {
            $answer = Read-Host "Continue with manual cleanup only? (y/N)"
            if ($answer -notmatch '^[yY]') {
                if ($transcriptStarted) { Stop-Transcript | Out-Null }
                exit 1
            }
        }
    }
    elseif ($DryRun) {
        Write-Info "[DryRun] Would launch: $cleanerExe"
    }
    else {
        Write-Info "Using: $cleanerExe"
        $cleanerLog = Join-Path $logDir 'CleanerTool.log'
        $launched = $false
        if ($SilentCleaner) {
            Write-Info "Launching in silent mode (--removeAll=ALL). If a window appears, follow the prompts."
            try {
                $p = Start-Process -FilePath $cleanerExe -ArgumentList @('--eulaAccepted=1', '--removeAll=ALL', ('--log="{0}"' -f $cleanerLog)) -Wait -PassThru -ErrorAction Stop
                if ($p.ExitCode -eq 0) { Write-Ok "Cleaner Tool finished (exit code 0)."; $launched = $true }
                else { Write-Warn "Cleaner Tool exited with code $($p.ExitCode); falling back to interactive mode." }
            }
            catch {
                Write-Warn "Silent launch failed: $($_.Exception.Message)"
            }
        }
        if (-not $launched) {
            Write-Host "    The Cleaner Tool window will open. In it:" -ForegroundColor Yellow
            Write-Host "      1. Accept the license agreement" -ForegroundColor White
            Write-Host "      2. Choose 'All' (or 'Creative Cloud 2017 and later')" -ForegroundColor White
            Write-Host "      3. Select 'Clean All', then click 'Cleanup Selected'" -ForegroundColor White
            Write-Host "      4. Close the tool when it reports completion" -ForegroundColor White
            try {
                $p = Start-Process -FilePath $cleanerExe -Wait -PassThru -ErrorAction Stop
                Write-Ok "Cleaner Tool closed (exit code $($p.ExitCode))."
            }
            catch {
                Write-Fail "Could not launch the Cleaner Tool: $($_.Exception.Message)"
                $script:Stats.Failed++
            }
        }
    }
    # The Cleaner can leave helper processes behind; sweep again before deleting files.
    Stop-AdobeProcesses -Passes 2
}

# ---------------------------------------------------------------------------
# Step 6: Registry cleanup
# ---------------------------------------------------------------------------
Write-Step "Step 6/8: Cleaning registry"
$registryKeys = @(
    'HKLM:\SOFTWARE\Adobe',
    'HKLM:\SOFTWARE\WOW6432Node\Adobe',
    'HKCU:\SOFTWARE\Adobe',
    'HKLM:\SOFTWARE\Policies\Adobe',
    'HKCU:\SOFTWARE\Policies\Adobe'
)
foreach ($key in $registryKeys) { Remove-RegistryKey -Path $key }

# Leftover uninstall entries (products the uninstallers or Cleaner did not clear).
foreach ($entry in @(Get-AdobeUninstallEntries)) {
    $label = if ($entry.DisplayName) { $entry.DisplayName } else { $entry.KeyName }
    Remove-RegistryKey -Path $entry.KeyPath -Label "Uninstall entry: $label"
}

# Startup (Run) values that point at Adobe executables.
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)
foreach ($runKey in $runKeys) {
    if (-not (Test-Path $runKey)) { continue }
    $props = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    foreach ($prop in $props.PSObject.Properties) {
        if ($prop.Name -like 'PS*') { continue }
        $value = [string]$prop.Value
        if ($prop.Name -match '(?i)adobe' -or $value -match '(?i)\\Adobe\\|Creative Cloud') {
            if ($DryRun) { Write-Info "[DryRun] Would remove startup entry: $($prop.Name)"; continue }
            try {
                Remove-ItemProperty -LiteralPath $runKey -Name $prop.Name -ErrorAction Stop
                Write-Ok "Removed startup entry: $($prop.Name)"
                $script:Stats.Registry++
            }
            catch {
                Write-Warn "Could not remove startup entry $($prop.Name): $($_.Exception.Message)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 7: File system cleanup
# ---------------------------------------------------------------------------
Write-Step "Step 7/8: Removing Adobe folders"
$programDirs = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
$systemPaths = @()
foreach ($dir in $programDirs) {
    $systemPaths += (Join-Path $dir 'Adobe')
    $systemPaths += (Join-Path $dir 'Common Files\Adobe')
}
$systemPaths += (Join-Path $env:ProgramData 'Adobe')
$systemPaths += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Adobe')
$systemPaths += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Adobe Creative Cloud')
$systemPaths += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Adobe Creative Cloud Experience')
foreach ($path in $systemPaths) { Remove-Target -Path $path }

# Per-user application data for every profile on the machine (the elevated session's own
# profile may not be the profile that used Creative Cloud).
$profileRoot = Split-Path -Parent $env:USERPROFILE
$profiles = @(Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') })
foreach ($userProfile in $profiles) {
    $userPaths = @(
        (Join-Path $userProfile.FullName 'AppData\Local\Adobe'),
        (Join-Path $userProfile.FullName 'AppData\LocalLow\Adobe'),
        (Join-Path $userProfile.FullName 'AppData\Roaming\Adobe'),
        (Join-Path $userProfile.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Adobe'),
        (Join-Path $userProfile.FullName 'AppData\Local\Temp\Adobe')
    )
    foreach ($path in $userPaths) { Remove-Target -Path $path -Label "$($userProfile.Name): $path" }

    $ccFiles = Join-Path $userProfile.FullName 'Creative Cloud Files'
    if (Test-Path -LiteralPath $ccFiles) {
        if ($RemoveCreativeCloudFiles) {
            Remove-Target -Path $ccFiles -Label "$($userProfile.Name): $ccFiles"
        }
        else {
            Write-Info "Kept user documents (use -RemoveCreativeCloudFiles to delete): $ccFiles"
        }
    }
}

# Desktop shortcuts
foreach ($desktop in @((Join-Path $env:PUBLIC 'Desktop'), (Join-Path $env:USERPROFILE 'Desktop'))) {
    if (-not (Test-Path -LiteralPath $desktop)) { continue }
    Get-ChildItem -LiteralPath $desktop -Filter 'Adobe*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Target -Path $_.FullName -Label "Shortcut: $($_.Name)"
    }
}

# ---------------------------------------------------------------------------
# Step 8: Final cleanup (temp files, orphaned services)
# ---------------------------------------------------------------------------
Write-Step "Step 8/8: Final cleanup"
$tempRoots = @((Join-Path $env:SystemRoot 'Temp'), $env:TEMP) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
foreach ($root in $tempRoots) {
    Get-ChildItem -LiteralPath $root -Filter 'Adobe*' -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Target -Path $_.FullName -Label "Temp: $($_.FullName)"
    }
}

# Delete service registrations whose binaries are now gone.
foreach ($svc in @(Get-AdobeServices)) {
    if ($DryRun) { Write-Info "[DryRun] Would delete service: $($svc.Name)"; continue }
    $out = & sc.exe delete $svc.Name 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "Deleted service: $($svc.Name)" }
    else { Write-Warn "Could not delete service $($svc.Name): $out" }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Yellow
if ($DryRun) {
    Write-Host "Dry run complete. Nothing was changed." -ForegroundColor Green
}
else {
    Write-Host "Adobe Creative Cloud removal completed." -ForegroundColor Green
    Write-Host ("  Processes killed:      {0}" -f $script:Stats.Processes)
    Write-Host ("  Services disabled:     {0}" -f $script:Stats.Services)
    Write-Host ("  Scheduled tasks:       {0}" -f $script:Stats.Tasks)
    Write-Host ("  MSI products removed:  {0}" -f $script:Stats.Msi)
    Write-Host ("  Registry keys removed: {0}" -f $script:Stats.Registry)
    Write-Host ("  Folders/files removed: {0}" -f $script:Stats.Folders)
    if ($script:Stats.Failed -gt 0) {
        Write-Host ("  Items needing a retry: {0}  (locked files - run again after rebooting)" -f $script:Stats.Failed) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Restart your computer to finish the removal." -ForegroundColor Yellow
}
if ($transcriptStarted) { Write-Info "Full log: $logPath" }

if ($transcriptStarted) { Stop-Transcript | Out-Null }
if (-not $Force) { Read-Host "Press Enter to exit" | Out-Null }
exit 0
