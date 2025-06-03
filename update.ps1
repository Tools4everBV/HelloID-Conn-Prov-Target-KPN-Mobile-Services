#################################################
# HelloID-Conn-Prov-Target-KPN-Mobile-Services-Update
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-KPN-Mobile-ServicesError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            # Make sure to inspect the error result object and add only the error message as a FriendlyMessage.
            if ($errorDetailsObject.errors.count -gt 0) {
                $httpErrorObj.FriendlyMessage = ($errorDetailsObject.errors -join ', ')
            }
            elseif (-not([string]::IsNullOrEmpty($errorDetailsObject.fault.faultstring))) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.fault.faultstring
            }
            else {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.message
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    $tokenHeaders = [System.Collections.Generic.Dictionary[string, string]]::new()
    $tokenHeaders.Add('Content-Type', 'application/x-www-form-urlencoded')

    $tokenBody = @{
        grant_type    = 'client_credentials'
        client_id     = $actionContext.Configuration.ClientId
        client_secret = $actionContext.Configuration.ClientSecret
    }

    $splatGetToken = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/oauth/grip/msm/accesstoken"
        Method  = 'POST'
        Body    = $tokenBody
        Headers = $tokenHeaders
    }
    $accessToken = (Invoke-RestMethod @splatGetToken).access_token

    Write-Information 'Setting authorization header'
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add('Authorization', "Bearer $($accessToken)")

    Write-Information 'Verifying if a KPN-Mobile-Services account exists'
    $splatGetUser = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = $headers
    }
    $correlatedAccount = (Invoke-RestMethod @splatGetUser)
    $outputContext.PreviousData = $correlatedAccount

    # Always compare the account against the current account in target system
    $actionList = @()
    if ($null -ne $correlatedAccount) {

        $filteredCorrelatedAccount = $correlatedAccount | Select-Object * -ExcludeProperty path, id, location

        $filteredCorrelatedAccount.PSObject.Properties | ForEach-Object {
            if ($null -eq $_.Value) { 
                $_.Value = "" 
            }
        }

        $account = $actionContext.Data | Select-Object * -ExcludeProperty id, groupId, costCenterNumber, referenceNumber

        $account.PSObject.Properties | ForEach-Object {
            if ($null -eq $_.Value) { 
                $_.Value = "" 
            }
        }

        $splatCompareProperties = @{
            ReferenceObject  = @($filteredCorrelatedAccount.PSObject.Properties)
            DifferenceObject = @($account.PSObject.Properties)
        }

        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }

        if ($null -ne $propertiesChanged) {
            $updateAccount = $filteredCorrelatedAccount
            $updateAccount.PSObject.Properties | ForEach-Object {
                if ($account.PSObject.Properties.Name -contains $_.Name) {
                    $_.Value = $account.($_.Name)
                }
                elseif ([string]::IsNullOrEmpty($_.Value)) {
                    $updateAccount.PSObject.Properties.Remove("$($_.Name)")
                }
            }
        }

        $splatGetDebtors = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/children"
            Method  = 'GET'
            Headers = $headers
        }
        $debtors = (Invoke-RestMethod @splatGetDebtors).result

        $costCenters = [System.Collections.Generic.list[object]]::new()
        foreach ($debtor in $debtors) {
            $splatTotalCostCenters = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/children?id=$($debtor.id)&from=0&to=1"
                Method  = 'GET'
                Headers = $headers
            }
            $totalCostCenters = (Invoke-RestMethod @splatTotalCostCenters).total

            $splatCostCenters = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/children?id=$($debtor.id)&from=0&to=$($totalCostCenters)"
                Method  = 'GET'
                Headers = $headers
            }
            $costCenterResult = ((Invoke-RestMethod @splatCostCenters).result | Where-Object { $_.type -eq 'COST_CENTER' })

            foreach ($costCenter in $costCenterResult) {
                $costCenterObject = [pscustomobject]@{
                    id               = $costCenter.id
                    name             = $costCenter.name
                    costcenterNumber = $costCenter.costCenterNumber
                }
                $costCenters += $costCenterObject
            }
        }

        $actionContext.Data | Add-Member -NotePropertyName groupId -NotePropertyValue $null -Force
        $actionContext.Data.groupId = ($costCenters | Where-Object { $_.costcenterNumber -eq $actionContext.Data.costCenterNumber }).id
        $targetCostCenterId = ($correlatedAccount.path | Where-Object { $_.type -eq 'COST_CENTER' }).id
        $previousDataCostCenter = ($costCenters | Where-Object { $_.id -eq $targetCostCenterId }).costcenterNumber

        # Returning data to HelloID
        $outputContext.PreviousData | Add-Member -MemberType NoteProperty -Name 'costcenterNumber' -Value $previousDataCostCenter
        $outputContext.PreviousData | Add-Member -MemberType NoteProperty -Name 'groupId' -Value $targetCostCenterId
        $outputContext.Data.groupId = $actionContext.Data.groupId
        $outputContext.Data.id = $correlatedAccount.id

        if ($null -eq $actionContext.Data.groupId) {
            $actionList += 'CostcenterValidationError'
        }
        else {
            if ($actionContext.Data.groupId -ne $targetCostCenterId) {
                $actionList += 'UpdateCostCenter'
            }
            if ($propertiesChanged) {
                $actionList += 'UpdateAccount'
            }
            elseif ($actionContext.Data.groupId -eq $targetCostCenterId) {
                $actionList += 'NoChanges'
            }
        }
    }
    else {
        $actionList += 'NotFound'
    }

    Write-Information "Calculated actions $($actionList -join ', ')"

    # Process
    foreach ($action in $actionList) {
        switch ($action) {
            'UpdateAccount' {
                Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"
                
                $splatUpdateSubscriber = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)"
                    Method      = 'PUT'
                    Body        = ([PSCustomObject]@{
                            referenceNumber = $actionContext.Data.referenceNumber
                            subscriber      = $updateAccount
                        } | ConvertTo-Json -Depth 10)
                    Headers     = $headers
                    ContentType = 'application/json'
                }

                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating KPN-Mobile-Services account with accountReference: [$($actionContext.References.Account)]"
                    $null = Invoke-RestMethod @splatUpdateSubscriber
                }
                else {
                    Write-Information "[DryRun] Update KPN-Mobile-Services account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                        IsError = $false
                    })
                break
            }

            'UpdateCostCenter' {
                Write-Information 'Update subscriber costcenter'

                $moveSubscriberBody = @{
                    destinationGroupId = $actionContext.Data.groupId
                }

                $splatUpdateSubscriberCostCenter = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)/move"
                    Method      = 'POST'
                    Body        = ($moveSubscriberBody | ConvertTo-Json -Depth 10)
                    Headers     = $headers
                    ContentType = 'application/json'
                }

                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Move account from costcenter [$($targetCostCenterId)] to costcenter [$($actionContext.Data.groupId)]"
                    $null = Invoke-RestMethod @splatUpdateSubscriberCostCenter
                }
                else {
                    Write-Information "[DryRun] Move account from costcenter [$($targetCostCenterId)] to costcenter [$($actionContext.Data.groupId)], will be executed during enforcement"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "Move account was successful, account moved from costcenter [$($targetCostCenterId)] to costcenter [$($actionContext.Data.groupId)]"
                        IsError = $false
                    })
                break
            }

            'NoChanges' {
                Write-Information "No changes to KPN-Mobile-Services account with accountReference: [$($actionContext.References.Account)]"
                $outputContext.Success = $true
                $outputContext.PreviousData = $outputContext.Data
                break
            }

            'CostcenterValidationError' {
                throw "Could not find costcenter with costcenterNumber [$($actionContext.Data.costCenterNumber)]"
                break
            }

            'NotFound' {
                Write-Information "KPN-Mobile-Services account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                $outputContext.Success = $false
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = "KPN-Mobile-Services account with accountReference: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                        IsError = $true
                    })
                break
            }
        }
    }
}
catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-KPN-Mobile-ServicesError -ErrorObject $ex
        $auditMessage = "Could not update KPN-Mobile-Services account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not update KPN-Mobile-Services account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}