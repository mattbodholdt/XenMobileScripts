## XenMobile - Issue enrollment pin from CSV list
## Note: will not generate multiple enrollments for a single user
## Geared for a single enrollment type two_factor.  Easily modified to match your needs though!
## Matt Bodholdt - 8/2017

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

## CSV with headers: UserName, Platform, Ownership
## Data Example: UserName, iOS, CORPORATE
## Data Example: UserName, Android, BYOD
$inputcsvpath = "\\server\share\enrollmentlist.csv"
$toissueenrollments = Import-Csv -Path $inputcsvpath | sort -Property UserName -Unique
if ($toissueenrollments -eq $null) { throw "No input data, check if $($inputcsvpath) exists" }

## XMS Base URL must have a trusted cert or the requests will fail
$xmsbaseurl = "xms.company.com:4443"

## Logging directory
$logdir = "\\server\share\outputdirectory"
if ((Test-Path -Path $logdir) -eq $false) { New-Item -ItemType Directory -Path $logdir  }

## Note: These notification templates need to be created in XMS beforehand!
# These are different, in my case, because I want to let the user know what type of device and the ownership flag of the enrollment in the notification that contains the pin
$iosbyodtemplate = "Enrollment PIN BYOD iOS"
$ioscorptemplate = "Enrollment PIN Corporate iOS"
$androidbyodtemplate = "Enrollment PIN BYOD Android"
$androidcorptemplate = "Enrollment PIN Corporate Android"

$creds = Get-Credential
if ($creds -eq $null) { throw "No Creds Provided" }

 $authbody = @" { "login":"$($creds.GetNetworkCredential().UserName)", "password":"$($creds.GetNetworkCredential().password)" }
"@

$logoutbody = @"
{“login”:”$($creds.GetNetworkCredential().UserName)”}
"@
Clear-Variable creds

$authtoken = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/login" -ContentType "application/json" -Body $authbody
Clear-Variable authbody
if ($authtoken.auth_token -eq $null) { throw "Authentication Failure" }
$authheader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$authheader.Add("auth_token", "$($authtoken.auth_token)")
Clear-Variable authtoken

$enrollmentstatusbody = @"
{
 "limit": "2000",
 "sortOrder": "ASC",
 "sortColumn": "ID",
 "enableCount": "false",
 "filterIds": "['enrollment.invitationStatus.pending']"
}
"@
$pendingenrollments = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/enrollment/filter" -ContentType "application/json" -Headers $authheader -Body $enrollmentstatusbody
if ($pendingenrollments.status -eq 0) { $pendingenrollments = $pendingenrollments.enrollmentFilterResponse.enrollmentList.enrollments.userName | foreach { $_.Split("@")[0] } | sort -Unique }
else { Write-Warning "Error enumerating pending enrollments, moving on" }

$errorarray = @()
$sentpins = @()
$toissueenrollments | ForEach-Object {

if ($pendingenrollments -notcontains $_.UserName) {

if ($_.Platform -like "iOS") { $platform = "iOS"
if ($_.Ownership -like "Corporate") { 
$ownership = "CORPORATE"
$pintemplate = "$($ioscorptemplate)" }
else { 
$ownership = "BYOD"
$pintemplate = "$($iosbyodtemplate)"
}
}

if ($_.Platform -like "Android") { 
$platform = "SHTP"
if ($_.Ownership -like "Corporate") { 
$ownership = "CORPORATE"
$pintemplate = "$($androidcorptemplate)" }
else { 
$ownership = "BYOD"
$pintemplate = "$($androidcorptemplate)"
}
}

$enrollmentbody = @"
{
 "platform": "$($platform)",
 "deviceOwnership": "$($ownership)",
 "mode": {
"name": "two_factor"
},
 "userName": "$($_.UserName)",
 "notificationTemplateCategories":[{
"category": "ENROLLMENT_AGENT",
"notificationTemplate": {
"name": "NONE"
}
},
{
"category": "ENROLLMENT_URL",
"notificationTemplate": {
"name": "Enrollment Invitation"
}
},
{
"category": "ENROLLMENT_PIN",
"notificationTemplate": {
"name": "$($pintemplate)"
}
},
{
"category": "ENROLLMENT_CONFIRMATION",
"notificationTemplate": {
"name": "Enrollment Confirmation"
}
}],

 "notifyNow": true
}
"@

$enrollmentrequest = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/enrollment" -ContentType "application/json" -Headers $authheader -Body $enrollmentbody

if ($enrollmentrequest.status -ne 0) { 
$errorobject = New-Object PSObject -Property @{
UserName = $_.UserName
Token = $enrollmentrequest.token
PinTemplate = $pintemplate
Platform = $platform
Ownership = $ownership
}
$errorarray += $errorobject 
Clear-Variable errorobject
Write-Host "Enrollment error for $($_.UserName) - $($platform) - $($pintemplate)" -ForegroundColor Black -BackgroundColor Red
}

else { 
$outputobject = New-Object PSObject -Property @{
UserName = $_.UserName
Token = $enrollmentrequest.token
PinTemplate = $pintemplate
Platform = $platform
Ownership = $ownership
}
$sentpins += $outputobject
Clear-Variable outputobject
Write-Host "Enrollment issued for $($_.UserName) - $($platform) - $($pintemplate)" -ForegroundColor Black -BackgroundColor Green
}
Clear-Variable ownership, platform, pintemplate, enrollmentrequest
}
else { Write-Host "Already a pending enrollment, no new enrollment issued" -ForegroundColor Black -BackgroundColor Yellow }
}
## End of Pin Generation

if ($errorarray -ne $null) { Write-Host $errorarray.count 'Errors, see $errorarray for who' 
$errorarray | select UserName, Token, Platform, Ownership, PinTemplate | Export-Csv -Path "$($logdir)\errors.csv" -Append -NoTypeInformation }
if ($sentpins -ne $null) { Write-Host $sentpins.count 'PINs Sent, see $sentpins'
$sentpins | select UserName, Token, Platform, Ownership, PinTemplate | Export-Csv -Path "$($logdir)\sent_pins.csv" -Append -NoTypeInformation }

Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/logout" -ContentType "application/json" -Headers $authheader -Body $logoutbody | Out-Null
