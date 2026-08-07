<#
.SYNOPSIS
    Lifecycle helper for the Keycloak PoC stack.

.DESCRIPTION
    Wraps docker compose so you don't have to remember the -f/--env-file paths.

.EXAMPLE
    .\infrastructure\scripts\poc.ps1 up
    .\infrastructure\scripts\poc.ps1 status
    .\infrastructure\scripts\poc.ps1 reset     # destroys the database volume
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'down', 'reset', 'restart-keycloak', 'status', 'logs', 'export-realm')]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [string]$Service
)

$ErrorActionPreference = 'Stop'

$RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ComposeFile = Join-Path $RepoRoot 'infrastructure\compose\docker-compose.yml'
$EnvFile     = Join-Path $RepoRoot '.env'
$EnvExample  = Join-Path $RepoRoot '.env.example'

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    # docker compose writes progress to stderr; under $ErrorActionPreference='Stop'
    # PowerShell 5.1 turns that into a terminating NativeCommandError even on
    # exit code 0. Relax the preference around the call and trust $LASTEXITCODE.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker compose -f $ComposeFile --env-file $EnvFile @ComposeArgs
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($ComposeArgs -join ' ') failed with exit code $LASTEXITCODE" }
}

function Initialize-EnvFile {
    if (-not (Test-Path $EnvFile)) {
        Write-Host "No .env found - creating one from .env.example" -ForegroundColor Yellow
        Copy-Item $EnvExample $EnvFile
        Write-Host "  -> $EnvFile (local dev passwords; never commit this file)" -ForegroundColor Yellow
    }
}

function Wait-ForKeycloak {
    param([int]$TimeoutSeconds = 240)

    Write-Host "Waiting for Keycloak to report ready..." -NoNewline
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = (& docker inspect -f '{{.State.Health.Status}}' kc-poc-keycloak 2>$null)
        if ($state -eq 'healthy') {
            Write-Host " healthy." -ForegroundColor Green
            return $true
        }
        if ($state -eq 'unhealthy') {
            Write-Host " unhealthy." -ForegroundColor Red
            return $false
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 5
    }
    Write-Host " timed out after ${TimeoutSeconds}s." -ForegroundColor Red
    return $false
}

function Show-Endpoints {
    Write-Host ''
    Write-Host 'Endpoints' -ForegroundColor Cyan
    Write-Host '  Admin console   http://localhost:8080/admin      (see .env for credentials)'
    Write-Host '  Account console http://localhost:8080/realms/guarantee-gateway/account'
    Write-Host '  Discovery       http://localhost:8080/realms/guarantee-gateway/.well-known/openid-configuration'
    Write-Host '  Health          http://localhost:9000/health/ready'
    Write-Host '  Metrics         http://localhost:9000/metrics'
    Write-Host '  Mailpit inbox   http://localhost:8025'
}

switch ($Command) {
    'up' {
        Initialize-EnvFile
        Invoke-Compose @('up', '-d')
        if (Wait-ForKeycloak) {
            Show-Endpoints
            Write-Host ''
            Write-Host 'Next: .\infrastructure\scripts\smoke-test.ps1' -ForegroundColor Cyan
        }
        else {
            Write-Host 'Keycloak did not come up. Recent logs:' -ForegroundColor Red
            Invoke-Compose @('logs', '--tail', '80', 'keycloak')
            exit 1
        }
    }

    'down' {
        # Keeps the postgres volume: realm config, users and sessions survive.
        Invoke-Compose @('down')
    }

    'reset' {
        Write-Host 'This DESTROYS the Postgres volume (all realms, users, sessions).' -ForegroundColor Yellow
        $answer = Read-Host 'Type "yes" to continue'
        if ($answer -ne 'yes') { Write-Host 'Aborted.'; break }
        Invoke-Compose @('down', '-v')
        Write-Host 'Volume removed. Run "up" to re-import the realm from keycloak/realms/.' -ForegroundColor Green
    }

    'restart-keycloak' {
        # Used by the persistent-session test: sessions must survive this.
        Invoke-Compose @('restart', 'keycloak')
        [void](Wait-ForKeycloak)
    }

    'status' {
        Invoke-Compose @('ps')
        Show-Endpoints
    }

    'logs' {
        if ($Service) { Invoke-Compose @('logs', '-f', $Service) }
        else { Invoke-Compose @('logs', '-f') }
    }

    'export-realm' {
        # Snapshot the live realm for inspection/diffing. Git-ignored by default -
        # promote changes into keycloak/realms/ deliberately, never dump over it.
        $outDir = Join-Path $RepoRoot 'keycloak\realms'
        Invoke-Compose @('exec', 'keycloak', '/opt/keycloak/bin/kc.sh', 'export',
            '--realm', 'guarantee-gateway',
            '--file', '/tmp/guarantee-gateway.export.json')
        & docker cp 'kc-poc-keycloak:/tmp/guarantee-gateway.export.json' (Join-Path $outDir 'guarantee-gateway.export.json')
        Write-Host "Exported to keycloak\realms\guarantee-gateway.export.json" -ForegroundColor Green
    }
}
