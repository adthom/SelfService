param (
    [Parameter(Mandatory = $true)]
    [string]
    $BatchId,

    [int] $SleepMinutes = 5
)

Import-Module Az.Accounts
Import-Module Az.Automation
Import-Module Az.Storage

$RGName = Get-AutomationVariable -Name ResourceGroupName
$Prefix = Get-AutomationVariable -Name ResourcePrefix
$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection"
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName
    Write-Output "Logging into Azure..."
    Connect-AzAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint | Out-Null
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

#load credentials from automation account
$SfBTeamsAdminCredential = Get-AutomationPSCredential -Name "O365Admin"
#Connect to Microsoft Teams Powershell. Used for new-csbatchpolicyassignmentoperation
Write-Output "Logging into Teams PowerShell..."
$TeamsConnection = Connect-MicrosoftTeams -Credential $SfBTeamsAdminCredential -ErrorAction Stop

$BatchResult = Get-CsBatchPolicyAssignmentOperation -Identity $BatchId -ErrorAction SilentlyContinue

if ($null -ne $BatchResult) {
    Write-Output "BatchId: $($BatchResult.OperationId)"
    Write-Output "OperationName: $($BatchResult.OperationName)"
    Write-Output "Completed: $($BatchResult.CompletedCount)"
    Write-Output "InProgress: $($BatchResult.InProgressCount)"
    Write-Output "Pending: $($BatchResult.NotStartedCount)"
}

if ($null -eq $BatchResult -or $BatchResult.OverallStatus -eq "Completed") {
    #Get configured storage account
    $StorageAccount = Get-AzStorageAccount -ResourceGroupName $RGName -Name "${Prefix}storage"
    $CompletedQueue = Get-AzStorageQueue -Name "teamsonlycompleted" -Context $StorageAccount.Context

    #add logging here
    foreach ($UserState in $BatchResult.UserState) {
        $User = $UserState.Id
        if ($UserState.Result -eq "Success") {
            # log success
            # alert user
        } else {
            # log failure
            # alert admin
            # alert user
        }
        # add completed run to queue, regardless of success
        $ResultJson = $UserState | ConvertTo-Json -Compress
        $NoExpire = [TimeSpan]::new(0,0,-1)     # set to -1 seconds to make TTL infinite for completed queue
        $Message = [Microsoft.Azure.Storage.Queue.CloudQueueMessage]::new($ResultJson, $false)
        $CompletedQueue.CloudQueue.AddMessage($Message, $NoExpire, $null, $null, $null)
    }
} else {
    Write-Output "Batch $BatchId still running, sleeping $SleepMinutes minutes..."
    Start-Sleep -Seconds ($SleepMinutes * 60)                                                   # Wait between checks for status

    # start another cycle
    $RunbookParams = @{
        AutomationAccountName = "${Prefix}-automation"
        Name = "WaitForBatch"
        ResourceGroupName = $RGName
        Parameters = @{
            BatchId = $BatchId
        }
    }
    Start-AzAutomationRunbook @RunbookParams
}