<#
.SYNOPSIS
    ROADMAP Phase 4 acceptance: every edge of the design.md §5 browser flow.

.DESCRIPTION
    Flow under test (all built-in authenticators plus the pinned email-OTP
    extension):

        guarantee-gateway-browser
        ├─ Cookie                    ALTERNATIVE
        └─ Forms                     ALTERNATIVE
           ├─ Username Password Form REQUIRED
           └─ Email OTP              REQUIRED

    Cases, taken straight from the mermaid diagram in design.md §5:
      1. Flow is bound and composed as specified
      2. Valid password + valid OTP  -> session + tokens
      3. OTP email is 6 digits and states its validity window
      4. Existing SSO cookie skips both forms
      5. Wrong password is rejected; a later correct login still works
         (counter below threshold)
      6. Wrong OTP is rejected, and a correct OTP afterwards still succeeds
      7. Failed OTP attempts count toward the SAME brute-force lockout
      8. Locked account rejects even a correct password + OTP
      9. Admin unlock restores login
     10. Whether Keycloak emails the user on lockout (design.md §6 claims it does)

    The script restores state (unlocks the account, clears the mailbox) so it is
    re-runnable.

.EXAMPLE
    .\infrastructure\scripts\test-otp-flow.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

Write-Host ''
Write-Host '=== Phase 4: email OTP browser flow ===' -ForegroundColor Cyan
$dotenv   = Get-DotEnv
$user     = $dotenv['POC_TEST_USER']
$password = $dotenv['POC_TEST_PASSWORD']
$token    = Get-AdminToken -Env $dotenv

$userId = (Invoke-AdminApi -Token $token -Path "$Realm/users?username=$([Uri]::EscapeDataString($user))&exact=true")[0].id

function Reset-UserState {
    # Clear any brute-force lockout and re-enable, so each case starts clean.
    try { [void](Invoke-AdminApi -Token $token -Method Delete -Path "$Realm/attack-detection/brute-force/users/$userId") } catch { }
    [void](Invoke-AdminApi -Token $token -Method Put -Path "$Realm/users/$userId" -Body @{ enabled = $true })
}

function Get-BruteForceStatus {
    Invoke-AdminApi -Token $token -Path "$Realm/attack-detection/brute-force/users/$userId"
}

Reset-UserState

# --- 1. Flow composition ---
Write-Host ''
Write-Host '1. Flow is bound and composed per design.md §5' -ForegroundColor Cyan
$realmCfg = Invoke-AdminApi -Token $token -Path $Realm
Assert-That -Name 'Realm browser flow is guarantee-gateway-browser' `
            -Condition ($realmCfg.browserFlow -eq 'guarantee-gateway-browser') -Detail "got: $($realmCfg.browserFlow)"

$executions = Invoke-AdminApi -Token $token -Path "$Realm/authentication/flows/guarantee-gateway-browser/executions"
$cookie = $executions | Where-Object { $_.providerId -eq 'auth-cookie' }
$forms  = $executions | Where-Object { $_.displayName -eq 'guarantee-gateway-forms' }
$pwd    = $executions | Where-Object { $_.providerId -eq 'auth-username-password-form' }
$otp    = $executions | Where-Object { $_.providerId -eq 'email-otp-authenticator' }

Assert-That -Name 'Cookie authenticator is ALTERNATIVE'        -Condition ($cookie.requirement -eq 'ALTERNATIVE') -Detail "got: $($cookie.requirement)"
Assert-That -Name 'Forms sub-flow is ALTERNATIVE'              -Condition ($forms.requirement -eq 'ALTERNATIVE') -Detail "got: $($forms.requirement)"
Assert-That -Name 'Username Password Form is REQUIRED'         -Condition ($pwd.requirement -eq 'REQUIRED') -Detail "got: $($pwd.requirement)"
Assert-That -Name 'Email OTP is REQUIRED'                      -Condition ($otp.requirement -eq 'REQUIRED') -Detail "got: $($otp.requirement)"
Assert-That -Name 'Email OTP nested under Forms (level 1)'     -Condition ($otp.level -eq 1) -Detail "level: $($otp.level)"

# --- 2. Happy path ---
Write-Host ''
Write-Host '2. Valid password + valid OTP' -ForegroundColor Cyan
Clear-Mailbox
$login = Invoke-PkceLogin -Username $user -Password $password
Assert-That -Name 'Login succeeds'              -Condition ([bool]$login.Success) -Detail $login.Error
Assert-That -Name 'Password form was presented' -Condition ($login.PromptedForPassword -eq $true)
Assert-That -Name 'OTP form was presented'      -Condition ($login.PromptedForOtp -eq $true)

if ($login.Success) {
    $tokens = Invoke-TokenExchange -Code $login.Code -Verifier $login.Verifier
    Assert-That -Name 'Tokens issued after OTP' -Condition ($null -ne $tokens.access_token)
    $ssoJar = $login.Jar
}

# --- 3. OTP email content ---
Write-Host ''
Write-Host '3. OTP email content' -ForegroundColor Cyan
$messages = @(Get-MailboxMessages -ToAddress $user)
Assert-That -Name 'An OTP email was delivered' -Condition ($messages.Count -ge 1) -Detail "messages: $($messages.Count)"
if ($messages.Count -ge 1) {
    $body = Get-MessageBody -Id $messages[0].ID
    Assert-That -Name 'OTP is 6 digits'                -Condition ($body -match '\b\d{6}\b') -Detail $body
    Assert-That -Name 'Email states a validity window' -Condition ($body -match 'valid for') -Detail $body
    Assert-That -Name "OTP used matches emailed code"  -Condition ($body -match [regex]::Escape($login.OtpUsed)) -Detail "used: $($login.OtpUsed)"
    Write-Host "    subject: $($messages[0].Subject)" -ForegroundColor DarkGray
    Write-Host "    body:    $body" -ForegroundColor DarkGray
}

# --- 4. SSO cookie skips both forms ---
Write-Host ''
Write-Host '4. Existing SSO session skips password and OTP' -ForegroundColor Cyan
if ($login.Success) {
    $again = Invoke-PkceLogin -Jar $ssoJar
    Assert-That -Name 'Authorization succeeds via cookie' -Condition ([bool]$again.Success) -Detail $again.Error
    Assert-That -Name 'No password prompt'                -Condition ($again.PromptedForPassword -eq $false)
    Assert-That -Name 'No OTP prompt (no second email)'   -Condition ($again.PromptedForOtp -eq $false)
}

# --- 5. Wrong password below threshold ---
Write-Host ''
Write-Host '5. Two wrong passwords, then a correct login' -ForegroundColor Cyan
Reset-UserState
# Spaced deliberately: attempts closer together than quickLoginCheckMilliSeconds
# trip a different protection entirely - covered in section 5b.
1..2 | ForEach-Object {
    [void](Invoke-PkceLogin -Username $user -Password 'DeliberatelyWrong!1')
    Start-Sleep -Seconds 2
}
$status = Get-BruteForceStatus
Assert-That -Name 'Account still enabled after 2 spaced failures' -Condition ($status.disabled -ne $true) -Detail "numFailures: $($status.numFailures)"

$recover = Invoke-PkceLogin -Username $user -Password $password
Assert-That -Name 'Correct login still succeeds' -Condition ([bool]$recover.Success) -Detail $recover.Error

# --- 5b. Quick-login detection (documents a real operational edge) ---
Write-Host ''
Write-Host '5b. Rapid failures trip quick-login detection before failureFactor' -ForegroundColor Cyan
Reset-UserState
1..2 | ForEach-Object { [void](Invoke-PkceLogin -Username $user -Password 'DeliberatelyWrong!1') }
$quick = Get-BruteForceStatus
Assert-That -Name 'TWO failures under 1s permanently disable the account' `
            -Condition ($quick.disabled -eq $true) `
            -Detail "numFailures: $($quick.numFailures) - quickLoginCheckMilliSeconds=1000 fires before failureFactor=3"
Write-Host '    Consequence: a double-submit or a retrying client locks a user at 2' -ForegroundColor DarkGray
Write-Host '    failures, not 3, and permanently. See docs/decision-email-otp-extension.md' -ForegroundColor DarkGray

# --- 6. Wrong OTP, then correct OTP ---
Write-Host ''
Write-Host '6. Wrong OTP is rejected; correct OTP afterwards succeeds' -ForegroundColor Cyan
Reset-UserState
$badOtp = Invoke-PkceLogin -Username $user -Password $password -OtpCode '000000'
Assert-That -Name 'Wrong OTP does not yield a code' -Condition (-not $badOtp.Success) -Detail "error: $($badOtp.Error)"
Assert-That -Name 'Wrong OTP reached the OTP step'  -Condition ($badOtp.PromptedForOtp -eq $true)

$goodOtp = Invoke-PkceLogin -Username $user -Password $password
Assert-That -Name 'Correct OTP then succeeds' -Condition ([bool]$goodOtp.Success) -Detail $goodOtp.Error

# --- 7. Failed OTPs and the lockout counter (the critical case) ---
#
# THIS ASSERTION IS EXPECTED TO FAIL against the current extension, and it is
# left failing on purpose: design.md §5 requires "failed OTP attempts count
# toward the same lockout", and they do not. Closing it needs a decision
# (switch to built-in TOTP, or accept the risk), not a code change here -
# writing our own authenticator is forbidden by ROADMAP constraint 2.
Write-Host ''
Write-Host '7. Do failed OTP attempts count toward lockout?' -ForegroundColor Cyan
Reset-UserState
1..3 | ForEach-Object {
    [void](Invoke-PkceLogin -Username $user -Password $password -OtpCode '000000')
    Start-Sleep -Seconds 2
}
$otpStatus = Get-BruteForceStatus
Write-Host "    numFailures after 3 bad OTPs: $($otpStatus.numFailures), disabled: $($otpStatus.disabled)" -ForegroundColor DarkGray
Assert-That -Name 'Three failed OTPs lock the account (design.md §5 requirement)' `
            -Condition ($otpStatus.disabled -eq $true) `
            -Detail "numFailures=$($otpStatus.numFailures). KNOWN GAP: the extension never calls the brute-force protector, so OTP guessing is unlimited within the code's 5-minute window. See docs/decision-email-otp-extension.md"

# --- 8/9. Lockout behaviour and unlock ---
Write-Host ''
Write-Host '8. Lockout blocks a fully correct login, admin unlock restores it' -ForegroundColor Cyan
Reset-UserState
1..3 | ForEach-Object { [void](Invoke-PkceLogin -Username $user -Password 'DeliberatelyWrong!1') }
Assert-That -Name 'Three bad passwords lock the account' -Condition ((Get-BruteForceStatus).disabled -eq $true)

Clear-Mailbox
$blocked = Invoke-PkceLogin -Username $user -Password $password
Assert-That -Name 'Correct credentials rejected while locked' -Condition (-not $blocked.Success)

# --- 9. Does Keycloak email the user on lockout? (design.md §6) ---
#
# It does not. design.md §6 states "Keycloak sends the suspicious-activity email
# - no links - via M365", but stock brute-force detection has no such
# notification. This assertion documents the real behaviour so the gap stays
# visible; the design document needs correcting, not the code.
Write-Host ''
Write-Host '9. Suspicious-activity email on lockout (design.md §6 claim)' -ForegroundColor Cyan
$lockedStatus = Get-BruteForceStatus
Write-Host "    account disabled before attempt: $($lockedStatus.disabled)" -ForegroundColor DarkGray
Clear-Mailbox
Start-Sleep -Seconds 2
$attempt = Invoke-PkceLogin -Username $user -Password $password   # blocked attempt on a locked account
Write-Host "    blocked attempt: success=$($attempt.Success) promptedOtp=$($attempt.PromptedForOtp)" -ForegroundColor DarkGray
Start-Sleep -Seconds 3
$lockoutMail = @(Get-MailboxMessages -ToAddress $user)
foreach ($m in $lockoutMail) {
    Write-Host "    unexpected mail: '$($m.Subject)' -> $(Get-MessageBody -Id $m.ID)" -ForegroundColor DarkGray
}
Assert-That -Name 'CONFIRMED: stock Keycloak sends NO lockout notification' `
            -Condition ($lockoutMail.Count -eq 0) `
            -Detail "messages: $($lockoutMail.Count)"
Write-Host '    design.md §6 assumes this email exists. It does not. Delivering it' -ForegroundColor DarkGray
Write-Host '    needs an event-listener SPI - which ROADMAP constraint 2 forbids -' -ForegroundColor DarkGray
Write-Host '    or an external job watching the audit log stream.' -ForegroundColor DarkGray

Reset-UserState
$restored = Invoke-PkceLogin -Username $user -Password $password
Assert-That -Name 'Admin unlock restores login' -Condition ([bool]$restored.Success) -Detail $restored.Error

Clear-Mailbox
Write-TestSummary
