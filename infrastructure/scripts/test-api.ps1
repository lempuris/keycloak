<#
.SYNOPSIS
    ROADMAP Phase 3 acceptance: SPA login -> API call with JWT -> role enforcement.

.DESCRIPTION
    Drives the real Authorization Code + PKCE flow for two users with different
    realm roles, then calls the Spring Boot resource server with the resulting
    tokens and asserts:
      - 200 for the endpoint matching the user's role
      - 403 for the endpoint belonging to the other role
      - 401 with no token, a malformed token, or a token from another realm
      - business data (facility linkage) is resolved server-side, not carried
        in the token (design.md §4)

.EXAMPLE
    .\infrastructure\scripts\test-api.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

Write-Host ''
Write-Host '=== Phase 3: SPA -> API integration ===' -ForegroundColor Cyan
$dotenv       = Get-DotEnv
$holderUser   = $dotenv['POC_TEST_USER']
$brokerUser   = $dotenv['POC_BROKER_USER']
$password     = $dotenv['POC_TEST_PASSWORD']

# --- 1. API reachable ---
Write-Host ''
Write-Host '1. API reachable' -ForegroundColor Cyan
$info = Invoke-ApiRequest -Path '/api/public/info'
Assert-That -Name 'Public endpoint returns 200 without a token' -Condition ($info.Status -eq 200) -Detail "status: $($info.Status)"

# --- 2. Rejections ---
Write-Host ''
Write-Host '2. Unauthenticated and invalid tokens are rejected' -ForegroundColor Cyan
$noToken = Invoke-ApiRequest -Path '/api/me'
Assert-That -Name 'No token -> 401' -Condition ($noToken.Status -eq 401) -Detail "status: $($noToken.Status)"

$garbage = Invoke-ApiRequest -Path '/api/me' -Token 'not.a.jwt'
Assert-That -Name 'Malformed token -> 401' -Condition ($garbage.Status -eq 401) -Detail "status: $($garbage.Status)"

# A perfectly valid token from the master realm: right signature algorithm,
# wrong issuer and no matching audience. Proves both validators are live.
$masterToken = Get-AdminToken -Env $dotenv
$wrongRealm = Invoke-ApiRequest -Path '/api/me' -Token $masterToken
Assert-That -Name 'Valid token from another realm -> 401 (issuer/audience enforced)' `
            -Condition ($wrongRealm.Status -eq 401) -Detail "status: $($wrongRealm.Status)"

# --- 3. Facility holder ---
Write-Host ''
Write-Host "3. Facility holder ($holderUser)" -ForegroundColor Cyan
$holderToken = Get-UserAccessToken -Username $holderUser -Password $password

$me = Invoke-ApiRequest -Path '/api/me' -Token $holderToken
Assert-That -Name 'GET /api/me -> 200' -Condition ($me.Status -eq 200) -Detail "status: $($me.Status)"
if ($me.Status -eq 200) {
    Assert-That -Name 'API sees the facility-holder role' -Condition ($me.Json.roles -contains 'facility-holder') -Detail "roles: $($me.Json.roles -join ', ')"
    Assert-That -Name 'API validated the expected audience'  -Condition ($me.Json.audience -contains $ApiClientId) -Detail "aud: $($me.Json.audience -join ', ')"
}

$facilities = Invoke-ApiRequest -Path '/api/facilities' -Token $holderToken
Assert-That -Name 'GET /api/facilities -> 200 (role matches)' -Condition ($facilities.Status -eq 200) -Detail "status: $($facilities.Status)"
if ($facilities.Status -eq 200) {
    Assert-That -Name 'Facility linkage resolved server-side' -Condition ($facilities.Json.facilities.Count -gt 0) -Detail "count: $($facilities.Json.facilities.Count)"

    # design.md §4: business data must NOT ride along in the token.
    $claims = ConvertFrom-JwtPayload $holderToken
    $claimNames = ($claims | Get-Member -MemberType NoteProperty).Name
    Assert-That -Name 'Token carries no facility/business claims' `
                -Condition (-not ($claimNames -match 'facilit|marshall|portfolio')) `
                -Detail "claims: $($claimNames -join ', ')"
}

$forbidden = Invoke-ApiRequest -Path '/api/broker/portfolio' -Token $holderToken
Assert-That -Name 'GET /api/broker/portfolio -> 403 (wrong role)' -Condition ($forbidden.Status -eq 403) -Detail "status: $($forbidden.Status)"

# --- 4. Broker ---
Write-Host ''
Write-Host "4. Broker ($brokerUser)" -ForegroundColor Cyan
$brokerToken = Get-UserAccessToken -Username $brokerUser -Password $password

$portfolio = Invoke-ApiRequest -Path '/api/broker/portfolio' -Token $brokerToken
Assert-That -Name 'GET /api/broker/portfolio -> 200 (role matches)' -Condition ($portfolio.Status -eq 200) -Detail "status: $($portfolio.Status)"
if ($portfolio.Status -eq 200) {
    Assert-That -Name 'Broker portfolio populated' -Condition ($portfolio.Json.managedFacilities.Count -gt 0) -Detail "count: $($portfolio.Json.managedFacilities.Count)"
}

$brokerForbidden = Invoke-ApiRequest -Path '/api/facilities' -Token $brokerToken
Assert-That -Name 'GET /api/facilities -> 403 (wrong role)' -Condition ($brokerForbidden.Status -eq 403) -Detail "status: $($brokerForbidden.Status)"

# --- 5. CORS ---
Write-Host ''
Write-Host '5. CORS allows the SPA origin' -ForegroundColor Cyan
$cors = Invoke-ApiRequest -Path '/api/public/info' -Origin $SpaBaseUrl
$allowOrigin = $null
if ($cors.Response.Headers.TryGetValues('Access-Control-Allow-Origin', [ref]$allowOrigin)) {
    Assert-That -Name "Access-Control-Allow-Origin echoes $SpaBaseUrl" -Condition (@($allowOrigin) -contains $SpaBaseUrl) -Detail "got: $(@($allowOrigin) -join ', ')"
}
else {
    Assert-That -Name 'Access-Control-Allow-Origin present' -Condition $false -Detail 'header missing'
}

Write-TestSummary
