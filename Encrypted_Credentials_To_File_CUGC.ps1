## Run powershell on the system that will run the scheduled task as the user the task will run as.  This will allow the content of the output file to be decrypted only by that user on that system.

## Save encrypted pw to file
$cpath = "\\server\share\encrpytedpw.txt"
$password = 'P@$$W3RD'
$secureStringPwd = $password | ConvertTo-SecureString -AsPlainText -Force 
$secureStringText = $secureStringPwd | ConvertFrom-SecureString
if ((Test-Path -Path $path) -eq $true) { Remove-Item $path }
Set-Content $path $secureStringText

## In a script, this is how you consume the password.
$cpath = "\\server\share\encrpytedpw.txt"
$username = "XMSUserName"
$pwdTxt = Get-Content $path
$securePwd = $pwdTxt | ConvertTo-SecureString 
$creds = New-Object System.Management.Automation.PSCredential -ArgumentList $username, $securePwd
