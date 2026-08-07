<#
.SYNOPSIS
    ROADMAP Phase 5 acceptance: Marshall provisioning mock -> Keycloak Admin API.

.DESCRIPTION
    Proves the integration shape from design.md §4 — users live in Keycloak,
    Marshall pushes lifecycle events at it, and nothing runs inside Keycloak.

    Cases:
      1. The mock is up and talks to Keycloak as the scoped service account
      2. Create      -> the broker is log-in-capable within seconds (password + OTP)
      3. Update      -> attribute change reaches Keycloak
      4. Deactivate  -> blocks the next login, revokes live sessions, kills the
                        refresh token; an already-issued access token survives
                        only to its own expiry (this is what justifies the
                        5-minute accessTokenLifespan in design.md §5)
      5. Reactivate  -> login works again
      6. Least privilege -> the service account is refused everything outside
                        manage-users / view-users / view-realm
      7. Unknown broker -> 404, not a 500

    The test provisions and then deletes its own user, so it is re-runnable.

.PARAMETER ProveTokenExpiry
    Additionally waits out the full access-token lifetime after deactivation and
    asserts the API then rejects the token. Adds ~5 minutes; the arithmetic
    assertion on `exp` covers the same ground instantly.

.EXAMPLE
    .\infrastructure\scripts\test-provisioning.ps1
    .\infrastructure\scripts\test-provisioning.ps1 -ProveTokenExpiry
#>
[CmdletBinding()]
param(
    [switch]$ProveTokenExpiry
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

Write-Host ''
Write-Host '=== Phase 5: Marshall provisioning mock ===' -ForegroundColor Cyan

$dotenv   = Get-DotEnv
$broker   = $dotenv['POC_PROVISIONED_USER']
$password = $dotenv['POC_TEST_PASSWORD']
$adminTok = Get-AdminToken -Env $dotenv

if (-not $broker) { throw 'POC_PROVISIONED_USER is not set in .env - copy the new line from .env.example.' }
Write-Host "    provisioning target: $broker" -ForegroundColor DarkGray

# Leftovers from an interrupted run would make "create" fail with a 409.
[void](Invoke-MarshallApi -Path "/brokers/$broker" -Method Delete)
Clear-Mailbox

# --- 1. The mock is reachable and authenticates as the scoped service account ---
Write-Host ''
Write-Host '1. Mock service is up' -ForegroundColor Cyan
$health = Invoke-MarshallApi -Path '/health'
Assert-That -Name 'Marshall mock answers /health' -Condition ($health.Status -eq 200) -Detail "status: $($health.Status)"

$svcToken = $null
try { $svcToken = Get-ServiceAccountToken -Env $dotenv } catch { }
Assert-That -Name 'client_credentials grant works for marshall-provisioning' -Condition ($null -ne $svcToken)
if ($svcToken) {
    $svcClaims = ConvertFrom-JwtPayload $svcToken
    Assert-That -Name 'Service token is issued to marshall-provisioning, not admin-cli' `
                -Condition ($svcClaims.azp -eq 'marshall-provisioning') -Detail "azp: $($svcClaims.azp)"
}

# --- 2. Create ---
Write-Host ''
Write-Host '2. Create: Marshall onboards a broker' -ForegroundColor Cyan
$started = Get-Date
$created = Invoke-MarshallApi -Path '/brokers' -Method Post -Body @{
    username  = $broker
    email     = $broker
    firstName = 'Sipho'
    lastName  = 'Ndlovu'
    password  = $password
    realmRole = 'broker'
}
Assert-That -Name 'Mock accepts the create event (201)' -Condition ($created.Status -eq 201) -Detail $created.Body

$kcUser = $null
if ($created.Status -eq 201) {
    $kcUser = (Invoke-AdminApi -Token $adminTok -Path "$Realm/users?username=$([Uri]::EscapeDataString($broker))&exact=true")[0]
    Assert-That -Name 'User exists in Keycloak'  -Condition ($null -ne $kcUser)
    Assert-That -Name 'User is enabled'          -Condition ($kcUser.enabled -eq $true)

    $roles = @((Invoke-AdminApi -Token $adminTok -Path "$Realm/users/$($kcUser.id)/role-mappings/realm").name)
    Assert-That -Name 'Realm role `broker` assigned' -Condition ($roles -contains 'broker') -Detail "roles: $($roles -join ', ')"
}

# Log-in-capable "within seconds" is the actual criterion, so drive a real login.
$login  = Invoke-PkceLogin -Username $broker -Password $password
$tokens = $null
Assert-That -Name 'Provisioned broker completes password + OTP login' -Condition ([bool]$login.Success) -Detail $login.Error
if ($login.Success) {
    $elapsed = ((Get-Date) - $started).TotalSeconds
    Write-Host ("    create -> first successful login: {0:N1}s" -f $elapsed) -ForegroundColor DarkGray
    $tokens = Invoke-TokenExchange -Code $login.Code -Verifier $login.Verifier
    Assert-That -Name 'Tokens issued for the new broker' -Condition ($null -ne $tokens.access_token)

    $portfolio = Invoke-ApiRequest -Path '/api/broker/portfolio' -Token $tokens.access_token
    Assert-That -Name 'API accepts the new broker (200 on the broker endpoint)' `
                -Condition ($portfolio.Status -eq 200) -Detail "status: $($portfolio.Status)"
}

# --- 3. Update ---
Write-Host ''
Write-Host '3. Update: Marshall changes the broker record' -ForegroundColor Cyan
$updated = Invoke-MarshallApi -Path "/brokers/$broker" -Method Patch -Body @{ lastName = 'Ndlovu-Khumalo' }
Assert-That -Name 'Mock accepts the update event (200)' -Condition ($updated.Status -eq 200) -Detail $updated.Body
if ($kcUser) {
    $reread = Invoke-AdminApi -Token $adminTok -Path "$Realm/users/$($kcUser.id)"
    Assert-That -Name 'Change is visible in Keycloak' -Condition ($reread.lastName -eq 'Ndlovu-Khumalo') -Detail "lastName: $($reread.lastName)"
}

# --- 4. Deactivate: the event that actually matters ---
Write-Host ''
Write-Host '4. Deactivate: offboarding blocks login AND revokes live access' -ForegroundColor Cyan

if ($kcUser) {
    $sessionsBefore = @(Get-UserSessionList -Token $adminTok -UserId $kcUser.id)
    Assert-That -Name 'Broker has a live session before deactivation' -Condition ($sessionsBefore.Count -ge 1) -Detail "sessions: $($sessionsBefore.Count)"
}

$deactivated = Invoke-MarshallApi -Path "/brokers/$broker/deactivate" -Method Post
Assert-That -Name 'Mock accepts the deactivate event (200)' -Condition ($deactivated.Status -eq 200) -Detail $deactivated.Body
Assert-That -Name 'Mock reports the account disabled'       -Condition ($deactivated.Json.enabled -eq $false)
Assert-That -Name 'Mock reports sessions revoked'           -Condition ($deactivated.Json.revokedSessions -ge 1) -Detail "revoked: $($deactivated.Json.revokedSessions)"

if ($kcUser) {
    $sessionsAfter = @(Get-UserSessionList -Token $adminTok -UserId $kcUser.id)
    Assert-That -Name 'Keycloak shows zero sessions after deactivation' -Condition ($sessionsAfter.Count -eq 0) -Detail "sessions: $($sessionsAfter.Count)"
    Assert-That -Name 'Mock agrees the sessions are gone' -Condition ($deactivated.Json.activeSessions -eq 0) -Detail "activeSessions: $($deactivated.Json.activeSessions)"
}

$blocked = Invoke-PkceLogin -Username $broker -Password $password
Assert-That -Name 'Deactivated broker cannot log in' -Condition (-not $blocked.Success) -Detail "error: $($blocked.Error)"

if ($tokens) {
    # The two halves of the contrast. Revocation is immediate for anything that
    # touches Keycloak; it is invisible to a stateless resource server, which
    # only ever sees a signed JWT.
    $refresh = Invoke-RefreshGrant -RefreshToken $tokens.refresh_token
    Assert-That -Name 'Refresh token is dead immediately' `
                -Condition ($refresh.Status -eq 400 -and $refresh.Json.error -eq 'invalid_grant') `
                -Detail "status: $($refresh.Status) error: $($refresh.Json.error)"

    $stillWorks = Invoke-ApiRequest -Path '/api/me' -Token $tokens.access_token
    Assert-That -Name 'Already-issued access token STILL works (stateless JWT)' `
                -Condition ($stillWorks.Status -eq 200) `
                -Detail "status: $($stillWorks.Status) - this is expected, and is the residual-access window"

    $claims = ConvertFrom-JwtPayload $tokens.access_token
    $window = $claims.exp - $claims.iat
    Assert-That -Name 'Residual window is bounded by accessTokenLifespan (<= 300s)' `
                -Condition ($window -le 300) -Detail "exp - iat = ${window}s"
    Write-Host "    Residual access after offboarding: at most ${window}s. Shortening" -ForegroundColor DarkGray
    Write-Host '    accessTokenLifespan shortens this window and nothing else.' -ForegroundColor DarkGray

    if ($ProveTokenExpiry) {
        $secondsLeft = [int]($claims.exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) + 5
        Write-Host "    -ProveTokenExpiry: waiting ${secondsLeft}s for the access token to expire..." -ForegroundColor DarkGray
        Start-Sleep -Seconds ([Math]::Max($secondsLeft, 1))
        $expired = Invoke-ApiRequest -Path '/api/me' -Token $tokens.access_token
        Assert-That -Name 'API rejects the token once it expires' -Condition ($expired.Status -eq 401) -Detail "status: $($expired.Status)"
    }
}

# --- 5. Reactivate ---
Write-Host ''
Write-Host '5. Reactivate: the broker comes back' -ForegroundColor Cyan
$reactivated = Invoke-MarshallApi -Path "/brokers/$broker/reactivate" -Method Post
Assert-That -Name 'Mock accepts the reactivate event (200)' -Condition ($reactivated.Status -eq 200) -Detail $reactivated.Body
Assert-That -Name 'Mock reports the account enabled'        -Condition ($reactivated.Json.enabled -eq $true)

$backIn = Invoke-PkceLogin -Username $broker -Password $password
Assert-That -Name 'Reactivated broker can log in again' -Condition ([bool]$backIn.Success) -Detail $backIn.Error

# --- 6. Least privilege ---
#
# The provisioning identity must be useless for anything but user lifecycle.
# These calls go straight to the Admin API with the service token, bypassing the
# mock, so the boundary being tested is Keycloak's and not our route table.
Write-Host ''
Write-Host '6. Least privilege: the service account is scoped to users only' -ForegroundColor Cyan
if ($svcToken) {
    $allowed = Invoke-AdminApiStatus -Token $svcToken -Path "$Realm/users?max=1"
    Assert-That -Name 'ALLOWED: list users in guarantee-gateway' -Condition ($allowed.Status -eq 200) -Detail "status: $($allowed.Status)"

    $createClient = Invoke-AdminApiStatus -Token $svcToken -Path "$Realm/clients" -Method Post -Body @{
        clientId = 'should-never-be-created'; enabled = $true
    }
    Assert-That -Name 'FORBIDDEN: create a client (needs manage-clients)' `
                -Condition ($createClient.Status -eq 403) -Detail "status: $($createClient.Status)"

    $editRealm = Invoke-AdminApiStatus -Token $svcToken -Path $Realm -Method Put -Body @{ bruteForceProtected = $false }
    Assert-That -Name 'FORBIDDEN: weaken realm settings (needs manage-realm)' `
                -Condition ($editRealm.Status -eq 403) -Detail "status: $($editRealm.Status)"

    $otherRealm = Invoke-AdminApiStatus -Token $svcToken -Path 'master/users?max=1'
    Assert-That -Name 'FORBIDDEN: reach into the master realm' `
                -Condition ($otherRealm.Status -eq 403) -Detail "status: $($otherRealm.Status)"

    if ($createClient.Status -eq 201) {
        Write-Host '    Cleaning up a client that should never have been created.' -ForegroundColor Red
        $stray = Invoke-AdminApi -Token $adminTok -Path "$Realm/clients?clientId=should-never-be-created"
        if ($stray) { [void](Invoke-AdminApi -Token $adminTok -Method Delete -Path "$Realm/clients/$($stray[0].id)") }
    }
}

# --- 7. Unknown broker ---
Write-Host ''
Write-Host '7. Unknown broker is a 404, not a 500' -ForegroundColor Cyan
$missing = Invoke-MarshallApi -Path '/brokers/nobody@example.com/deactivate' -Method Post
Assert-That -Name 'Deactivating an unknown broker returns 404' -Condition ($missing.Status -eq 404) -Detail "status: $($missing.Status)"

# --- 8. Config-as-code and the provisioning feed must coexist ---
#
# The realm JSON in Git does not mention this broker, so a "make reality match
# the file" run is exactly the situation in which it could vanish. Users are not
# configuration: IMPORT_MANAGED_USER=no-delete is what keeps the two mechanisms
# from fighting, and this is the assertion that would catch someone setting it
# to `full` to tidy things up.
Write-Host ''
Write-Host '8. Re-applying realm config does not delete a provisioned user' -ForegroundColor Cyan
# poc.ps1 reports success with Write-Host, which ignores redirection, so match on
# the config-cli output rather than trusting $LASTEXITCODE from a nested script.
$applyOutput = & (Join-Path $PSScriptRoot 'poc.ps1') apply-realm 2>&1
$applyFailed = @($applyOutput | Where-Object { $_ -match 'ERROR|Cannot (update|create)' }).Count
Assert-That -Name 'Realm config re-applied without errors' -Condition ($applyFailed -eq 0) `
            -Detail (($applyOutput | Select-Object -Last 3) -join ' | ')

$survivor = Invoke-MarshallApi -Path "/brokers/$broker"
Assert-That -Name 'Provisioned broker survives a realm-config run' `
            -Condition ($survivor.Status -eq 200) `
            -Detail "status: $($survivor.Status) - if this is 404, IMPORT_MANAGED_USER is not no-delete"

$stillWorking = Invoke-PkceLogin -Username $broker -Password $password
Assert-That -Name 'and can still log in afterwards' -Condition ([bool]$stillWorking.Success) -Detail $stillWorking.Error

# --- 9. Support-desk role is scoped, and cannot impersonate ---
#
# The runbook in docs/runbook-user-support.md tells support to unlock and reset
# from the guarantee-gateway admin console, not the master realm. That only
# holds if the group carries user-management rights and nothing else - above all
# not `impersonation`, which would let the support desk log in as a facility
# holder and act on their guarantees.
Write-Host ''
Write-Host '9. Support-desk group is scoped to user management' -ForegroundColor Cyan
$groups   = @(Invoke-AdminApi -Token $adminTok -Path "$Realm/groups?search=support-desk")
$supportG = $groups | Where-Object { $_.name -eq 'support-desk' } | Select-Object -First 1
Assert-That -Name 'support-desk group exists' -Condition ($null -ne $supportG)

if ($supportG) {
    $rmClient = (Invoke-AdminApi -Token $adminTok -Path "$Realm/clients?clientId=realm-management")[0]
    $granted  = @((Invoke-AdminApi -Token $adminTok -Path "$Realm/groups/$($supportG.id)/role-mappings/clients/$($rmClient.id)").name)
    Write-Host "    granted: $($granted -join ', ')" -ForegroundColor DarkGray

    foreach ($needed in @('view-realm', 'view-users', 'manage-users', 'view-events')) {
        Assert-That -Name "support-desk has $needed" -Condition ($granted -contains $needed)
    }
    foreach ($forbidden in @('impersonation', 'manage-realm', 'manage-clients', 'manage-authorization')) {
        Assert-That -Name "support-desk does NOT have $forbidden" -Condition ($granted -notcontains $forbidden)
    }
}

# --- 10. Marshall outage degrades data, never authentication ---
#
# The whole reason the federation/user-storage-SPI option was dropped: Marshall
# sits on the data path and never on the login path. That is easy to assert on a
# whiteboard and only convincing if you actually stop the service, so this stops
# it. Logging in and identity endpoints must keep working; only facility linkage
# is allowed to fail, and it must fail visibly (503) rather than quietly return
# an empty list, which would tell the user they have no facilities.
Write-Host ''
Write-Host '10. Marshall outage: logins survive, facility data degrades' -ForegroundColor Cyan
$ComposeFile = Join-Path $RepoRoot 'infrastructure\compose\docker-compose.yml'

function Invoke-ComposeQuiet {
    param([string[]]$ComposeArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker compose -f $ComposeFile --env-file $EnvFile @ComposeArgs 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $previous }
}

Invoke-ComposeQuiet @('stop', 'marshall-mock')
try {
    $down = Invoke-MarshallApi -Path '/health'
    Assert-That -Name 'Marshall is genuinely down' -Condition ($down.Status -ne 200) -Detail "status: $($down.Status)"

    # The load-bearing assertion: authentication does not involve Marshall.
    $outageLogin = Invoke-PkceLogin -Username $dotenv['POC_TEST_USER'] -Password $password
    Assert-That -Name 'Users can still log in with Marshall down' -Condition ([bool]$outageLogin.Success) -Detail $outageLogin.Error

    if ($outageLogin.Success) {
        $outageToken = (Invoke-TokenExchange -Code $outageLogin.Code -Verifier $outageLogin.Verifier).access_token

        $identity = Invoke-ApiRequest -Path '/api/me' -Token $outageToken
        Assert-That -Name 'Identity endpoint unaffected (200)' -Condition ($identity.Status -eq 200) -Detail "status: $($identity.Status)"

        $degraded = Invoke-ApiRequest -Path '/api/facilities' -Token $outageToken
        Assert-That -Name 'Facility endpoint fails loudly (503, not an empty 200)' `
                    -Condition ($degraded.Status -eq 503) `
                    -Detail "status: $($degraded.Status) - a 200 here would mean the API invented 'no facilities'"
    }
}
finally {
    # Always bring it back, even if an assertion above threw.
    Invoke-ComposeQuiet @('start', 'marshall-mock')
}

$recoveryDeadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $recoveryDeadline -and (Invoke-MarshallApi -Path '/health').Status -ne 200) {
    Start-Sleep -Seconds 2
}
$recoveredToken = Get-UserAccessToken -Username $dotenv['POC_TEST_USER'] -Password $password
$recovered = Invoke-ApiRequest -Path '/api/facilities' -Token $recoveredToken
Assert-That -Name 'Facility data returns when Marshall comes back' -Condition ($recovered.Status -eq 200) -Detail "status: $($recovered.Status)"
Assert-That -Name 'and the linkage is resolved from Marshall, not the API' `
            -Condition ($recovered.Json.facilities.Count -gt 0) -Detail "count: $($recovered.Json.facilities.Count)"

# --- teardown ---
Write-Host ''
Write-Host 'Teardown' -ForegroundColor Cyan
$deleted = Invoke-MarshallApi -Path "/brokers/$broker" -Method Delete
Assert-That -Name 'Provisioned broker removed (204)' -Condition ($deleted.Status -eq 204) -Detail "status: $($deleted.Status)"
$gone = Invoke-MarshallApi -Path "/brokers/$broker"
Assert-That -Name 'Broker no longer resolvable (404)' -Condition ($gone.Status -eq 404) -Detail "status: $($gone.Status)"

Clear-Mailbox
Write-TestSummary
