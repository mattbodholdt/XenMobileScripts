## XenMobile - Disabled Users
## Removes BYOD devices with "anonymous" (ad disabled) users and reports on corp devices
## Intended to run as a scheduled task but can be run manually
## You may need to adjust the Send-MailMessage params to meet your reqirements
## Use at your own risk.  No implied warranty. 
## Matt Bodholdt - 9/2017

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$debug = $true

## XMS Base URL must havea trusted cert or the requests will fail
$xmsbaseurl = "xms.company.com:4443"

## Mail info
$sendmail = $true
$mailserver = "mail.company.com"
$fromemail = "XenMobile_Look.At.It@company.com"
[string[]]$toemail = "email1@company.com", "email2@company.com"

$outputdir = "\\server\share\"

$filesavedate = (Get-Date).tostring("yyyyMMdd-hhmmss")

## Auth with pw written to a file, user must have access to the xms rest api
$username = "XM_REST_USER"
$pwdTxt = Get-Content "\\server\share\encrpytedpw.txt"
$securePwd = $pwdTxt | ConvertTo-SecureString 
$creds = New-Object System.Management.Automation.PSCredential -ArgumentList $username, $securePwd
Clear-Variable pwdTxt, securePwd

## or Auth in pop up box
#$creds = Get-Credential

 $authbody = @" { "login":"$($creds.GetNetworkCredential().UserName)", "password":"$($creds.GetNetworkCredential().password)" }
"@
$logoutbody = @"
{“login”:”$($creds.GetNetworkCredential().UserName)”}
"@
Clear-Variable creds

function Logout { Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/logout" -ContentType "application/json" -Headers $authheader -Body $logoutbody | Out-Null }

$authtoken = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/login" -ContentType "application/json" -Body $authbody
Clear-Variable authbody
if ($authtoken.auth_token -eq $null) { if ($sendmail -eq $true) { Send-MailMessage -SmtpServer $mailserver -Port 25 -From $fromemail -To $toemail -Subject "XenMobile Automation - Auth Failure - Inactive Removal" } ; throw "Authentication failure" }
$authheader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$authheader.Add("auth_token", "$($authtoken.auth_token)")
Clear-Variable authtoken


## Query for devices, adjust the search value.  Notice the limit value.
$search = "anonymous"
$devicefilterbody = @"
{
 "start": "0",
 "limit": "5000",
 "sortOrder": "ASC",
 "sortColumn": "ID",
 "enableCount": "false",
 "search": "$($search)"
}"@

$devicefilter = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/filter" -ContentType "application/json" -Headers $authheader -Body $devicefilterbody
if ($devicefilter.status -ne 0) { if ($sendmail -eq $true) { Send-MailMessage -SmtpServer $mailserver -Port 25 -From $fromemail -To $toemail -Subject "XenMobile Automation - Device Search Error - $($devicefilter.message)" } ; throw "$($devicefilter.message)" }

if (($devicefilter.filteredDevicesDataList) -ne $null) { 

$removed = @()
$failedremove = @()
$corpdevices = @()
$devicefilter.filteredDevicesDataList  | foreach {

        if (($_.properties | where {$_.name -like "CORPORATE_OWNED"}).value -eq 1) { #corporate owned
            $ownership = "CORPORATE"
            if ($_.platform -like "iOS") { $platform = "iOS" }
            else { $platform = "SHTP" }
        }
        elseif (($_.properties | where {$_.name -like "CORPORATE_OWNED"}).value -eq 0) { #byod
            $ownership = "BYOD"
            if ($_.platform -like "iOS") { $platform = "iOS" }
            else { $platform = "SHTP" }
        }

if ($ownership -like "BYOD") { 
$removal = Invoke-RestMethod -Method Delete -Uri "https://$($xmsbaseurl)/xenmobile/api/v1/device/$($_.id)" -ContentType "application/json" -Headers $authheader

if ($removal.status -ne 0) { 
$removalerrorobject = New-Object PSObject -Property @{
UserName = $_.userName
SerialNumber = $_.serialnumber
Platform = $platform
Ownership = $ownership
Time = Get-Date -Format s
Inactivity = $_.inactivitydays
}
$failedremove += $removalerrorobject
Clear-Variable removalerrorobject
}
else { 
$removalobject = New-Object PSObject -Property @{
UserName = $_.userName
SerialNumber = $_.serialnumber
Platform = $platform
Ownership = $ownership
Time = Get-Date -Format s
Inactivity = $_.inactivitydays
}
$removed += $removalobject
Clear-Variable removalobject
}
Clear-Variable removal, platform, ownership
}
else { # Corporate owned
$corpobject = New-Object PSObject -Property @{
UserName = $_.userName
SerialNumber = $_.serialnumber
Platform = $platform
Ownership = $ownership
Time = Get-Date -Format s
Inactivity = $_.inactivitydays
}
$corpdevices += $corpobject
Clear-Variable corpobject
}

}
#end foreach device

}
#end device list not null
else { $nothingprocessed = $true }

Logout

if ($removed -ne $null) { if ($debug -eq $true) { Write-Host $removed.count "Devices removed" }
$removed | Export-Csv -Path "$($outputdir)byod_disabled_user_device_removals.csv" -NoTypeInformation -Append }
if ($failedremove -ne $null) { if ($debug -eq $true) { Write-Host $failedremove.count "Device Removal Failures" }
$failedremove | Export-Csv -Path "$($outputdir)byod_disabled_user_device_removal_failures" -NoTypeInformation -Append }
if ($corpdevices -ne $null) { if ($debug -eq $true) { Write-Host $corpdevices.count "Corp Devices Not Removed" }
$corpdevices | Export-Csv -Path "$($outputdir)corp_disabled_user_devices.csv" -NoTypeInformation -Append }

$reportarray = New-Object PSObject -Property @{
BYODRemoved = $removed.count
BYODFailedRemove = $failedremove.count
CorpDevices = $corpdevices.count
}

$style = "<style>BODY{font-family: Arial; font-size: 10pt;}"
$style = $style + "TABLE{border: 1px solid black; border-collapse: collapse;}"
$style = $style + "TH{border: 1px solid black; background: #dddddd; padding: 5px; }"
$style = $style + "TD{border: 1px solid black; padding: 5px; }"
$style = $style + "</style>"

$body = $reportarray | select BYODRemoved, BYODFailedRemove, CorpDevices | ConvertTo-Html -Head $style
if ($corpdevices -ne $null) { $cd = $corpdevices | select UserName, SerialNumber, Platform, Inactivity | ConvertTo-Html -Head $style }
$body = ($body -replace '</body></html>') + "<h5>See $($outputdir)</h5>"
if ($nothingprocessed -eq $true) { $body = $body + '<h5>No devices were processed, none meet the criteria</h5>' }
if ($corpdevices -ne $null) { $body = $body + $cd  }
$body = $body + '</body></html>' | Out-String

if ($sendmail -eq $true) { Send-MailMessage -SmtpServer $mailserver -Port 25 -From $fromemail -To $toemail -Subject "XenMobile Anonymous Users" -BodyAsHtml $body }
