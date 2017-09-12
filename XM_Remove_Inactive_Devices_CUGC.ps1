## XenMobile - Remove Inactive Devices
## Designed to run as a scheduled task but can be run manually
## You may need to adjust the Send-MailMessage params to meet your environments requirements
## Use at your own risk.  No implied warranty. 
## Matt Bodholdt 8/2017

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

## Set debug to $true for on screen feedback
$debug = $true

## XMS Base URL must have a trusted cert
$xmsbaseurl = "xms.company.com:4443"
$logdir = "\\server\share\"

## Inactivity threshold.  Devices inactive this value or longer will be removed
$inactivitydays = 60

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

## Auth
$authtoken = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/login" -ContentType "application/json" -Body $authbody
Clear-Variable authbody
if ($authtoken.auth_token -eq $null) { throw "Authentication Failure" }
$authheader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$authheader.Add("auth_token", "$($authtoken.auth_token)")
Clear-Variable authtoken
#

## Query for devices.  Notice limit and the filter.
$devicefilterbody = @"
{
 "start": "0",
 "limit": "5000",
 "sortOrder": "ASC",
 "sortColumn": "ID",
 "enableCount": "false",
 "filterIds": "['device.inactive.time.more.than.30.days']"
}"@

$devicefilter = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/filter" -ContentType "application/json" -Headers $authheader -Body $devicefilterbody
if ($devicefilter.status -ne 0) { Send-MailMessage -SmtpServer $mailserver -Port 25 -From $fromemail -To $toemail -Subject "XenMobile Automation - Device Search Error - $($devicefilter.message)" ; throw "$($devicefilter.message)" }

$removed = @()
$failedremove = @()

## Device removal and logging
$devicefilter.filteredDevicesDataList | where {$_.inactivitydays -ge $inactivitydays} | sort -Property inactivitydays -Descending  | foreach {

        if (($_.properties | where {$_.name -like "CORPORATE_OWNED"}).value -eq 1) { #corporate owned
            $ownership = "CORPORATE"
            $platform = $_.platform
        }
        elseif (($_.properties | where {$_.name -like "CORPORATE_OWNED"}).value -eq 0) { #byod
            $ownership = "BYOD"
            $platform = $_.platform 
        }
        else { $ownership = "NOPROPERTY"
               $platform = $_.platform
        }

$removal = Invoke-RestMethod -Method Delete -Uri "https://$($xmsbaseurl)/xenmobile/api/v1/device/$($_.id)" -ContentType "application/json" -Headers $authheader

if ($removal.status -ne 0) { 
$removalerrorobject = New-Object PSObject -Property @{
UserName = if ($_.userName -notlike "Device Enrollment*") { $_.username.Split("@")[0] }
           else { "DEP User" }
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
UserName = if ($_.userName -notlike "Device Enrollment*") { $_.username.Split("@")[0] }
           else { "DEP User" }
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
#end foreach device

## Logging to csv
if ($removed -ne $null) { if ($debug -eq $true) { Write-Warning "$($removed.count) Devices removed" }
$removed | Export-Csv -Path "$($logdir)\inactive_removals.csv" -NoTypeInformation -Append }
if ($failedremove -ne $null) { if ($debug -eq $true) { Write-Warning "$($failedremove.count) Device Removal Failures" }
$failedremove | Export-Csv -Path "$($logdir)\inactive_removal_failures.csv" -NoTypeInformation -Append }

#Logout
Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/logout" -ContentType "application/json" -Headers $authheader -Body $logoutbody | Out-Null