## XenMobile - Export Enterprise Managed WiFi MAC Addresses
## Designed to run as a scheduled task but can be run manually
## Use at your own risk.  No implied warranty. 
## Matt Bodholdt - 8/2017

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

## Set to true for on screen output
$debug = $false

## XMS Base URL must havea trusted cert or the requests will fail
$xmsbaseurl = "xms.company.com:4443"

$outdir = "\\server\share\"

## Auth with pw written to a file, user must have access to the XMS rest api (See "Encrypted_Credentials_To_File.ps1).  Needed if ran as a scheduled task
$username = "XMS_API_USER"
$cpath = Get-Content "\\server\share\encrpytedpw.txt"
$securePwd = $cpath | ConvertTo-SecureString 
$creds = New-Object System.Management.Automation.PSCredential -ArgumentList $username, $securePwd

## or Auth in pop up box
#$creds = Get-Credential

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

## Get device list.  Notice limit.
$devicefilterbody = @"
{
 "start": "0",
 "limit": "5000",
 "sortOrder": "ASC",
 "sortColumn": "ID",
 "enableCount": "false",
 "filterIds": "['device.mode.enterprise.managed']"
}"@

$devicefilter = Invoke-RestMethod -Method POST –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/filter" -ContentType "application/json" -Headers $authheader -Body $devicefilterbody

## export the property
if ($devicefilter.filteredDevicesDataList -ne $null) { ($devicefilter.filteredDevicesDataList).wifiMacAddress | Export-Csv -Path "$($outdir)\managed_device_wifi_macs.csv" -NoTypeInformation }
else { if ($debug -eq $true) { Write-Warning "No devices returned, list not exported" } }

Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/logout" -ContentType "application/json" -Headers $authheader -Body $logoutbody | Out-Null