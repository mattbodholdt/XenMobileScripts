## XenMobile - Add Custom Device Property Or Update Existing Property
## Use case: If you have an app (or policy, etc) that you want to test but have difficulty peeling off a set of devices into a different delivery group: 
##     Use this script to set the custom attribute on the device then use an advanced deployment rule to filter.  Ex: Limit by known device property name TEST_WITH_THIS is equal to Yes
## Use at your own risk.  No implied warranty. 
## Matt Bodholdt - 8/2017

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

## XMS base URL:port  Must be a valid, trusted cert
$xmsbaseurl = "xms.company.com:4443"

## Device search value, use this variable to query for a list of devices.  Seach by username, serial number, etc
$search = "username"

## To filter to only the platform specified, if this variable is commented out all devices returned in search will be acted on.  Ex "iOS", "Android"
$platformfilter = "iOS"

## Custom property name/value
$propertyname = "TEST_WITH_THIS"
$propertyvalue = "Yes"

$addpropertybody = @"
{
 "name": "$($propertyname)",
 "value": "$($propertyvalue)"
}
"@

## Auth in pop up box
$creds = Get-Credential
if ($creds -eq $null) { throw "No credentails provided" }

 $authbody = @" { "login":"$($creds.GetNetworkCredential().UserName)", "password":"$($creds.GetNetworkCredential().password)" }
"@
$logoutbody = @"
 {“login”:”$($creds.GetNetworkCredential().UserName)”}
"@
Clear-Variable creds

$authtoken = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/login" -ContentType "application/json" -Body $authbody
Clear-Variable authbody
if ($authtoken.auth_token -eq $null) { throw "Authentication failure" }
$authheader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$authheader.Add("auth_token", "$($authtoken.auth_token)")
Clear-Variable authtoken


## Query for devices, adjust the search value.  Notice the limit value.
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

## If platformfilter is populated, filter the device list further
if ($platformfilter -ne $null) { $filteredlist = $devicefilter.filteredDevicesDataList | where {($_.platform -like "$($platformfilter)")} }
else { $filteredlist = $devicefilter.filteredDevicesDataList }


## Per device actions
$success = $()
$alreadypresent = @()
$failure = @()
$unknown = @()

$filteredlist | foreach { 
$propertycheck = ($_.properties | where {$_.name -like "$($propertyname)"})
    if ($propertycheck.value -notlike "$($propertyvalue)") { ## add the custom property

    $add = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/property/$($_.id)" -ContentType "application/json" -Headers $authheader -Body $addpropertybody
        if ($add.status -eq 0) { $success += $_.serialnumber }
        elseif ($add.status -ne 0) { $failure += $_.serialnumber }
        else { $unknown += $_.serialnumber }
    Clear-Variable add
    }
    else  { $alreadypresent += $_.serialnumber }
Clear-Variable propertycheck
}

## Write action counts
Write-Output "$($success.count) successfully added"
Write-Output "$($failure.count) failed to add"
Write-Output "$($alreadypresent.count) already present"
if ($unknown -ne $null) { Write-Output "$($unknown.count) unknown (see `$unknown)" }

Clear-Variable devicefilter, filteredlist, platformfilter, search

## Logout
Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/logout" -ContentType "application/json" -Headers $authheader -Body $logoutbody | Out-Null