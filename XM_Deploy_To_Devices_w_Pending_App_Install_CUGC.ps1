## XM 10 Deploy to devices with Pending or Failed status for a specific app (iOS)
## REST API to XM (hosts entry required)
## 9/24/2016 - MB

$vars = Get-Variable -Scope Script

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$xmsbaseurl = "xms.company.com:4443"

function Select-TextItem 
{ 
PARAM  
( 
    [Parameter(Mandatory=$true)] 
    $options, 
    $displayProperty 
) 
 
    [int]$optionPrefix = 1 
    # Create menu list 
    foreach ($option in $options) 
    { 
        if ($displayProperty -eq $null) 
        { 
            Write-Host ("{0,3}: {1}" -f $optionPrefix,$option) 
        } 
        else 
        { 
            Write-Host ("{0,3}: {1}" -f $optionPrefix,$option.$displayProperty) 
        } 
        $optionPrefix++ 
    } 
    Write-Host ("{0,3}: {1}" -f 0,"To cancel")  
    [int]$response = Read-Host "Enter Selection" 
    $val = $null 
    if ($response -gt 0 -and $response -le $options.Count) 
    { 
        $val = $options[$response-1] 
    } 
    return $val 
}    

$creds = Get-Credential

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

$appsbody = @"
{
"limit": "50",
"applicationSortColumn": "name",
"sortOrder": "DESC",
"enableCount": false
}
"@
$appsreturn = (Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/application/filter" -ContentType "application/json" -Headers $authheader -Body $appsbody -TimeoutSec 3600).applicationListData.applist
if ($appsreturn -eq $null) { throw "No applications returned" }

$appname = Select-TextItem $appsreturn.name
$appid = ($appsreturn | where { $_.name -like $appname }).id
$appdetail = (Invoke-RestMethod -Method Get –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/application/mobile/$($appid)" -ContentType "application/json" -Headers $authheader).container

write-host "Checking for:"
write-host $appname
$appversion = Read-Host "Input the expected app version of $($appname) manually"
write-host $appversion
$platform = Read-Host "Specify platform (iOS or Android).  If blank it will return all types"
if (($platform -notlike "iOS") -and ($platform -notlike "Android")) { $platform = $null }

if ($platform -eq $null) { 
$devicefilterbody = @"
{
 "start": "0",
 "limit": "5000",
 "sortOrder": "ASC",
 "sortColumn": "ID",
 "enableCount": "false"
}"@
}
else {
$devicefilterbody = @"
{
 "start": "0",
 "limit": "5000",
 "sortOrder": "ASC",
 "sortColumn": "ID",
 "enableCount": "false",
 "filterIds": "['device.platform.$($platform)']"
}"@
}
$devices = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/filter" -ContentType "application/json" -Headers $authheader -Body $devicefilterbody
if ($devices.status -ne 0) { throw "Problem enumerating devices" }

##end 1

##start2
$devicestodeploy = @()
$good = @()
$notinstalled = @()
$other = @()
$failed = @()
$errors = @()

($devices.filteredDevicesDataList | where {(($_.userName -like "*@*") -and ($_.userName -notlike "Device Enrollment*"))}) | ForEach-Object {

try { $devicedetail = Invoke-RestMethod -Method Get –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/$($_.id)" -ContentType "application/json" -Headers $authheader }
catch { $err = $_.message }
finally { if ($err -ne $null) { Write-Warning "$($err), $($_.serialnumber), $($_.id)" ; Clear-Variable err } }

if ($devicedetail.status -ne 0) { $devicedetail.message ; $errors += $_ }
$app = $devicedetail.device.applications | where {$_.name -like $appname}
if ($app.status -like "SUCCESS") { $good += $devicedetail.device }
elseif ($app.status -like "AVAILABLE") { $notinstalled += $_devicedetail.device }
elseif ($app.status -like "PENDING") {$devicestodeploy += $devicedetail.device }
elseif ($app.status -like "FAILURE") { $failed += $devicedetail.device ; $devicestodeploy += $devicedetail.device }
else { $other += $devicedetail.device }
Clear-Variable app, devicedetail
}
##end 2

##start 3
$reallydodeploy = @()
$inactivitydevices = @()

$devicestodeploy | foreach {
if ($_.inactivitydays -eq 0) { $reallydodeploy += $_.id }
else { $inactivitydevices += $_.id }
}


## My app names don't match the installed names hence the namefilter variable.. w/e!
$notupdated = @()
$namefilter = ($appname.Split(" ") | select -First 2) -join " "
$good | foreach { $nu_temp = $_.softwareinventory | where {(($_.name -like $namefilter) -and ($_.version -notlike $appversion))} | select name, Version
if ($nu_temp -ne $null) { $notupdated += $_ ; Clear-Variable nu_temp} }

write-host ""
write-host $reallydodeploy.count "to deploy (pending and failed)"
write-host $inactivitydevices.count "to deploy but have 1 or more days of inactivity"
write-host $good.count "good"
write-host $notupdated.count "in the good category but have not updated to $($appname) version $($appversion)"
write-host $notinstalled.count "not installed"
write-host $failed.count "failed deploying"
write-host $other.count 'other, see $other.  Likely MDM only devices'
write-host $errors.count "errors getting device details"
write-host ($devicestodeploy.softwareinventory | where {$_.name -like $appname}).count "in devices to deploy with $appname shown in the app inventory, listed below"
write-output ($devicestodeploy | foreach { $_ | where {$_.softwareinventory.name -like $appname} | select lastUsername, deviceType, serialNumber, inactivitydays })
##end 3

#start 4
$deploycheck = Read-Host "Deploy to $($reallydodeploy.count) active devices?  Y to deploy, N to not"
if ($deploycheck -like "Y") {
$deploybody = @"
[$($($reallydodeploy) -join ",")]
"@
$deploystatus = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/refresh" -ContentType "application/json" -Headers $authheader -Body $deploybody
if ($deploystatus.status -ne 0) { $deploystatus.deviceActionMessages }
else { $deploystatus.message }
}
else { write-host $reallydodeploy.count "active devices skipped" }


$deployinactive = Read-Host "Deploy to $($inactivitydevices.count) devices with 1 or more day of inactivity?  Y to deploy, N to not"
if ($deployinactive -like "Y") {
$deploybody2 = @"
[$($($inactivitydevices) -join ",")]
"@
$deploystatus2 = Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/device/refresh" -ContentType "application/json" -Headers $authheader -Body $deploybody2
if ($deploystatus2.status -ne 0) { $deploystatus2.deviceActionMessages }
else { $deploystatus2.message }
}
else { write-host $inactivitydevices.count "inactive devices skipped" }
##end 4

Invoke-RestMethod -Method Post –URI  "https://$($xmsbaseurl)/xenmobile/api/v1/authentication/logout" -ContentType "application/json" -Headers $authheader -Body $logoutbody | Out-Null

Compare-Object $vars.name (Get-Variable -Scope Script).name | foreach { Clear-Variable $_.InputObject }