## XenMobile Device Reporting
## Use at your own risk.  No implied warranty. This script is only reading data from XMS
## Requires Active Directory powershell snapin, optionally Citrix.Licensing.Admin
## Depending on the number of devices you have, this might take a little bit to finish.  2k devices in about 5 min, give or take!  Also, note the limit value in $devicefilterbody
## You may need to modify the Send-MailMessage commands to match you environment if you choose to send mail
## Matt Bodholdt - 8/2017

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Debug to $true for a little on screen output
$debug = $true

if ((Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue) -eq $null) { throw "AD module not present" }

$xmsbaseurl = "xms.company.com:4443"
$licenseserver = "ctxlicenseserver.fqdn.company.com"
$outputdir = "\\server\share\"
$savedate = (Get-Date).ToString("MM-dd-yyyy")

## Auth to XMS with pw written to a file or pop up, user must have access to the XenMobile rest api
#  (See "Encrypted_Credentials_To_File_CUGC.ps1).  This is needed if ran as a scheduled task, otherwise you can use get-credential
$username = "XMS_RESTAPI_USER"
$cpath = Get-Content "\\server\share\encrpytedpw.txt"
$securePwd = $cpath | ConvertTo-SecureString 
$creds = New-Object System.Management.Automation.PSCredential -ArgumentList $username, $securePwd

## Or Auth in pop-up, comment out the above lines in that case
#$creds = Get-Credential

# Set sendmail to $false to not send reports via email
$sendmail = $true
$mailserver = "mail.company.com"
$fromemail = "XenMobile_Look.At.It@company.com"
[string[]]$toemail = "email1@company.com", "email2@company.com"

$time = Measure-Command { 

##License Server
if ((Get-PSSnapin -Name Citrix.Licensing.Admin.* -ErrorAction SilentlyContinue) -eq $null) { Add-PsSnapin Citrix.Licensing.Admin.* }

if ((Get-PSSnapin -Name Citrix.Licensing.Admin.* -ErrorAction SilentlyContinue) -ne $null -and ($licenseserver -ne $null)) {
    $overalllicensearray = @()
    $licinventoryCXM = Get-LicInventory -AdminAddress $licenseserver | where-object { $_.LocalizedLicenseProductName -like "Citrix XenMobile Enterprise Edition" } | ForEach-Object {

        $licobjarray = @()
        $realavailable = $_.LicensesAvailable - $_.LicenseOverdraft
        $withoverageavailable = $_.LicensesAvailable

        $licobjarray = New-Object PSObject -Property @{
        LicensesInUse = $_.LicensesInUse
        LicensesAvailableWOOverage = $realavailable
        LicensesAvailableWithOverage = $withoverageavailable
        }

        $overalllicensearray += $licobjarray
        Clear-Variable realavailable, withoverageavailable, realavailable -ErrorAction SilentlyContinue
        }

    $totalinuse = ($overalllicensearray.LicensesInUse | Measure-Object -Sum).Sum
    $totalrealavail = ($overalllicensearray.LicensesAvailableWOOverage | Measure-Object -Sum).Sum
    $totalavailwithoverage = ($overalllicensearray.LicensesAvailableWithOverage | Measure-Object -Sum).Sum
    $percentageused = $totalinuse / $totalrealavail
}
else { if ($debug -eq $true) { Write-Warning "Citrix Licensing PSSnapin Not Available or License Server Not Specified" } }
#### End of license server

### XMS Stuff

 $authbody = @" { "login":"$($creds.GetNetworkCredential().UserName)", "password":"$($creds.GetNetworkCredential().password)" }
"@
$logoutbody = @"
{“login”:”$($creds.GetNetworkCredential().UserName)”}
"@
Clear-Variable creds ; if ($pwdTxt -ne $null) { Clear-Variable username, cpath, securePwd }

$authtoken = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/login" -ContentType "application/json" -Body $authbody
Clear-Variable authbody
if ($authtoken.auth_token -eq $null) { if ($sendmail -ne $false) { Send-MailMessage -SmtpServer $mailserver -Port 25 -From $fromemail -To $toemail -Subject "XenMobile Automation - Auth Failure - Reporting" } ; throw "Authentication failure" }
$authheader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$authheader.Add("auth_token", "$($authtoken.auth_token)")
Clear-Variable authtoken

## Return initial device list, note the limit value!
$devicefilterbody = @"
{
 "start": "0",
 "limit": "5000",
 "sortOrder": "ASC",
 "sortColumn": "ID",
 "enableCount": "false"
}"@
$devicefilter = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/filter" -ContentType "application/json" -Headers $authheader -Body $devicefilterbody

## Per Device
$overallarray = @()
$disabledusers = @()
$errorarray = @()
$origin = New-Object -Type DateTime -ArgumentList 1970, 1, 1, 0, 0, 0, 0

($devicefilter.filteredDevicesDataList | where { (($_.username -like "*@*") -or ($_.username -like "*Device Enrollment*"))}) | ForEach-Object { 

try { $devicedetail = Invoke-RestMethod -Method GET –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/$($_.id)" -ContentType "application/json" -Headers $authheader }
catch { $err = $_.message }
finally { if ($err -ne $null) { Write-Warning "$($err), $($_.serialnumber), $($_.id)" ; Clear-Variable err } }

if (($_.properties | where {$_.name -like "CORPORATE_OWNED"}).value -eq 1) { $ownership = "Corporate" }
elseif (($_.properties | where {$_.name -like "CORPORATE_OWNED"}).value -eq 0) { $ownership = "BYOD" }
else { $ownership = "Unknown" }

## Get user info from AD.  This is geared for a single domain environment as is...  you could switch the split character to the space to get a UPN if the dns suffix matches the users UPN suffix
if (($_.username -notlike "*Device Enrollment*")) {
    Try {$userdata = Get-ADUser ($_.username.Split("@")[0]) -Properties Department | select SamAccountName, Name, Department }
    Catch   { $ErrorMessage = $_.Exception.Message }
    Finally { if ($ErrorMessage -ne $null) { $errorarray += $ErrorMessage
    Clear-Variable ErrorMessage } }
}
else { $userdata = New-Object PSObject -Property @{
Name = "DEP User"
Department = "DEP"
}
}

if (($_.properties | where {$_.name -like "SUPERVISED"}).value -eq 1) { $supervised = "True" }
else { $supervised = "False" }

$outputobject = New-Object PSObject -Property @{
UserName = $userdata.Name
SamAccountName = if ($UserData.Name -notlike "DEP User") { ($_.username.Split("@")[0]) }
                 else { "DEP User" }
Department = $userdata.department
Platform = $_.platform
DeviceModel = $_.deviceType
OwnedBy = $ownership
Supervised = $supervised
serialNumber = $_.serialnumber
managed = $_.managed
mdmKnown = $_.mdmknown
mamKnown = $_.mamknown
firstConnectionDate = ($origin.AddMilliseconds($devicedetail.device.firstConnectionDate)).ToLocalTime()
lastAccess = ($origin.AddMilliseconds($devicedetail.device.lastActivity)).ToLocalTime()
lastSoftwareInventoryTime = ($origin.AddMilliseconds($devicedetail.device.lastSoftwareInventoryTime)).ToLocalTime()
inactivityDays = $_.inactivityDays
OSVersion = ($_.properties | where {$_.name -like "SYSTEM_OS_VERSION"}).value
SecureHubVersion = ($_.properties | where {$_.name -like "EW_VERSION"}).value
SecureMailVersion = if (($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.citrix.mail*"}).version -ne $null) { ($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.citrix.mail*"}).version }
                    else { "NA" }
SecureWebVersion = if (($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.citrix.browser*"}).version -ne $null) { ($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.citrix.browser*"}).version }
                   else { "NA" }
SharefileVersion = if (($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.sharefile*"}).version -ne $null) { ($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.sharefile*"}).version }
                   else { "NA" }
SecureTasksVersion = if (($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.citrix.tasks*"}).version -ne $null) { ($devicedetail.device.softwareInventory | where {$_.packageInfo -like "com.citrix.tasks*"}).version }
                     else { "NA" }
}

if ($userdata -ne $null ) { $overallarray += $outputobject }
else { $disabledusers += $outputobject }

Clear-Variable userdata, outputobject, devicedetail, ownership, supervised
}

## Create output directory and export data to CSV
if ((Test-Path -Path ("$($outputdir)" + "$($savedate)")) -eq $false) { New-Item -ItemType Directory -Path ("$($outputdir)" + "$($savedate)") | Out-Null }
$overallarray | select SamAccountName, UserName, Department, Platform, DeviceModel, OSVersion, SecureHubVersion, SecureMailVersion, SecureWebVersion, SharefileVersion, SecureTasksVersion, Supervised, serialNumber, OwnedBy, managed, mdmKnown, mamknown, lastAccess, inactivityDays, lastSoftwareInventoryTime, firstConnectionDate | sort -Property SamAccountName | Export-Csv -Path ("$($outputdir)" + "$($savedate)" + "\XM_Enrolled_Devices.csv") -NoTypeInformation
$overallarray | select SamAccountName, UserName, Department | sort -Property SamAccountName -Unique | Export-Csv ("$($outputdir)" + "$($savedate)" + "\XM_Unique_Users_w_Dept.csv") -NoTypeInformation
$disabledusers | select SamAccountName, UserName, Department, Platform, DeviceModel, OSVersion, SecureHubVersion, SecureMailVersion, SecureWebVersion, SharefileVersion, SecureTasksVersion, Supervised, serialNumber, OwnedBy, managed, mdmKnown, mamknown, lastAccess, inactivityDays, lastSoftwareInventoryTime, firstConnectionDate | sort -Property SamAccountName | Export-Csv -Path ("$($outputdir)" + "$($savedate)" + "\XM_Disabled_Users.csv") -NoTypeInformation

## email reports and counts
if ($sendmail -ne $false) {
Send-MailMessage -SmtpServer $mailserver -Port 25 -From $fromemail -To $toemail -Subject "XenMobile Monthly Reports" -Attachments ("$($outputdir)" + "$($savedate)" + "\XM_Enrolled_Devices.csv"), ("$($outputdir)" + "$($savedate)" + "\XM_Unique_Users_w_Dept.csv"), ("$($outputdir)" + "$($savedate)" + "\XM_Disabled_Users.csv") -BodyAsHTML @"
XenMobile Reports <br> $((get-date).DateTime)
<br>
$(if ($totalrealavail -ne $null) { "$($totalrealavail) CXM User licenses installed w/o overage" })
<br>
$(($overallarray | where {$_.UserName -notlike "DEP User"}).count) Total devices with domain users
<br>
$(($overallarray | where {$_.UserName -like "DEP User"}).count) Total DEP User Devices
<br>
$(($overallarray | select -Property SamAccountName -Unique).count) XenMobile Unique Users
"@
}

## On screen output
if ($debug -eq $true) { if ($disabledusers -ne $null) { Write-Output $disabledusers.count "disabled user(s) in XM" -ForegroundColor Black -BackgroundColor Gray }
Write-Host ""
Write-Host "$($devicefilter.filteredDevicesDataList | where { ($_.username -like "*@*")}.count) Total devices with users"
Write-Host "$(($devicefilter.filteredDevicesDataList | where { ($_.username -like "*Device Enrollment*")}).count) Total DEP User Devices"
Write-Host "$(($overallarray | select -Property SamAccountName -Unique).count) XenMobile Unique Users"
Write-Host ""

if ($overalllicensearray -ne $null) {
Write-Host "$($totalinuse) CXM User licenses checked out which is" $("{0:P2}" -f  $percentageused)
Write-Host "$($totalrealavail) CXM User licenses installed w/o overage"
Write-Host "$($totalavailwithoverage) CXM User licenses installed including overage"
Write-Host "" }
else { Write-Host "CTX license server data not collected" }

Write-Output "Output files saved to $($outputdir)"
if ($errorarray -ne $null) { Write-Output "$($errorarray.count) Errors" }
}

Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/logout" -ContentType "application/json" -Headers $authheader -Body $logoutbody

}

if ($debug -eq $true) { Write-Output " $($time.TotalMinutes) minutes to run" }