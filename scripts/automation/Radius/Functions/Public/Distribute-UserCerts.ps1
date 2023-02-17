# Import Global Config:
. "$JCScriptRoot/config.ps1"
Connect-JCOnline $JCAPIKEY -force

################################################################################
# Do not modify below
################################################################################

# Import the functions
Import-Module "$JCScriptRoot/Functions/JCRadiusCertDeployment.psm1" -DisableNameChecking -Force

# Import the users.json file and convert to PSObject
$userArray = Get-Content -Raw -Path "$JCScriptRoot/users.json" | ConvertFrom-Json -Depth 6
# Check to see if previous commands exist
$RadiusCertCommands = Get-JCCommand | Where-Object { $_.Name -like 'RadiusCert-Install*' }

if ($RadiusCertCommands.Count -ge 1) {
    Write-Host "[status] $([char]0x1b)[96mRadiusCert commands detected, please make a selection."
    Write-Host "1: Press '1' to generate new commands for ALL users. $([char]0x1b)[96mNOTE: This will remove any previously generated Radius User Certificate Commands titled 'RadiusCert-Install:*'"
    Write-Host "2: Press '2' to generate new commands for NEW RADIUS users. $([char]0x1b)[96mNOTE: This will only generate commands for users who did not have a cert previously"
    Write-Host "E: Press 'E' to exit."
    $confirmation = Read-Host "Please make a selection"
    while ($confirmation -ne 'E') {
        if ($confirmation -eq '1') {
            # Get queued commands
            $queuedCommands = Get-JCQueuedCommands
            # Clear any queued commands for old RadiusCert commands
            foreach ($command in $RadiusCertCommands) {
                if ($command._id -in $queuedCommands.command) {
                    $queuedCommandInfo = $queuedCommands | Where-Object command -EQ $command._id
                    Clear-JCQueuedCommand -workflowId $queuedCommandInfo.id
                }
            }
            Write-Host "[status] Removing $($RadiusCertCommands.Count) commands"
            # Delete previous commands
            $RadiusCertCommands | Remove-JCCommand -force | Out-Null
            # Clean up users.json array
            $userArray | ForEach-Object { $_.commandAssociations = @() }
            break
        } elseif ($confirmation -eq '2') {
            Write-Host "[status] Proceeding with execution"
            break
        }
    }

    # Break out of the scriptblock and return to main menu
    if ($confirmation -eq 'E') {
        break
    }
}

# Create commands for each user
foreach ($user in $userArray) {
    # Get certificate and zip to upload to Commands
    $userCertFiles = Get-ChildItem -path "$JCScriptRoot/UserCerts" -Filter "$($user.userName)*"
    # set crt and pfx filepaths
    $userCrt = ($userCertFiles | Where-Object { $_.Name -match "crt" }).FullName
    $userPfx = ($userCertFiles | Where-Object { $_.Name -match "pfx" }).FullName
    # define .zip name
    $userPfxZip = "$JCScriptRoot/UserCerts/$($user.userName)-client-signed.zip"

    Compress-Archive -Path $userPfx -DestinationPath $userPfxZip -CompressionLevel NoCompression -Force
    # Find OS of System
    if ($user.systemAssociations.osFamily -contains 'Mac OS X') {
        # Get the macOS system ids
        $systemIds = $user.systemAssociations | Where-Object { $_.osFamily -eq 'Mac OS X' } | Select-Object systemId

        # Check to see if previous commands exist
        $Command = Get-JCCommand -name "RadiusCert-Install:$($user.userName):MacOSX"

        if ($Command.Count -ge 1) {
            $confirmation = Write-Host "[status] RadiusCert-Install:$($user.userName):MacOSX command already exists, skipping..."
            continue
        }

        # get certInfo for command:
        $certInfo = Invoke-Expression "$opensslBinary x509 -in $($userCrt) -enddate -serial -subject -issuer -noout"
        $certHash = @{}
        $certInfo | ForEach-Object {
            $property = $_ | ConvertFrom-StringData
            $certHash += $property
        }
        # Create new Command and upload the signed pfx
        try {
            $CommandBody = @{
                Name              = "RadiusCert-Install:$($user.userName):MacOSX"
                Command           = @"
set -e
unzip -o /tmp/$($user.userName)-client-signed.zip -d /tmp
currentUser=`$(/usr/bin/stat -f%Su /dev/console)
currentUserUID=`$(id -u "`$currentUser")
currentCertSN="$($certHash.serial)"
if [[ `$currentUser ==  $($user.userName) ]]; then
    certs=`$(security find-certificate -a -c "$($user.userName)" -Z /Users/$($user.userName)/Library/Keychains/login.keychain)
    regexSHA='SHA-1 hash: ([0-9A-F]{5,40})'
    regexSN='"snbr"<blob>=0x([0-9A-F]{5,40})'
    global_rematch() {
        # Set local variables
        local s=`$1 regex=`$2
        # While string matches regex expression
        while [[ `$s =~ `$regex ]]; do
            # Echo out the match
            echo "`${BASH_REMATCH[1]}"
            # Remove the string
            s=`${s#*"`${BASH_REMATCH[1]}"}
        done
    }
    # Save results
    # Get Text Results
    textSHA=`$(global_rematch "`$certs" "`$regexSHA")
    # Set as array for SHA results
    arraySHA=(`$textSHA)
    # Get Text Results
    textSN=`$(global_rematch "`$certs" "`$regexSN")
    # Set as array for SN results
    arraySN=(`$textSN)
    # set import var
    import=true
    if [[ `${#arraySN[@]} == `${#arraySHA[@]} ]]; then
        len=`${#arraySN[@]}
        for (( i=0; i<`$len; i++ )); do
            if [[ `$currentCertSN == `${arraySN[`$i]} ]]; then
                echo "Found Cert: SN; `${arraySN[`$i]} SHA: `${arraySHA[`$i]}"
                # if cert is installed, no need to update
                import=false
            else
                echo "Deleteing Old Radius Cert:"
                echo "SN: `${arraySN[`$i]} SHA: `${arraySHA[`$i]}"
                security delete-certificate -Z "`${arraySHA[`$i]}" /Users/$($user.userName)/Library/Keychains/login.keychain
            fi
        done

    else
        echo "array length mismatch, will not delete old certs"
    fi

    if [[ `$import == true ]]; then
        /bin/launchctl asuser "`$currentUserUID" sudo -iu "`$currentUser" /usr/bin/security import /tmp/$($user.userName)-client-signed.pfx -k /Users/$($user.userName)/Library/Keychains/login.keychain -P $JCUSERCERTPASS
        if [[ `$? -eq 0 ]]; then
            echo "Import Success"
        else
            echo "import failed"
            exit 4
        fi
    else
        echo "cert already imported"
    fi
else
    echo "Current logged in user, `$currentUser, does not match expected certificate user. Please ensure $($user.userName) is signed in and retry"
    exit 4
fi

"@
                launchType        = "trigger"
                User              = "000000000000000000000000"
                trigger           = "RadiusCertInstall"
                commandType       = "mac"
                timeout           = 600
                TimeToLiveSeconds = 864000
                files             = (New-JCCommandFile -certFilePath $userPfxZip -FileName "$($user.userName)-client-signed.zip" -FileDestination "/tmp/$($user.userName)-client-signed.zip")
            }
            $NewCommand = New-JcSdkCommand @CommandBody

            # Find newly created command and add system as target
            # TODO: Condition for duplicate commands
            $Command = Get-JCCommand -name "RadiusCert-Install:$($user.userName):MacOSX"
            $systemIds | ForEach-Object { Set-JcSdkCommandAssociation -CommandId:("$($Command._id)") -Op 'add' -Type:('system') -Id:("$($_.systemId)") | Out-Null }
        } catch {
            throw $_
        }

        $CommandTable = [PSCustomObject]@{
            commandId            = $command._id
            commandName          = $command.name
            commandPreviouslyRun = $false
            commandQueued        = $false
            systems              = $systemIds
        }

        $user.commandAssociations += $CommandTable

        Write-Host "[status] Successfully created $($Command.name): User - $($user.userName); OS - Mac OS X"
    }
    if ($user.systemAssociations.osFamily -contains 'Windows') {
        # Get the Windows system ids
        $systemIds = $user.systemAssociations | Where-Object { $_.osFamily -eq 'Windows' } | Select-Object systemId

        # Check to see if previous commands exist
        $Command = Get-JCCommand -name "RadiusCert-Install:$($user.userName):Windows"

        if ($Command.Count -ge 1) {
            $confirmation = Write-Host "[status] RadiusCert-Install:$($user.userName):Windows command already exists, skipping..."
            continue
        }

        # Create new Command and upload the signed pfx
        try {
            $CommandBody = @{
                Name              = "RadiusCert-Install:$($user.userName):Windows"
                Command           = @"
`$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$PkgProvider = Get-PackageProvider
If ("Nuget" -notin `$PkgProvider.Name){
    Install-PackageProvider -Name NuGet -Force
}
`$CurrentUser = ((Get-WMIObject -ClassName Win32_ComputerSystem).Username).Split('\')[1]
if (`$CurrentUser -eq "$($user.userName)") {
    if (-not(Get-InstalledModule -Name RunAsUser -errorAction "SilentlyContinue")) {
        Write-Host "RunAsUser Module not installed, Installing..."
        Install-Module RunAsUser -Force
        Import-Module RunAsUser -Force
    } else {
        Write-Host "RunAsUser Module installed, importing into session..."
        Import-Module RunAsUser -Force
    }
    Expand-Archive -LiteralPath C:\Windows\Temp\$($user.userName)-client-signed.zip -DestinationPath C:\Windows\Temp -Force
    `$password = ConvertTo-SecureString -String $JCUSERCERTPASS -AsPlainText -Force
    `$ScriptBlock = { `$password = ConvertTo-SecureString -String "secret1234!" -AsPlainText -Force
     Import-PfxCertificate -Password `$password -FilePath "C:\Windows\Temp\$($user.userName)-client-signed.pfx" -CertStoreLocation Cert:\CurrentUser\My
}
     Write-Host "Importing Pfx Certificate for $($user.userName)"
    `$JSON = Invoke-AsCurrentUser -ScriptBlock `$ScriptBlock -CaptureOutput
    `$JSON
} else {
    Write-Host "Current logged in user, `$CurrentUser, does not match expected certificate user. Please ensure $($user.userName) is signed in and retry."
    exit 4
}
"@
                launchType        = "trigger"
                trigger           = "RadiusCertInstall"
                commandType       = "windows"
                shell             = "powershell"
                timeout           = 600
                TimeToLiveSeconds = 864000
                files             = (New-JCCommandFile -certFilePath $userPfxZip -FileName "$($user.userName)-client-signed.zip" -FileDestination "C:\Windows\Temp\$($user.userName)-client-signed.zip")
            }
            $NewCommand = New-JcSdkCommand @CommandBody

            # Find newly created command and add system as target
            $Command = Get-JCCommand -name "RadiusCert-Install:$($user.userName):Windows"
            $systemIds | ForEach-Object { Set-JcSdkCommandAssociation -CommandId:("$($Command._id)") -Op 'add' -Type:('system') -Id:("$($_.systemId)") | Out-Null }
        } catch {
            throw $_
        }

        $CommandTable = [PSCustomObject]@{
            commandId            = $command._id
            commandName          = $command.name
            commandPreviouslyRun = $false
            commandQueued        = $false
            systems              = $systemIds
        }

        $user.commandAssociations += $CommandTable
        Write-Host "[status] Successfully created $($Command.name): User - $($user.userName); OS - Windows"
    }
}

# Invoke Commands
$confirmation = Read-Host "Would you like to invoke commands? [y/n]"
$UserArray | ConvertTo-Json -Depth 6 | Out-File "$JCScriptRoot\users.json"

while ($confirmation -ne 'y') {
    if ($confirmation -eq 'n') {
        Write-Host "[status] To invoke the commands at a later time, select option '4' to monitor your User Certification Distribution"
        Write-Host "[status] Returning to main menu"
        exit
    }
}

$invokeCommands = Invoke-CommandsRetry -jsonFile "$JCScriptRoot\users.json"
Write-Host "[status] Commands Invoked"

# Set commandPreviouslyRun property to true
$userArray.commandAssociations | ForEach-Object { $_.commandPreviouslyRun = $true }

$UserArray | ConvertTo-Json -Depth 6 | Out-File "$JCScriptRoot\users.json"

Write-Host "[status] Select option '4' to monitor your User Certification Distribution"
Write-Host "[status] Returning to main menu"