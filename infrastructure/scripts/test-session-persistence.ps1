<#
.SYNOPSIS
    ROADMAP Phase 1 criterion: an active user session survives a Keycloak restart.

.DESCRIPTION
    Keycloak 26 stores user sessions in PostgreSQL (persistent sessions) rather
    than only in memory, so a replica restart must not log anyone out. This is a
    load-bearing assumption for the Azure Container Apps design (design.md §2):
    ACA restarts and rescales replicas routinely.

    The test:
      1. Logs in with Authorization Code + PKCE, keeping the SSO cookies.
      2. Restarts the Keycloak container and waits for it to report ready.
      3. Re-runs an authorization request with those same cookies and asserts
         Keycloak issues a code WITHOUT rendering the login form - i.e. the
         Cookie authenticator matched a session that outlived the restart.

.PARAMETER FullRestart
    Use `down` + `up` instead of `restart`, which also proves the session
    survives the container being recreated (not just the process restarting).

.EXAMPLE
    .\infrastructure\scripts\test-session-persistence.ps1
    .\infrastructure\scripts\test-session-persistence.ps1 -FullRestart
#>
[CmdletBinding()]
param(
    [switch]$FullRestart
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$ComposeFile = Join-Path $RepoRoot 'infrastructure\compose\docker-compose.yml'

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    # docker compose writes progress to stderr; under $ErrorActionPreference='Stop'
    # PowerShell 5.1 turns that into a terminating NativeCommandError even on
    # exit code 0. Relax the preference around the call and trust $LASTEXITCODE.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker compose -f $ComposeFile --env-file $EnvFile @ComposeArgs 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($ComposeArgs -join ' ') failed ($LASTEXITCODE)" }
}

function Wait-ForKeycloak {
    param([int]$TimeoutSeconds = 240)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((& docker inspect -f '{{.State.Health.Status}}' kc-poc-keycloak 2>$null) -eq 'healthy') { return $true }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 5
    }
    return $false
}

Write-Host ''
Write-Host '=== Persistent user session across restart ===' -ForegroundColor Cyan
$dotenv = Get-DotEnv

# --- 1. Establish a session ---
Write-Host ''
Write-Host '1. Establish an SSO session' -ForegroundColor Cyan
$login = Invoke-PkceLogin -Username $dotenv['POC_TEST_USER'] -Password $dotenv['POC_TEST_PASSWORD']
Assert-That -Name 'Initial login succeeds' -Condition ([bool]$login.Success) -Detail $login.Error
if (-not $login.Success) { Write-TestSummary }

Assert-That -Name 'Login required the password form' -Condition ($login.PromptedForPassword -eq $true)

$tokens = Invoke-TokenExchange -Code $login.Code -Verifier $login.Verifier
$claims = ConvertFrom-JwtPayload $tokens.access_token
$sessionId = $claims.sid
Write-Host "  session id: $sessionId" -ForegroundColor DarkGray

# Cookies carrying the SSO session (KEYCLOAK_IDENTITY / KEYCLOAK_SESSION).
$ssoJar = $login.Jar

# --- 2. Restart Keycloak ---
Write-Host ''
if ($FullRestart) {
    Write-Host '2. Recreating the Keycloak container (down + up)' -ForegroundColor Cyan
    Invoke-Compose @('rm', '-sf', 'keycloak')
    Invoke-Compose @('up', '-d', 'keycloak')
}
else {
    Write-Host '2. Restarting the Keycloak container' -ForegroundColor Cyan
    Invoke-Compose @('restart', 'keycloak')
}

Write-Host '   waiting for ready' -NoNewline
$ready = Wait-ForKeycloak
Write-Host ''
Assert-That -Name 'Keycloak returns to healthy after restart' -Condition $ready
if (-not $ready) { Write-TestSummary }

# Healthy != serving. Until the realm endpoint answers for real, an authorize
# request comes back as "Bootstrap in progress" and looks exactly like a lost
# session. See Wait-ForRealmEndpoint.
$serving = Wait-ForRealmEndpoint
Assert-That -Name 'Realm endpoint is serving again' -Condition $serving
if (-not $serving) { Write-TestSummary }

# --- 3. Session must have survived ---
Write-Host ''
Write-Host '3. Re-authorize with the pre-restart cookies' -ForegroundColor Cyan
$again = Invoke-PkceLogin -Jar $ssoJar

Assert-That -Name 'Authorization succeeds after restart' -Condition ([bool]$again.Success) -Detail $again.Error
Assert-That -Name 'No password prompt (Cookie authenticator matched)' `
            -Condition ($again.PromptedForPassword -eq $false) `
            -Detail 'Session was lost - Keycloak fell back to the login form.'

if ($again.Success) {
    $tokens2 = Invoke-TokenExchange -Code $again.Code -Verifier $again.Verifier
    $claims2 = ConvertFrom-JwtPayload $tokens2.access_token
    Assert-That -Name 'Same session id before and after restart' `
                -Condition ($claims2.sid -eq $sessionId) `
                -Detail "before: $sessionId  after: $($claims2.sid)"
}

Write-TestSummary
