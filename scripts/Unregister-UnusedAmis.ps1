[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $Environment,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $Pod,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $Region,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('WindowsServices', 'Calculation', 'Configuration')]
    [String]
    $Usage,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $SharedServicesExternalId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $SharedAccountRoleArn,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $AssumeRoleArn,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [String]
    $CurrentAMIId,

    [Parameter(Mandatory = $false)]
    [Switch]
    $WhatIf
)

$ErrorActionPreference = 'Stop'


if (-not (Get-PackageSource -Name 'PSGallery' -ErrorAction SilentlyContinue)) {
    Register-PackageSource -Name 'PSGallery' -Location 'https://www.powershellgallery.com/api/v2' -ProviderName 'NuGet' -Trusted
}

$modules = @('AWS.Tools.Common', 'AWS.Tools.S3', 'AWS.Tools.SecurityToken', 'AWS.Tools.EC2')
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Install-Module -Name $module -Scope CurrentUser -Force
    }
    else {
        Write-Output "Module $module is already installed."
    }
    Import-Module -Name $module -Force
}

Get-InstalledModule -Name AWS.Tools.* | Select-Object Name, Version | Sort-Object Name | Format-Table -AutoSize

Write-Output "Pod: $Pod"
Write-Output "Environment: $Environment"
Write-Output "Region: $Region"
Write-Output "Usage: $Usage"
Write-Output "SharedAccountRoleArn: $SharedAccountRoleArn"
Write-Output "SharedServicesExternalId: $SharedServicesExternalId"
Write-Output "AssumeRoleArn: $AssumeRoleArn"
Write-Output "CurrentAMIId: $CurrentAMIId"

$remainingAMIs = @()
Write-Output "Set Remaining AMIs: $remainingAMIs"

$ssRole = Use-STSRole -RoleArn $SharedAccountRoleArn -RoleSessionName "Cleanup-Unregistered-AMIs" -Region $Region
Write-Output "ssRole: $ssRole"

$role = Use-STSRole -RoleArn "$AssumeRoleArn" -RoleSessionName "Cleanup-Unregistered-AMIs" -Region $Region
Write-Output "role: $role"

#Debugging Environment
Write-Output "Environment structure: $(ConvertTo-Json $environment -Depth 5)"
Write-Output "Pod: $Pod"

$ssAccountID = $SharedAccountRoleArn.Split(":")[4]
Write-Output "Shared Account ID: $ssAccountID"

Write-Output ("Cleaning up unregistered AMIs. Pod Id: $Pod. Region: $Region.")

$amiTagsFilter = @(
    @{ Name = "tag:OSeriesPodId"; Values = $Pod };
    @{ Name = "tag:Environment"; Values = $Environment };
    @{ Name = "tag:Source_Code"; Values = "vcd-immutable-oseries" };
    @{ Name = "tag:OSeriesUsage"; Values = $Usage };
)

$amis = Get-EC2Image -Owner $ssAccountID -Filter $amiTagsFilter -Region $Region -Credential $ssRole.Credentials
$amis = $amis | Where-Object { $_.CreationDate -ne $null } | Sort-Object { $_.CreationDate }

Write-Output "AMIs found: $($amis.Count) AMIs"
#want $amistoleave to be 5
$amisToLeave = 5
Write-Output "AMIs to leave: $amisToLeave"
$amisProcessed = 0
Write-Output "AMIs to process: $amisProcessed"
$eligibleForDeregistration = $amis.Count - $amisToLeave
Write-Output "AMIs eligible for deregistration: $eligibleForDeregistration"

$amis | ForEach-Object {
    $ami = $_
    $imageId = $ami.ImageId
    $imageName = $ami.Name

    Write-Output "`nInspecting AMI for possible DEREGISTRATION"
    Write-Output "AMI ID: $imageId"
    Write-Output "AMI Name: $imageName"

    $deploymentStatus = $ami.Tags | Where-Object { $_.Key -eq 'DeploymentStatus' } | Select-Object -ExpandProperty Value

    if ($deploymentStatus -eq 'Pending' -or $deploymentStatus -eq 'InUse') {
        Write-Output "Skipping AMI $imageId ($imageName) as it is marked for deployment or currently in use."
        Write-Output "This is where SKIPPING AMI imagename should output"
        continue
    }
    else {
        $amiForThisBuild = $ami.Tags | Where-Object { $_.Key -EQ 'BuildNumber' -AND $_.Value -EQ $BuildNumber } | Select-Object -First 1
        Write-Output "AMI for this build: $amiForThisBuild"

        if ($amiForThisBuild -eq $CurrentAMIId) {
            Write-Output "NO-OP, Found the AMI created by this deployment."
        }
        else {
            $amisProcessed++
            if ($amisProcessed -le $eligibleForDeregistration) {
                Write-Output "NO-OP, due to limit of required backup AMI's..."

                $launchTemplateFilter = @(
                    @{ Name = "image-id"; Values = $imageId };
                )

                $launchTemplates = Get-EC2TemplateVersion `
                    -Region $Region `
                    -Credential $role.Credentials `
                    -Filter $launchTemplateFilter `
                    -Version '$Latest'

                if ($launchTemplates) {
                    $templateNames = $launchTemplates |  Select-Object -Property LaunchTemplateName -ExpandProperty LaunchTemplateName
                    $templateNameString = $templateNames -JOIN ','
                    Write-Output "Template Names: $templateNames"
                    Write-Output "NO-OP, AMI IS IN USE."
                    Write-Output "Launch Template Names: $templateNameString."
                }
                else {
                    if ($deploymentStatus -ne 'InUse' -and $deploymentStatus -ne 'pending' -and $imageId -ne $CurrentAMIId -and -not $WhatIf) {
                        #Need a way to lit all AMI's that are eligible for deregistration
                        Write-Output "Eligible for deregistration: AMI ID: $imageId, AMI Name: $imageName"
                        Write-Output "Unregister-EC2Image -ImageId $imageId -Region $Region -Credential $($ssRole.Credentials)"
                        $DeregisteredAMIs = Unregister-EC2Image -ImageId $imageId -Region $Region -Credential $ssRole.Credentials
                        Write-Output "AMI $imageId has been deregistered."
                        Write-Output "List of AMI's that have been deregistered: $DeregisteredAMIs"
                        $remainingAMIs = Get-EC2Image -Owner $ssAccountID -Filter $amiTagsFilter -Region $Region -Credential $ssRole.Credentials | Sort-Object -Property CreationDate
                        Write-Output "AMIs found: $($remainingAMIs.Count)"
                    }
                    else {
                        Write-Output "Skipping deregistration due to current deployment status or WhatIf flag."
                    }
                }
            }
            else {
                Write-Output "This AMI is among the last $amisToLeave and will not be deregistered."
            }
        }
    }
}
Write-Output ""
if ($remainingAMIs.Count -gt 5) {
    Write-Output "There are greater than 5 AMI's remaining."
    Write-Output "There are $($remainingAMIs.Count) AMIs remaining."
}
else {
    Write-Output "All but $($remainingAMIs.Count) AMIs have been deregistered."
}
