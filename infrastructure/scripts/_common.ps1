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
$Realm       = 'guarantee-gateway'
$ClientId    = 'guarantee-gateway-za'
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
        [hashtable]$Jar = @{}
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
                    Jar = $Jar; PromptedForPassword = $false; Location = $loc
                }
            }
            return @{ Success = $false; Code = $null; Location = $loc; Jar = $Jar; Error = 'redirect without code' }
        }

        $html = $page.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($html -notmatch '(?s)id="kc-form-login".*?action="([^"]+)"') {
            return @{ Success = $false; Code = $null; Html = $html; Jar = $Jar; Error = 'login form not found' }
        }
        $action = [System.Net.WebUtility]::HtmlDecode($Matches[1])

        $resp = Invoke-FormPost -Client $client -Url $action -Jar $Jar -Fields @{
            username = $Username
            password = $Password
        }

        if ($resp.StatusCode.value__ -ge 300 -and $resp.StatusCode.value__ -lt 400 -and $resp.Headers.Location) {
            $location = $resp.Headers.Location.ToString()
            if ($location -match '[?&]code=([^&]+)') {
                return @{
                    Success = $true; Code = $Matches[1]; Verifier = $verifier
                    Jar = $Jar; PromptedForPassword = $true; Location = $location
                }
            }
            return @{ Success = $false; Code = $null; Location = $location; Jar = $Jar; Error = 'redirect without code' }
        }

        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
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
