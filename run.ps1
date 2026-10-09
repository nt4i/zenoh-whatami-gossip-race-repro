param(
    [string]$Toolchain = "1.97.1"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$baseCommit = "173b1220c2ab59cc22c82bfc6c95ac9971ff213b"
$repoUrl = "https://github.com/eclipse-zenoh/zenoh.git"
$workRoot = Join-Path $PSScriptRoot ".work"
$runDir = Join-Path $workRoot ([guid]::NewGuid().ToString("N"))
$zenohDir = Join-Path $runDir "zenoh"
$beforeLog = Join-Path $runDir "before.log"
$afterLog = Join-Path $runDir "after.log"

New-Item -ItemType Directory -Force -Path $runDir | Out-Null

Write-Host "Cloning eclipse-zenoh at $baseCommit ..."
& git -c core.longpaths=true clone --quiet --no-checkout $repoUrl $zenohDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed ($LASTEXITCODE)" }
& git -c core.longpaths=true -C $zenohDir checkout --quiet $baseCommit
if ($LASTEXITCODE -ne 0) { throw "git checkout failed ($LASTEXITCODE)" }

Write-Host "Adding the deterministic regression test ..."
& git -C $zenohDir apply (Join-Path $PSScriptRoot "regression-test.patch")
if ($LASTEXITCODE -ne 0) { throw "Applying regression-test.patch failed ($LASTEXITCODE)" }

$testArgs = @(
    "+$Toolchain", "test", "-p", "zenoh", "--features", "test", "--lib",
    "net::protocol::network::tests::test_reintroduced_node_role_is_filled_by_its_own_linkstate",
    "--", "--exact", "--nocapture"
)

Write-Host "Running against the unmodified base (failure is expected) ..."
Push-Location $zenohDir
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & cargo @testArgs *> $beforeLog
    $beforeExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
}
if ($beforeExit -eq 0) {
    throw "The regression unexpectedly passed before the fix. See $beforeLog"
}
$beforeText = Get-Content $beforeLog -Raw
if ($beforeText -notmatch 'left: None\s+right: Some\(Router\)') {
    Get-Content $beforeLog
    throw "The baseline failed for an unexpected reason. See $beforeLog"
}
Write-Host "Confirmed: baseline leaves whatami as None. Log: $beforeLog"

Write-Host "Applying the one-line PR fix and rerunning ..."
& git -C $zenohDir apply (Join-Path $PSScriptRoot "whatami-fix.patch")
if ($LASTEXITCODE -ne 0) { throw "Applying whatami-fix.patch failed ($LASTEXITCODE)" }
Push-Location $zenohDir
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & cargo @testArgs *> $afterLog
    $afterExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
}
Get-Content $afterLog
if ($afterExit -ne 0) { throw "The regression did not pass with the fix. See $afterLog" }

Write-Host "Confirmed: fixed source stores Some(Router). Logs are in $runDir"
