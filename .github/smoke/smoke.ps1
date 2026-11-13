# Smoke test of one momentry release on Windows (Windows PowerShell 5.1), run by .github/workflows/smoke.yml on the
# assets exactly as they were uploaded to the (draft) release. Same checks as smoke.sh; the hook probe runs the hook
# from a parent that put itself in a Job Object that kills its members when it closes, as agent hosts do.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File smoke.ps1 -Tag <tag> -Assets <assets dir> [-Previous <dir>]
# -Previous, when the dir holds TAG and install.ps1 (the workflow fills it from the latest published release), adds
# the update check; without it the check is skipped. No token is in the environment.
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Assets,
    [string]$Previous = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail([string]$Message) { Write-Host "::error::$Message"; exit 1 }
function Step([string]$Message) { Write-Host ''; Write-Host "== $Message" }
function Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

# -cmatch with \z: no newline or other character may follow the tag
function Test-Tag([string]$Value) { $Value -cmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?\z' }
if (-not (Test-Tag $Tag)) { Fail "not a release tag: $Tag" }
$Assets = (Resolve-Path -LiteralPath $Assets).Path
$Version = $Tag.Substring(1)
$Archive = "momentry-$Tag-windows-amd64.tar.gz"
$Work = Join-Path ([IO.Path]::GetTempPath()) ("momentry-smoke-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
# GitHub's Windows runners run as Administrator; the installer refuses that unless told otherwise.
$env:MOMENTRY_ALLOW_ROOT = '1'
$env:MOMENTRY_NO_MODIFY_PATH = '1'

# Paths and hashes of a version dir, to prove a step left it untouched.
function Get-TreeDigest([string]$Dir) {
    $lines = Get-ChildItem -LiteralPath $Dir -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Dir.Length)
        if ($_.PSIsContainer) { $rel } else { "$rel $(Sha256 $_.FullName)" }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

# A fresh profile with the installer's default layout; doctor needs a claude CLI on PATH, so a stub stands in
# for it (the smoke tests momentry, not Claude Code; no model is ever called).
function Use-Profile([string]$Name) {
    $h = Join-Path $Work $Name
    $local = Join-Path $h 'AppData\Local'
    $roaming = Join-Path $h 'AppData\Roaming'
    New-Item -ItemType Directory -Path $local, $roaming, (Join-Path $h '.claude'), (Join-Path $Work 'stub') -Force | Out-Null
    $env:HOME = $h; $env:USERPROFILE = $h; $env:LOCALAPPDATA = $local; $env:APPDATA = $roaming
    foreach ($k in 'MOMENTRY_HOME', 'MOMENTRY_INSTALL_DIR', 'MOMENTRY_RELEASE_BASE') { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    Set-Content -LiteralPath (Join-Path $Work 'stub\claude.cmd') -Encoding ASCII -Value '@echo 2.1.0 (Claude Code)'
    if (($env:PATH -split ';') -notcontains (Join-Path $Work 'stub')) { $env:PATH = (Join-Path $Work 'stub') + ';' + $env:PATH }
    $script:MDir = Join-Path $local 'momentry\app'
    $script:Shim = Join-Path $local 'momentry\bin\momentry.cmd'
}

function Install-From([string]$Dir) {
    $env:MOMENTRY_RELEASE_BASE = $Dir
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'install.ps1') | Out-Host } finally { Remove-Item env:MOMENTRY_RELEASE_BASE }
    return $LASTEXITCODE
}

function Assert-Version([string]$Want) {
    $got = & $Shim --version
    if ($LASTEXITCODE -ne 0) { Fail 'momentry --version failed' }
    if ($got -ne "momentry $($Want.Substring(1))") { Fail "momentry --version says '$got', want 'momentry $($Want.Substring(1))'" }
}

function Get-Current { (Get-Content -Raw -LiteralPath (Join-Path $MDir 'current')).Trim() }

# privacy source, a git repo, init: what doctor needs to say ok
function Initialize-Repo {
    & $Shim config privacy-add 'Smoke Probe Name' | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'momentry config privacy-add failed' }
    $script:RepoDir = Join-Path $env:USERPROFILE 'repo'
    New-Item -ItemType Directory -Path $RepoDir -Force | Out-Null
    & git -C $RepoDir init -q
    Push-Location $RepoDir
    try { & $Shim init --yes } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { Fail 'momentry init --yes failed' }
}

try {
    Step "checksums.txt of $Tag"
    $sums = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $Assets 'checksums.txt')) {
        if ($line -match '^([0-9a-f]{64})  \*?(\S+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
    if (-not $sums.ContainsKey($Archive)) { Fail "checksums.txt does not list $Archive" }
    foreach ($name in $sums.Keys) {
        if ((Sha256 (Join-Path $Assets $name)) -ne $sums[$name]) { Fail "$name does not match checksums.txt" }
    }

    Step 'install with install.ps1'
    Use-Profile 'main'
    if ((Install-From $Assets) -ne 0) { Fail 'install.ps1 failed' }
    Assert-Version $Tag
    $vdir = Join-Path $MDir "versions\$Tag"
    if ((Get-Current) -ne $Tag) { Fail "current is not $Tag" }

    Step 'the installed tree is exactly BUILD.files'
    $build = Get-Content -Raw -LiteralPath (Join-Path $vdir 'BUILD') | ConvertFrom-Json
    if ("$($build.target.goos)/$($build.target.goarch)" -ne 'windows/amd64') { Fail "BUILD.target is $($build.target.goos)/$($build.target.goarch)" }
    $want = @($build.files | ForEach-Object { $_.path } | Sort-Object)
    $have = @(Get-ChildItem -LiteralPath $vdir -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($vdir.Length + 1).Replace('\', '/') } |
        Where-Object { $_ -ne 'BUILD' } | Sort-Object)
    if (($want -join "`n") -cne ($have -join "`n")) {
        Compare-Object $want $have | Format-Table | Out-String | Write-Host
        Fail "the files of $vdir differ from BUILD.files"
    }
    foreach ($f in $build.files) {
        if ((Sha256 (Join-Path $vdir $f.path)) -ne $f.sha256) { Fail "$($f.path) does not match its BUILD.files sha256" }
    }

    Step 'doctor --json'
    Initialize-Repo
    $doctor = (& $Shim doctor --json) -join "`n" | ConvertFrom-Json
    if ($doctor.schema -ne 1) { Fail 'doctor --json: schema is not 1' }
    if ($doctor.ok -ne $true) {
        $doctor.data.checks | Where-Object { $_.status -ne 'ok' } | ForEach-Object { Write-Host "$($_.code): $($_.status) $($_.detail)" }
        Fail 'doctor --json: ok is not true'
    }

    Step 'reinstalling the same release changes nothing'
    $before = Get-TreeDigest $vdir
    if ((Install-From $Assets) -ne 0) { Fail 'the second install.ps1 exited non-zero' }
    if ((Get-Current) -ne $Tag) { Fail 'current changed on reinstall' }
    if ((Get-TreeDigest $vdir) -ne $before) { Fail "reinstall changed $vdir" }

    Step 'a tampered archive is refused'
    $tampered = Join-Path $Work 'tampered'
    New-Item -ItemType Directory -Path $tampered | Out-Null
    Copy-Item -Path (Join-Path $Assets '*') -Destination $tampered
    $bytes = [IO.File]::ReadAllBytes((Join-Path $tampered $Archive))
    $bytes[100] = $bytes[100] -bxor 0xFF
    [IO.File]::WriteAllBytes((Join-Path $tampered $Archive), $bytes)
    if ((Install-From $tampered) -eq 0) { Fail "install.ps1 accepted a tampered $Archive" }
    if ((Get-Current) -ne $Tag) { Fail 'current changed after a refused install' }
    if ((Get-TreeDigest $vdir) -ne $before) { Fail "a refused install changed $vdir" }

    Step "hook probe: the harvest the hook starts outlives a parent whose Job Object kills its members on close"
    $mark = Join-Path $Work 'mark'
    New-Item -ItemType Directory -Path $mark | Out-Null
    $parent = Join-Path $Work 'parent.ps1'
    Set-Content -LiteralPath $parent -Encoding ASCII -Value @'
param([string]$Shim, [string]$Repo)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ProbeJob {
    [StructLayout(LayoutKind.Sequential)] struct Basic {
        public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong R, W, O, RB, WB, OB; }
    [StructLayout(LayoutKind.Sequential)] struct Extended {
        public Basic BasicLimits; public IoCounters Io; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, ref Extended info, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    // KILL_ON_JOB_CLOSE (0x2000): closing the last handle kills every member; BREAKAWAY_OK (0x800): a child
    // created with CREATE_BREAKAWAY_FROM_JOB leaves the job, the documented way out.
    public static IntPtr Enter() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception();
        Extended info = new Extended();
        info.BasicLimits.LimitFlags = 0x2000 | 0x800;
        if (!SetInformationJobObject(job, 9, ref info, (uint)Marshal.SizeOf(typeof(Extended)))) throw new Win32Exception();
        if (!AssignProcessToJobObject(job, GetCurrentProcess())) throw new Win32Exception();
        return job;
    }
}
"@
$job = [ProbeJob]::Enter()
Set-Location -LiteralPath $Repo
'{}' | & $Shim hook session-start | Out-Null
exit $LASTEXITCODE
'@
    $env:MOMENTRY_PROBE_MARK = $mark
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File $parent -Shim $Shim -Repo $RepoDir } finally { Remove-Item env:MOMENTRY_PROBE_MARK }
    if ($LASTEXITCODE -ne 0) { Fail "the hook's parent exited $LASTEXITCODE" }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not ((Test-Path (Join-Path $mark 'start')) -and (Test-Path (Join-Path $mark 'alive')))) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path (Join-Path $mark 'start'))) { Fail 'no start marker: the hook did not start a harvest' }
    if (-not (Test-Path (Join-Path $mark 'alive'))) { Fail 'start marker but no alive marker within 60 s: the harvest died with the Job Object of its parent' }

    Step 'update from the previous release'
    $prevTagFile = if ($Previous) { Join-Path $Previous 'TAG' } else { '' }
    if (-not $prevTagFile -or -not (Test-Path -LiteralPath $prevTagFile)) {
        Write-Host 'bo qua: chua co ban truoc (skipped: no previous release)'
    } else {
        $prev = (Get-Content -Raw -LiteralPath $prevTagFile).Trim()
        if (-not (Test-Tag $prev)) { Fail 'the previous release tag is not a release tag' }
        $prevInstaller = Join-Path $Previous 'install.ps1'
        if (-not (Test-Path -LiteralPath $prevInstaller)) { Fail "no install.ps1 of $prev in $Previous" }
        Use-Profile 'update'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $prevInstaller | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail "installing $prev from the public release failed" }
        Assert-Version $prev
        Initialize-Repo
        $settings = Sha256 (Join-Path $env:USERPROFILE '.claude\settings.json')
        $env:MOMENTRY_RELEASE_BASE = $Assets
        try { & $Shim update --version $Tag --yes } finally { Remove-Item env:MOMENTRY_RELEASE_BASE }
        if ($LASTEXITCODE -ne 0) { Fail "momentry update $prev -> $Tag failed" }
        Assert-Version $Tag
        if (-not (Test-Path -LiteralPath (Join-Path $MDir "versions\$prev"))) { Fail "update removed the previous version $prev" }
        if ((Sha256 (Join-Path $env:USERPROFILE '.claude\settings.json')) -ne $settings) { Fail 'update changed the hooks in .claude\settings.json' }
        & $Shim uninstall --yes | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'uninstall after the update failed' }
    }

    Step 'uninstall'
    Use-Profile 'main'
    & $Shim uninstall --yes
    if ($LASTEXITCODE -ne 0) { Fail 'momentry uninstall --yes failed' }

    Step "smoke passed: $Tag on windows/amd64"
} finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
