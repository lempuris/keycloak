<#
    Shared helpers for the PoC test scripts. Dot-source it:

        . (Join-Path $PSScriptRoot '_common.ps1')

    Later roadmap phases reuse these as their smoke-test primitives.
#>

Add-Type -AssemblyName System.Net.Http

$RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$EnvFile     = Join-Path $RepoRoot '.env'

$BaseUrl     = 'http://localhost:8080'
$MgmtUrl     = 'http://localhost:9000'
$ApiBaseUrl  = 'http://localhost:8081'
$SpaBaseUrl  = 'http://localhost:4200'
$MailpitUrl  = 'http://localhost:8025'
$MarshallUrl = 'http://localhost:8090'
$Realm       = 'guarantee-gateway'
$ClientId    = 'guarantee-gateway-za'
$ApiClientId = 'guarantee-gateway-api'
$RedirectUri = 'http://localhost:4200/'

# ------------------------------------------------------------- assertions ---

$script:Passed = 0
$script:Failed = 0

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail
    )
    if ($Condition) {
        $script:Passed++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    }
}

function Write-TestSummary {
    Write-Host ''
    Write-Host ('-' * 50)
    if ($script:Failed -eq 0) {
        Write-Host "All $($script:Passed) checks passed." -ForegroundColor Green
        exit 0
    }
    Write-Host "$($script:Passed) passed, $($script:Failed) FAILED." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------ utils ---

function Get-DotEnv {
    if (-not (Test-Path $EnvFile)) { throw ".env not found at $EnvFile - run poc.ps1 up first." }
    $map = @{}
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $k, $v = $line -split '=', 2
        $map[$k.Trim()] = $v.Trim()
    }
    return $map
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64UrlString {
    param([string]$Text)
    $s = $Text.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

function ConvertFrom-JwtPayload {
    param([string]$Jwt)
    ConvertFrom-Base64UrlString $Jwt.Split('.')[1] | ConvertFrom-Json
}

function ConvertFrom-JwtHeader {
    param([string]$Jwt)
    ConvertFrom-Base64UrlString $Jwt.Split('.')[0] | ConvertFrom-Json
}

# ------------------------------------------------------------------- http ---

# Cookies are managed by hand rather than with a CookieContainer.
# Keycloak sets AUTH_SESSION_ID with SameSite=None, which obliges it to add
# Secure. Browsers treat http://localhost as a secure context and send such
# cookies anyway; .NET's CookieContainer applies the rule strictly and drops
# them over plain http, which loses the auth session between requests.
function New-HttpClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    New-Object System.Net.Http.HttpClient($handler)
}

function Update-CookieJar {
    param($Response, [hashtable]$Jar)
    $values = $null
    if ($Response.Headers.TryGetValues('Set-Cookie', [ref]$values)) {
        foreach ($v in $values) {
            $nameValue = $v.Split(';')[0]
            $i = $nameValue.IndexOf('=')
            if ($i -gt 0) {
                $name = $nameValue.Substring(0, $i)
                $value = $nameValue.Substring($i + 1)
                # An empty value with Max-Age=0 is Keycloak expiring the cookie.
                if ($value -eq '' -or $v -match 'Max-Age=0\b') { $Jar.Remove($name) }
                else { $Jar[$name] = $value }
            }
        }
    }
}

function ConvertTo-CookieHeader {
    param([hashtable]$Jar)
    ($Jar.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
}

function Invoke-HttpGet {
    param([System.Net.Http.HttpClient]$Client, [string]$Url, [hashtable]$Jar)
    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get, $Url)
    if ($Jar.Count) { [void]$req.Headers.TryAddWithoutValidation('Cookie', (ConvertTo-CookieHeader $Jar)) }
    $resp = $Client.SendAsync($req).GetAwaiter().GetResult()
    Update-CookieJar -Response $resp -Jar $Jar
    $resp
}

function Invoke-FormPost {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Url,
        [hashtable]$Fields,
        [hashtable]$Jar
    )
    $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[String,String]]'
    foreach ($k in $Fields.Keys) {
        $pairs.Add((New-Object 'System.Collections.Generic.KeyValuePair[String,String]'($k, $Fields[$k])))
    }
    # `(, $pairs)` stops PowerShell unrolling the list into separate ctor args.
    $content = New-Object System.Net.Http.FormUrlEncodedContent -ArgumentList (, $pairs)

    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post, $Url)
    if ($Jar.Count) { [void]$req.Headers.TryAddWithoutValidation('Cookie', (ConvertTo-CookieHeader $Jar)) }
    $req.Content = $content

    $resp = $Client.SendAsync($req).GetAwaiter().GetResult()
    Update-CookieJar -Response $resp -Jar $Jar
    $resp
}

# -------------------------------------------------------------- mailbox ---

# Mailpit stands in for M365. These helpers let the tests read the OTP that
# Keycloak actually emailed, rather than asserting against a code we made up.

<#
    Empties the mailbox and waits until it really is empty.

    The delete is not immediately reflected in the message list, so without this
    wait a subsequent read can return an already-deleted message - whose body
    then 404s. That race produced a false "a lockout email was sent" result.
#>
function Clear-Mailbox {
    param([int]$TimeoutSeconds = 10)
    try { Invoke-RestMethod -Method Delete -Uri "$MailpitUrl/api/v1/messages" | Out-Null } catch { }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if ((Invoke-RestMethod "$MailpitUrl/api/v1/messages?limit=1").total -eq 0) { return }
        }
        catch { return }
        Start-Sleep -Milliseconds 200
    }
}

function Get-MailboxMessages {
    param([string]$ToAddress)
    $list = Invoke-RestMethod "$MailpitUrl/api/v1/messages?limit=50"
    # Callers must wrap the result in @() - PowerShell unrolls a single-element
    # array on return. Do NOT "fix" that with a leading comma here: `,@()` on an
    # empty mailbox yields a one-element array containing an empty array, which
    # reads as a phantom message at the call site.
    if (-not $ToAddress) { return @($list.messages) }
    # `$_.To.Address` looks right but binds to System.Array's Address() method
    # rather than enumerating the recipients, so project explicitly.
    @($list.messages | Where-Object {
        @($_.To | ForEach-Object { $_.Address }) -contains $ToAddress
    })
}

function Get-MessageBody {
    param([string]$Id)
    try {
        $full = Invoke-RestMethod "$MailpitUrl/api/v1/message/$Id"
    }
    catch {
        # The listing can briefly outlive the message itself.
        return $null
    }
    if ($full.Text) { return $full.Text }
    return $full.HTML
}

<#
    Waits for an OTP email and returns the 6-digit code.
    The extension's template reads: "Your email login code is NNNNNN and is
    valid for N minutes." - so take the first 6-digit run.
#>
function Get-OtpCodeFromMailbox {
    param([string]$ToAddress, [int]$TimeoutSeconds = 25)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $messages = @(Get-MailboxMessages -ToAddress $ToAddress)
        if ($messages.Count -gt 0) {
            $body = Get-MessageBody -Id $messages[0].ID
            if ($body -match '\b(\d{6})\b') { return $Matches[1] }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# ------------------------------------------------------------------ oauth ---

function New-PkceVerifier {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ConvertTo-Base64Url $bytes
}

function Get-PkceChallenge {
    param([string]$Verifier)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ConvertTo-Base64Url $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($Verifier))
}

function Get-AuthorizeUrl {
    param([string]$Challenge, [string]$State = ([Guid]::NewGuid().ToString('N')))
    "$BaseUrl/realms/$Realm/protocol/openid-connect/auth" +
    "?client_id=$ClientId" +
    "&redirect_uri=$([Uri]::EscapeDataString($RedirectUri))" +
    "&response_type=code&scope=openid%20profile%20email" +
    "&state=$State&code_challenge=$Challenge&code_challenge_method=S256"
}

<#
    Performs an Authorization Code + PKCE browser login.

    Pass -Jar to reuse cookies from an earlier login: with a live SSO session the
    Cookie authenticator short-circuits and no login form is rendered, which is
    exactly what the persistent-session test asserts. The returned hashtable then
    reports PromptedForPassword = $false.
#>
function Invoke-PkceLogin {
    param(
        [string]$Username,
        [string]$Password,
        [hashtable]$Jar = @{},
        # Supply a code explicitly (e.g. a deliberately wrong or expired one)
        # instead of reading the real one out of Mailpit.
        [string]$OtpCode,
        # Stop at the OTP prompt without answering it.
        [switch]$NoOtp
    )

    $verifier  = New-PkceVerifier
    $challenge = Get-PkceChallenge -Verifier $verifier
    $authUrl   = Get-AuthorizeUrl -Challenge $challenge

    $client = New-HttpClient
    try {
        $page = Invoke-HttpGet -Client $client -Url $authUrl -Jar $Jar

        # Existing SSO session: Keycloak redirects straight back with a code.
        if ($page.StatusCode.value__ -ge 300 -and $page.StatusCode.value__ -lt 400 -and $page.Headers.Location) {
            $loc = $page.Headers.Location.ToString()
            if ($loc -match '[?&]code=([^&]+)') {
                return @{
                    Success = $true; Code = $Matches[1]; Verifier = $verifier
                    Jar = $Jar; PromptedForPassword = $false; PromptedForOtp = $false; Location = $loc
                }
            }
            return @{ Success = $false; Code = $null; Location = $loc; Jar = $Jar; Error = 'redirect without code' }
        }

        $html = $page.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($html -notmatch '(?s)id="kc-form-login".*?action="([^"]+)"') {
            return @{ Success = $false; Code = $null; Html = $html; Jar = $Jar; Error = 'login form not found' }
        }
        $action = [System.Net.WebUtility]::HtmlDecode($Matches[1])

        # Clear the mailbox before submitting the password so the OTP we read
        # back is definitely the one this login triggered, not a stale one.
        if (-not $OtpCode) { Clear-Mailbox }

        $resp = Invoke-FormPost -Client $client -Url $action -Jar $Jar -Fields @{
            username = $Username
            password = $Password
        }

        if ($resp.StatusCode.value__ -ge 300 -and $resp.StatusCode.value__ -lt 400 -and $resp.Headers.Location) {
            $location = $resp.Headers.Location.ToString()
            if ($location -match '[?&]code=([^&]+)') {
                return @{
                    Success = $true; Code = $Matches[1]; Verifier = $verifier
                    Jar = $Jar; PromptedForPassword = $true; PromptedForOtp = $false; Location = $location
                }
            }
            return @{ Success = $false; Code = $null; Location = $location; Jar = $Jar; Error = 'redirect without code' }
        }

        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        # Second factor: the email-OTP form from the pinned extension.
        if ($body -match '(?s)id="kc-email-code-login-form".*?action="([^"]+)"') {
            $otpAction = [System.Net.WebUtility]::HtmlDecode($Matches[1])

            if ($NoOtp) {
                return @{
                    Success = $false; Code = $null; Jar = $Jar; OtpAction = $otpAction
                    PromptedForPassword = $true; PromptedForOtp = $true; Error = 'stopped at OTP prompt'
                }
            }

            $code = $OtpCode
            if (-not $code) {
                $code = Get-OtpCodeFromMailbox -ToAddress $Username
                if (-not $code) {
                    return @{
                        Success = $false; Code = $null; Jar = $Jar
                        PromptedForPassword = $true; PromptedForOtp = $true; Error = 'no OTP email arrived'
                    }
                }
            }

            $otpResp = Invoke-FormPost -Client $client -Url $otpAction -Jar $Jar -Fields @{
                code  = $code
                login = 'Sign in'
            }

            if ($otpResp.StatusCode.value__ -ge 300 -and $otpResp.StatusCode.value__ -lt 400 -and $otpResp.Headers.Location) {
                $otpLocation = $otpResp.Headers.Location.ToString()
                if ($otpLocation -match '[?&]code=([^&]+)') {
                    return @{
                        Success = $true; Code = $Matches[1]; Verifier = $verifier; OtpUsed = $code
                        Jar = $Jar; PromptedForPassword = $true; PromptedForOtp = $true; Location = $otpLocation
                    }
                }
                return @{ Success = $false; Code = $null; Location = $otpLocation; Jar = $Jar; Error = 'redirect without code' }
            }

            $otpBody = $otpResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return @{
                Success = $false; Code = $null; Html = $otpBody; Jar = $Jar; OtpUsed = $code
                PromptedForPassword = $true; PromptedForOtp = $true
                Error = "OTP rejected (status $($otpResp.StatusCode.value__))"
            }
        }

        return @{ Success = $false; Code = $null; Html = $body; Jar = $Jar; Error = "status $($resp.StatusCode.value__)" }
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-TokenExchange {
    param([string]$Code, [string]$Verifier)
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/realms/$Realm/protocol/openid-connect/token" -Body @{
        grant_type    = 'authorization_code'
        client_id     = $ClientId
        code          = $Code
        redirect_uri  = $RedirectUri
        code_verifier = $Verifier
    }
}

# Logs in and returns the access token in one step.
function Get-UserAccessToken {
    param([string]$Username, [string]$Password)
    $login = Invoke-PkceLogin -Username $Username -Password $Password
    if (-not $login.Success) { throw "Login failed for ${Username}: $($login.Error)" }
    (Invoke-TokenExchange -Code $login.Code -Verifier $login.Verifier).access_token
}

# Calls the resource server. Returns status + body instead of throwing, so the
# tests can assert on 401/403 as first-class outcomes.
function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Token,
        [string]$Method = 'Get',
        [string]$Origin
    )
    $client = New-HttpClient
    try {
        # Uppercase for the same reason as Invoke-JsonRequest - see the note there.
        $verb = New-Object System.Net.Http.HttpMethod -ArgumentList $Method.ToUpperInvariant()
        $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ($verb, "$ApiBaseUrl$Path")
        if ($Token)  { [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token") }
        if ($Origin) { [void]$req.Headers.TryAddWithoutValidation('Origin', $Origin) }

        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        $parsed = $null
        if ($body) { try { $parsed = $body | ConvertFrom-Json } catch { } }

        @{ Status = $resp.StatusCode.value__; Body = $body; Json = $parsed; Response = $resp }
    }
    finally {
        $client.Dispose()
    }
}

# ------------------------------------------------------------- admin api ---

function Get-AdminToken {
    param([hashtable]$Env)
    $body = @{
        grant_type = 'password'
        client_id  = 'admin-cli'
        username   = $Env['KC_BOOTSTRAP_ADMIN_USERNAME']
        password   = $Env['KC_BOOTSTRAP_ADMIN_PASSWORD']
    }
    (Invoke-RestMethod -Method Post -Uri "$BaseUrl/realms/master/protocol/openid-connect/token" -Body $body).access_token
}

function Invoke-AdminApi {
    param([string]$Token, [string]$Path, [string]$Method = 'Get', $Body)
    $params = @{
        Method  = $Method
        Uri     = "$BaseUrl/admin/realms/$Path"
        Headers = @{ Authorization = "Bearer $Token" }
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = 'application/json'
    }
    Invoke-RestMethod @params
}

<#
    Active SSO sessions for a user.

    Do not call the endpoint directly and count the result. When the user has no
    sessions Keycloak answers `[]`, and Invoke-RestMethod hands that back as a
    single empty-array object - so `@(...)` reports Count = 1 and a revocation
    test passes when nothing was revoked, or fails when everything was. Filtering
    on a field every real session has is what makes the count trustworthy.

    Callers must still wrap the result in @() - PowerShell unrolls a
    single-element array on return, and a lone session comes back as a scalar
    whose .Count is $null. Same rule as Get-MailboxMessages.
#>
function Get-UserSessionList {
    param([string]$Token, [string]$UserId)
    @((Invoke-AdminApi -Token $Token -Path "$Realm/users/$UserId/sessions") | Where-Object { $_.id })
}

# ------------------------------------------------------- json over http ---

<#
    Status-first HTTP. Invoke-RestMethod throws on 4xx, which makes "assert this
    is forbidden" awkward; these return the status as data instead.
#>
function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = 'Get',
        $Body,
        [hashtable]$Headers = @{}
    )
    $client = New-HttpClient
    try {
        # Uppercase deliberately. HTTP method tokens are case-sensitive, and
        # HttpMethod does not normalize them - it hands 'Patch' to the wire
        # verbatim. Node's parser rejects that with a bare 400 before Express
        # ever sees the request, so the server logs nothing and the failure
        # looks like a routing bug. 'Get'/'Post' happen to survive because
        # .NET Framework normalizes its own table of known verbs; PATCH and
        # DELETE do not get that treatment here.
        $verb = New-Object System.Net.Http.HttpMethod -ArgumentList $Method.ToUpperInvariant()
        $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ($verb, $Url)
        foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, $Headers[$k]) }
        if ($null -ne $Body) {
            $json = ($Body | ConvertTo-Json -Depth 10)
            $req.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
        }

        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        $parsed = $null
        if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { } }

        @{ Status = $resp.StatusCode.value__; Body = $text; Json = $parsed }
    }
    finally {
        $client.Dispose()
    }
}

<#
    Waits until Keycloak actually serves the realm on its public port.

    The container healthcheck is not enough. After a restart, /health/ready on
    :9000 reports UP while :8080 still answers every request with the plain-text
    body "Bootstrap in progress. Retry in 1 seconds." A test that starts as soon
    as the container is healthy therefore sees neither a login form nor a
    redirect, and reports a lost session when the session is fine.
#>
function Wait-ForRealmEndpoint {
    param([int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $probe = Invoke-JsonRequest -Url "$BaseUrl/realms/$Realm/.well-known/openid-configuration"
        if ($probe.Status -eq 200 -and $probe.Body -notmatch 'Bootstrap in progress') { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ------------------------------------------------------- marshall mock ---

# Calls the Phase 5 provisioning mock, i.e. simulates a Marshall lifecycle event.
function Invoke-MarshallApi {
    param([Parameter(Mandatory)][string]$Path, [string]$Method = 'Get', $Body)
    Invoke-JsonRequest -Url "$MarshallUrl$Path" -Method $Method -Body $Body
}

<#
    The token the mock itself uses: client_credentials against the
    `marshall-provisioning` service-account client. Tests borrow it to prove the
    least-privilege boundary directly, without going through the mock.
#>
function Get-ServiceAccountToken {
    param([hashtable]$Env)
    (Invoke-RestMethod -Method Post -Uri "$BaseUrl/realms/$Realm/protocol/openid-connect/token" -Body @{
        grant_type    = 'client_credentials'
        client_id     = 'marshall-provisioning'
        client_secret = $Env['MARSHALL_CLIENT_SECRET']
    }).access_token
}

# Admin API call that reports 403 rather than throwing it.
function Invoke-AdminApiStatus {
    param([string]$Token, [string]$Path, [string]$Method = 'Get', $Body)
    Invoke-JsonRequest -Url "$BaseUrl/admin/realms/$Path" -Method $Method -Body $Body `
                       -Headers @{ Authorization = "Bearer $Token" }
}

# Redeems a refresh token. Used to show that revocation kills refresh while an
# already-issued access token keeps working to its expiry.
function Invoke-RefreshGrant {
    param([string]$RefreshToken)
    $client = New-HttpClient
    try {
        $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[String,String]]'
        @{ grant_type = 'refresh_token'; client_id = $ClientId; refresh_token = $RefreshToken }.GetEnumerator() |
            ForEach-Object { $pairs.Add((New-Object 'System.Collections.Generic.KeyValuePair[String,String]'($_.Key, $_.Value))) }
        $content = New-Object System.Net.Http.FormUrlEncodedContent -ArgumentList (, $pairs)

        $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Post, "$BaseUrl/realms/$Realm/protocol/openid-connect/token")
        $req.Content = $content

        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = $null
        if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { } }

        @{ Status = $resp.StatusCode.value__; Body = $text; Json = $parsed }
    }
    finally {
        $client.Dispose()
    }
}
