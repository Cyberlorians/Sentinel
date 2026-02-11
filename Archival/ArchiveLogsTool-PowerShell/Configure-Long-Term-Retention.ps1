<#
    .SYNOPSIS
        Configure Log Analytics table plans (Basic/Analytics) and retention.

    .DESCRIPTION
        1. Connects to Commercial Azure or GCCH (Azure Government)
        2. Lists tables in your Log Analytics workspace
        3. Lets you switch tables between Basic and Analytics plans
        4. Lets you set archive retention days for Analytics tables

    .PARAMETER TenantId
        Your Azure Tenant ID (required)

    .EXAMPLE
        .\Configure-Long-Term-Retention-v2.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

    .NOTES
        Based on Azure Sentinel Archive Log Tool by Sreedhar Ande
        Simplified with GCCH fix applied
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Enter your Azure Tenant Id")]
    [string]$TenantID
)

#region Setup

$TimeStamp = Get-Date -Format yyyyMMdd_HHmmss
$LogFileName = "Sentinel_LTR_$TimeStamp.csv"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Information','Warning','Error')]
        [string]$Severity = 'Information'
    )
    switch ($Severity) {
        "Information" { Write-Host $Message -ForegroundColor Green }
        "Warning"     { Write-Host $Message -ForegroundColor Yellow }
        "Error"       { Write-Host $Message -ForegroundColor Red }
    }
    [PSCustomObject]@{
        Time     = (Get-Date -f g)
        Message  = $Message
        Severity = $Severity
    } | Export-Csv -Path "$PSScriptRoot\$LogFileName" -Append -NoTypeInformation -Force
}

# Check PowerShell version
if ($host.Version.Major -lt 5) {
    Write-Log "PowerShell 5 or higher is required." -Severity Error
    exit
}

# Install/Import required modules
$MinAzAccountsVersion = [Version]"2.12.0"
foreach ($mod in @('Az.Accounts','Az.OperationalInsights')) {
    $installed = Get-Module -ListAvailable -Name $mod | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installed) {
        Write-Log "Installing $mod..." -Severity Warning
        Install-Module -Name $mod -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    elseif ($mod -eq 'Az.Accounts' -and $installed.Version -lt $MinAzAccountsVersion) {
        Write-Log "Az.Accounts $($installed.Version) is too old. Minimum required: $MinAzAccountsVersion. Updating..." -Severity Warning
        Update-Module -Name $mod -Force -ErrorAction SilentlyContinue
        if (-not $?) {
            Install-Module -Name $mod -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
    }
    Import-Module -Name $mod -Force
}

# Confirm Az.Accounts version
$loadedAz = Get-Module Az.Accounts
Write-Log "Az.Accounts version: $($loadedAz.Version)" -Severity Information
if ($loadedAz.Version -lt $MinAzAccountsVersion) {
    Write-Log "Az.Accounts $($loadedAz.Version) is below minimum $MinAzAccountsVersion. Please update and retry." -Severity Error
    exit
}

#endregion

#region Connect to Azure

# Step 1: Pick your cloud
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Select your Azure Environment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  1) Commercial  (login.microsoftonline.com)" -ForegroundColor White
Write-Host "  2) GCCH / Gov   (login.microsoftonline.us)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

do {
    $envChoice = Read-Host "Enter 1 or 2"
} until ($envChoice -in @('1','2'))

if ($envChoice -eq '2') {
    $AzEnvironment = "AzureUSGovernment"
    $APIEndpoint   = "management.usgovcloudapi.net"
    Write-Log "Environment: GCCH / Azure Government" -Severity Information
} else {
    $AzEnvironment = "AzureCloud"
    $APIEndpoint   = "management.azure.com"
    Write-Log "Environment: Commercial Azure" -Severity Information
}

# Clear old sessions
Write-Log "Clearing existing Azure connections..." -Severity Information
$null = Disconnect-AzAccount -ErrorAction SilentlyContinue
Get-AzContext -ListAvailable | ForEach-Object { $_ | Remove-AzContext -Force -ErrorAction SilentlyContinue | Out-Null }

# Login with correct environment
try {
    Write-Log "Connecting to $AzEnvironment..." -Severity Information
    Connect-AzAccount -Tenant $TenantID -Environment $AzEnvironment -UseDeviceAuthentication -Force -ErrorAction Stop
}
catch {
    Write-Log "Failed to connect: $_" -Severity Error
    exit
}

#endregion

#region Select Subscription and Workspace

# Pick subscription
$Subscriptions = Get-AzSubscription -TenantId $TenantID | Where-Object { $_.State -eq 'Enabled' } |
    Out-GridView -Title "Select Subscription" -PassThru

if (-not $Subscriptions) {
    Write-Log "No subscription selected. Exiting." -Severity Error
    exit
}

# Get access token for REST API calls
# Newer Az.Accounts returns SecureString, so we convert to plain text
$tokenObj = Get-AzAccessToken
$AzureAccessToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
    [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
    )
} else {
    $tokenObj.Token
}
Write-Log "Token acquired successfully" -Severity Information
$LaAPIHeaders = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer $AzureAccessToken"
}

foreach ($Sub in $Subscriptions) {
    $null = Set-AzContext -Subscription $Sub.Id
    $SubscriptionId = $Sub.Id
    Write-Log "Working in subscription: $($Sub.Name)" -Severity Information

    # Pick workspace
    $Workspaces = Get-AzOperationalInsightsWorkspace |
        Where-Object { $_.ProvisioningState -eq "Succeeded" } |
        Select-Object Name, ResourceGroupName, Location |
        Out-GridView -Title "Select Log Analytics Workspace" -PassThru

    if (-not $Workspaces) {
        Write-Log "No workspace selected. Skipping." -Severity Warning
        continue
    }

    foreach ($LAW in $Workspaces) {
        $LogAnalyticsWorkspaceName = $LAW.Name
        $LogAnalyticsResourceGroup = $LAW.ResourceGroupName
        Write-Log "Workspace: $LogAnalyticsWorkspaceName" -Severity Information

        #region Get All Tables
        $TablesUri = "https://$APIEndpoint/subscriptions/$SubscriptionId/resourcegroups/$LogAnalyticsResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$LogAnalyticsWorkspaceName/tables?api-version=2021-12-01-preview"

        try {
            $TablesResult = Invoke-RestMethod -Uri $TablesUri -Method GET -Headers $LaAPIHeaders
        }
        catch {
            Write-Log "Failed to get tables: $_" -Severity Error
            continue
        }

        $AllTables = @()
        foreach ($t in $TablesResult.value) {
            if ($t.name -notmatch '_RST|_EXT') {
                $AllTables += [PSCustomObject]@{
                    TableName          = $t.name.Trim()
                    IngestionPlan      = $t.properties.plan
                    RetentionInWorkspace = $t.properties.retentionInDays
                    RetentionInArchive   = $t.properties.archiveRetentionInDays
                    TotalLogRetention    = $t.properties.totalRetentionInDays
                }
            }
        }

        if ($AllTables.Count -eq 0) {
            Write-Log "No tables found." -Severity Warning
            continue
        }
        #endregion

        #region Choose Plan and Tables
        do {
            Write-Host ""
            Write-Host "What do you want to do?" -ForegroundColor Cyan
            Write-Host "  1) Set tables to Analytics plan (+ set retention)"
            Write-Host "  2) Set tables to Basic plan"
            Write-Host "  3) Done with this workspace"
            Write-Host ""
            $planChoice = Read-Host "Enter 1, 2, or 3"

            if ($planChoice -eq '3') { break }

            if ($planChoice -eq '1') {
                $Plan = "Analytics"
                $SelectedTables = $AllTables |
                    Where-Object { $_.TableName -notmatch '(AzureActivity|Usage)' } |
                    Sort-Object TableName |
                    Out-GridView -Title "Select tables to set to ANALYTICS (Ctrl+Click for multi-select)" -PassThru
            }
            elseif ($planChoice -eq '2') {
                $Plan = "Basic"
                $SelectedTables = $AllTables |
                    Where-Object { $_.TableName -match '(ContainerLog|ContainerLogV2|ContainerInsights|AppTraces)' } |
                    Sort-Object TableName |
                    Out-GridView -Title "Select tables to set to BASIC (Ctrl+Click for multi-select)" -PassThru
            }
            else {
                Write-Host "Invalid choice." -ForegroundColor Red
                continue
            }

            if (-not $SelectedTables) {
                Write-Log "No tables selected." -Severity Warning
                continue
            }

            # Set the plan on each table
            $UpdatedTables = @()
            foreach ($tbl in $SelectedTables) {
                $TableUri = "https://$APIEndpoint/subscriptions/$SubscriptionId/resourcegroups/$LogAnalyticsResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$LogAnalyticsWorkspaceName/tables/$($tbl.TableName)?api-version=2021-12-01-preview"

                $Body = @{ properties = @{ plan = $Plan } } | ConvertTo-Json
                try {
                    $result = Invoke-RestMethod -Uri $TableUri -Method PUT -Headers $LaAPIHeaders -Body $Body
                    Write-Log "Set $($tbl.TableName) to $Plan" -Severity Information
                    $UpdatedTables += [PSCustomObject]@{
                        TableName          = $result.name
                        IngestionPlan      = $result.properties.plan
                        RetentionInWorkspace = $result.properties.retentionInDays
                        RetentionInArchive   = $result.properties.archiveRetentionInDays
                        TotalLogRetention    = $result.properties.totalRetentionInDays
                    }
                }
                catch {
                    Write-Log "Failed to update $($tbl.TableName): $_" -Severity Error
                }
            }

            # If Analytics, ask for retention days
            if ($Plan -eq "Analytics" -and $UpdatedTables.Count -gt 0) {
                Write-Host ""
                Write-Host "Set total retention (interactive + archive) in days." -ForegroundColor Cyan
                Write-Host "Allowed: 4-730, or full years: 1095, 1460, 1826, 2191, 2556, 2922, 3288, 3653, 4018, 4383" -ForegroundColor Yellow

                do {
                    $retDays = Read-Host "Enter total retention days"
                    $retInt = [int]$retDays
                    $valid = ($retInt -ge 4 -and $retInt -le 730) -or $retInt -in @(1095,1460,1826,2191,2556,2922,3288,3653,4018,4383)
                    if (-not $valid) { Write-Host "Invalid value. Try again." -ForegroundColor Red }
                } until ($valid)

                $FinalResults = @()
                foreach ($tbl in $UpdatedTables) {
                    $TableUri = "https://$APIEndpoint/subscriptions/$SubscriptionId/resourcegroups/$LogAnalyticsResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$LogAnalyticsWorkspaceName/tables/$($tbl.TableName)?api-version=2021-12-01-preview"

                    $Body = @{ properties = @{ totalRetentionInDays = $retInt } } | ConvertTo-Json
                    try {
                        $result = Invoke-RestMethod -Uri $TableUri -Method PUT -Headers $LaAPIHeaders -Body $Body
                        Write-Log "Set $($tbl.TableName) retention to $retInt days" -Severity Information
                        $FinalResults += [PSCustomObject]@{
                            TableName            = $result.name
                            IngestionPlan        = $result.properties.plan
                            RetentionInWorkspace = $result.properties.retentionInDays
                            RetentionInArchive   = $result.properties.archiveRetentionInDays
                            TotalLogRetention    = $result.properties.totalRetentionInDays
                        }
                    }
                    catch {
                        Write-Log "Failed to set retention on $($tbl.TableName): $_" -Severity Error
                    }
                }
                $UpdatedTables = $FinalResults
            }

            # Show results
            if ($UpdatedTables.Count -gt 0) {
                Write-Host ""
                Write-Host "=== Final Table Configuration ===" -ForegroundColor Cyan
                $UpdatedTables | Format-Table -AutoSize
            }

        } while ($true)
        #endregion
    }
}

Write-Log "Done! Log file: $PSScriptRoot\$LogFileName" -Severity Information
#endregion
