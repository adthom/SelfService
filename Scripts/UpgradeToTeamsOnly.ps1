#this flags sets debug messages to show in the test pane
$debug=$true

Import-Module Az.Accounts
Import-Module Az.Automation
Import-Module Az.Storage
$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection"
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName
    Write-Output "Logging in to Azure..."
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
#Get configured storage account
$RGName = Get-AutomationVariable -Name ResourceGroupName
$StorageAccount = Get-AzStorageAccount -ResourceGroupName $RGName -Name "${RGName}storage"
$PendingQueue = Get-AzStorageQueue -Name "teamsonlypending" -Context $StorageAccount.Context

$BatchLimit = 5000
$UserIds = [System.Collections.Generic.HashSet[string]]::new()              # HashSet to only allow for unique names

while ($UserIds.Count -lt $BatchLimit) {
    $CurrentMessage = $PendingQueue.CloudQueue.GetMessage($null, $null, $null)
    if ($null -eq $CurrentMessage) {
        break
    }
    $UserIds.Add($CurrentMessage.AsString.ToLower()) | Out-Null
    $PendingQueue.CloudQueue.DeleteMessage($CurrentMessage, $null, $null)       # remove message from the queue
}
$UserIdArray = [string[]]::new($UserIds.Count)
$UserIds.CopyTo($UserIdArray)

Write-Output "Found $($UserIdArray.Count) users in pending queue"

$MoreExist = $PendingQueue.CloudQueue.PeekMessage($null, $null)
if ($null -ne $MoreExist) {
    if($debug){
        Write-Output "DEBUG: Found additional users in pending queue, requeuing"
    }
    $Requeue = [System.Collections.Generic.List[object]]::new()
    # re-queue all remaining messages to avoid 7 day expiration limit
    while($true) {
        $CurrentMessage = $PendingQueue.CloudQueue.GetMessage($null, $null, $null)
        if ($null -eq $CurrentMessage) {
            break
        }
        if (!$UserIds.Contains($CurrentMessage.AsString.ToLower())) {               # only requeue if user is unique
            $NewMessage = [Microsoft.Azure.Storage.Queue.CloudQueueMessage]::new($CurrentMessage.AsString, $false)
            $Requeue.Add($NewMessage) | Out-Null
        }
        $PendingQueue.CloudQueue.DeleteMessage($CurrentMessage, $null, $null)       # remove message from the queue
    }
    foreach ($Message in $Requeue) {
        $PendingQueue.CloudQueue.AddMessage($Message, $null, $null, $null, $null)
    }
}

#load credentials from automation account
$SfBTeamsAdminCredential = Get-AutomationPSCredential -Name "O365Admin"

if($debug){
    Write-Output "DEBUG: SfBAdmin credential retrieved as $($SfBTeamsAdminCredential.UserName)"
}

#Connect to Microsoft Teams Powershell. Used for new-csbatchpolicyassignmentoperation
Write-Output "Logging into Teams PowerShell..."
$TeamsConnection = Connect-MicrosoftTeams -Credential $SfBTeamsAdminCredential -ErrorAction Stop

if($debug){
    Write-Output "DEBUG: Teams connection domain name should be here: $($TeamsConnection.TenantDomain)"
}

# Assign using batch policy assignment
Write-Output "Beginning Batch Policy Assignment"

$BatchParams = @{
    PolicyType = "TeamsUpgradePolicy"
    PolicyName = "UpgradeToTeams"
    Identity = $UserIdArray
    OperationName = "Azure Automation UpgradeToTeams $(Get-Date -Format 's')"
    AdditionalParameters = @{
        MigrateMeetingsToTeams = $true
    }
}
if ($BatchParams['Identity'].Count -gt 0) {
    $BatchId = New-CsBatchPolicyAssignmentOperation @BatchParams
    if ($debug) {
        Write-Output "DEBUG: OperationName: $($BatchParams['OperationName'])"
    }
}

if ($null -ne $BatchId) {
    $RunbookParams = @{
        AutomationAccountName = "${RGName}-automation"
        Name = "WaitForBatch"
        ResourceGroupName = $RGName
        Parameters = @{
            BatchId = $BatchId
        }
    }
    if ($debug) {
        Write-Output "Batch $BatchId started, running WaitForBatch Runbook"
    }
    Start-AzAutomationRunbook @RunbookParams
}