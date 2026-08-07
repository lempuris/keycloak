<#
.SYNOPSIS
    Verifies the PoC stack against the ROADMAP Phase 1 / Phase 2 acceptance criteria.

.DESCRIPTION
    Every check is an actual request, not a read-back of our own config file:
      1. Keycloak health + metrics endpoints respond
      2. Realm discovery document and RS256 JWKS are published
      3. Realm settings match design.md (brute force, token lifetimes, registration off)
      4. Client is public + PKCE S256 + no implicit / no direct-access grants
      5. Full Authorization Code + PKCE login as a seeded user, then decode the JWT
         and assert the expected role claim is present

.PARAMETER TestLockout
    Additionally drives 3 failed logins to prove permanent lockout, then unlocks
    the account again via the Admin API. Off by default because it mutates state.

.EXAMPLE
    .\infrastructure\scripts\smoke-test.ps1
    .\infrastructure\scripts\smoke-test.ps1 -TestLockout
#>
[CmdletBinding()]
param(
    [switch]$TestLockout
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

Write-Host ''
Write-Host '=== Keycloak PoC smoke test ===' -ForegroundColor Cyan
$dotenv   = Get-DotEnv
$testUser = $dotenv['POC_TEST_USER']
$testPass = $dotenv['POC_TEST_PASSWORD']

# --- 1. Infrastructure (Phase 1) ---
Write-Host ''
Write-Host '1. Infrastructure' -ForegroundColor Cyan
try {
    $health = Invoke-RestMethod "$MgmtUrl/health/ready"
    Assert-That -Name 'Health endpoint reports UP' -Condition ($health.status -eq 'UP') -Detail "got: $($health.status)"
}
catch { Assert-That -Name 'Health endpoint reports UP' -Condition $false -Detail $_.Exception.Message }

try {
    $metrics = Invoke-WebRequest "$MgmtUrl/metrics" -UseBasicParsing
    Assert-That -Name 'Metrics endpoint responds' -Condition ($metrics.StatusCode -eq 200)
}
catch { Assert-That -Name 'Metrics endpoint responds' -Condition $false -Detail $_.Exception.Message }

# --- 2. Realm published (Phase 2) ---
Write-Host ''
Write-Host '2. Realm discovery' -ForegroundColor Cyan
try {
    $disco = Invoke-RestMethod "$BaseUrl/realms/$Realm/.well-known/openid-configuration"
    Assert-That -Name "Realm '$Realm' discovery document published" -Condition ($null -ne $disco.issuer) -Detail "issuer: $($disco.issuer)"
    Assert-That -Name 'S256 advertised as PKCE method' -Condition ($disco.code_challenge_methods_supported -contains 'S256')
    $jwks = Invoke-RestMethod $disco.jwks_uri
    $rs256 = @($jwks.keys | Where-Object { $_.alg -eq 'RS256' })
    Assert-That -Name 'JWKS exposes an RS256 signing key' -Condition ($rs256.Count -ge 1) -Detail "RS256 keys: $($rs256.Count)"
}
catch { Assert-That -Name 'Realm discovery document published' -Condition $false -Detail $_.Exception.Message }

# --- 3 & 4. Realm + client settings via Admin API ---
Write-Host ''
Write-Host '3. Realm settings match design.md' -ForegroundColor Cyan
$token = $null
try {
    $token = Get-AdminToken -Env $dotenv
    $r = Invoke-AdminApi -Token $token -Path $Realm

    Assert-That -Name 'Self-registration disabled'    -Condition ($r.registrationAllowed -eq $false)
    Assert-That -Name 'Remember-me disabled'          -Condition ($r.rememberMe -eq $false)
    Assert-That -Name 'Brute force protection on'     -Condition ($r.bruteForceProtected -eq $true)
    Assert-That -Name 'Permanent lockout mode'        -Condition ($r.permanentLockout -eq $true)
    Assert-That -Name 'Lockout after 3 failures'      -Condition ($r.failureFactor -eq 3) -Detail "got: $($r.failureFactor)"
    Assert-That -Name 'Access token lifetime 5 min'   -Condition ($r.accessTokenLifespan -eq 300) -Detail "got: $($r.accessTokenLifespan)s"
    Assert-That -Name 'SSO idle 30 min'               -Condition ($r.ssoSessionIdleTimeout -eq 1800) -Detail "got: $($r.ssoSessionIdleTimeout)s"
    Assert-That -Name 'SSO max 10 h'                  -Condition ($r.ssoSessionMaxLifespan -eq 36000) -Detail "got: $($r.ssoSessionMaxLifespan)s"
    Assert-That -Name 'Refresh token rotation on'     -Condition ($r.revokeRefreshToken -eq $true)
    Assert-That -Name 'Password policy configured'    -Condition ($r.passwordPolicy -match 'length\(12\)') -Detail "got: $($r.passwordPolicy)"
    Assert-That -Name 'Login + admin events enabled'  -Condition ($r.eventsEnabled -eq $true -and $r.adminEventsEnabled -eq $true)

    Write-Host ''
    Write-Host '4. Client hardening' -ForegroundColor Cyan
    $c = (Invoke-AdminApi -Token $token -Path "$Realm/clients?clientId=$ClientId")[0]
    Assert-That -Name 'Client is public'                       -Condition ($c.publicClient -eq $true)
    Assert-That -Name 'Authorization Code flow enabled'        -Condition ($c.standardFlowEnabled -eq $true)
    Assert-That -Name 'Implicit flow disabled'                 -Condition ($c.implicitFlowEnabled -eq $false)
    Assert-That -Name 'Direct access grants disabled'          -Condition ($c.directAccessGrantsEnabled -eq $false)
    Assert-That -Name 'PKCE S256 enforced'                     -Condition ($c.attributes.'pkce.code.challenge.method' -eq 'S256') -Detail "got: $($c.attributes.'pkce.code.challenge.method')"
    Assert-That -Name 'Full scope disabled (roles via mapping)' -Condition ($c.fullScopeAllowed -eq $false)
}
catch { Assert-That -Name 'Admin API reachable' -Condition $false -Detail $_.Exception.Message }

# --- 5. End-to-end login (the criterion that matters) ---
Write-Host ''
Write-Host '5. Authorization Code + PKCE login' -ForegroundColor Cyan
try {
    $login = Invoke-PkceLogin -Username $testUser -Password $testPass
    Assert-That -Name "Login succeeds for $testUser" -Condition ([bool]$login.Success) -Detail $login.Error

    if ($login.Success) {
        $tokenResp = Invoke-TokenExchange -Code $login.Code -Verifier $login.Verifier
        Assert-That -Name 'Authorization code exchanged for tokens' -Condition ($null -ne $tokenResp.access_token)
        Assert-That -Name 'Refresh token issued'                    -Condition ($null -ne $tokenResp.refresh_token)

        $claims = ConvertFrom-JwtPayload $tokenResp.access_token
        $header = ConvertFrom-JwtHeader  $tokenResp.access_token

        Assert-That -Name 'Access token signed with RS256' -Condition ($header.alg -eq 'RS256') -Detail "got: $($header.alg)"
        Assert-That -Name 'Issuer is the realm'            -Condition ($claims.iss -eq "$BaseUrl/realms/$Realm") -Detail "got: $($claims.iss)"
        Assert-That -Name "Role claim contains 'facility-holder'" `
                    -Condition ($claims.realm_access.roles -contains 'facility-holder') `
                    -Detail "got: $($claims.realm_access.roles -join ', ')"
        Assert-That -Name 'Access token expires in ~5 min' -Condition ($tokenResp.expires_in -le 300 -and $tokenResp.expires_in -gt 240) -Detail "expires_in: $($tokenResp.expires_in)s"

        Write-Host ''
        Write-Host '  Access token claims:' -ForegroundColor DarkGray
        Write-Host "    sub                $($claims.sub)"
        Write-Host "    preferred_username $($claims.preferred_username)"
        Write-Host "    realm_access.roles $($claims.realm_access.roles -join ', ')"
        Write-Host "    scope              $($claims.scope)"
    }
}
catch { Assert-That -Name 'Authorization Code + PKCE login' -Condition $false -Detail $_.Exception.Message }

# --- 6. Optional: permanent lockout (Phase 2 criterion) ---
if ($TestLockout) {
    Write-Host ''
    Write-Host '6. Permanent lockout after 3 failures' -ForegroundColor Cyan
    try {
        1..3 | ForEach-Object { [void](Invoke-PkceLogin -Username $testUser -Password 'DeliberatelyWrong!1') }

        $u = (Invoke-AdminApi -Token $token -Path "$Realm/users?username=$([Uri]::EscapeDataString($testUser))&exact=true")[0]
        $status = Invoke-AdminApi -Token $token -Path "$Realm/attack-detection/brute-force/users/$($u.id)"
        Assert-That -Name 'Account disabled by brute-force protection' -Condition ($status.disabled -eq $true) -Detail "numFailures: $($status.numFailures)"

        $blocked = Invoke-PkceLogin -Username $testUser -Password $testPass
        Assert-That -Name 'Correct password rejected while locked' -Condition (-not $blocked.Success)

        # Restore so the script stays re-runnable.
        [void](Invoke-AdminApi -Token $token -Method Delete -Path "$Realm/attack-detection/brute-force/users/$($u.id)")
        $recovered = Invoke-PkceLogin -Username $testUser -Password $testPass
        Assert-That -Name 'Admin unlock restores login' -Condition ([bool]$recovered.Success) -Detail $recovered.Error
    }
    catch { Assert-That -Name 'Lockout test' -Condition $false -Detail $_.Exception.Message }
}

Write-TestSummary
