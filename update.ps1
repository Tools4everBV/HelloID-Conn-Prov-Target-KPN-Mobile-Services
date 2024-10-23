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
        } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
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
            } elseif (-not([string]::IsNullOrEmpty($errorDetailsObject.fault.faultstring))) {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.fault.faultstring
            } else {
                $httpErrorObj.FriendlyMessage = $errorDetailsObject.message
            }
        } catch {
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
    $headers.Add('content', "Bearer $($accessToken)")

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
        $splatCompareProperties = @{
            ReferenceObject  = @($correlatedAccount.PSObject.Properties)
            DifferenceObject = @($actionContext.Data.subscriber.PSObject.Properties)
        }
        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' }

        $splatGetDebtors = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/children"
            Method  = 'GET'
            Headers = $headers
        }
        $debtors = (Invoke-RestMethod @splatGetDebtors).result

        $costCenters = New-Object System.Collections.ArrayList
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

        $actionContext.Data.groupId = ($costCenters | Where-Object { $_.costcenterNumber -eq $personContext.Person.PrimaryContract.CostCenter.Code } | Select-Object -ExpandProperty id)
        $targetCostCenterId = ($correlatedAccount.path | Where-Object { $_.type -eq 'COST_CENTER' } | Select-Object -ExpandProperty id)

        if ($actionContext.Data.groupId -ne $targetCostCenterId) {
            $actionList += 'UpdateCostCenter'
        }
        if ($propertiesChanged) {
            $actionList += 'UpdateAccount'
        } elseif ($actionContext.Data.groupId -eq $targetCostCenterId) {
            $actionList += 'NoChanges'
        }
    } else {
        $actionList += 'NotFound'
    }

    # Process
    foreach ($action in $actionList) {
        switch ($action) {
            'UpdateAccount' {
                Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"

                $splatUpdateSubscriber = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)"
                    Method      = 'PUT'
                    Body        = ($actionContext.Data | Select-Object * -ExcludeProperty groupId | ConvertTo-Json -Depth 10)
                    Headers     = $headers
                    ContentType = 'application/json'
                }

                if (-not($actionContext.DryRun -eq $true)) {
                    Write-Information "Updating KPN-Mobile-Services account with accountReference: [$($actionContext.References.Account)]"
                    $null = Invoke-RestMethod @splatUpdateSubscriber
                } else {
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
                } else {
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
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = 'No changes will be made to the account during enforcement'
                        IsError = $false
                    })
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
} catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-KPN-Mobile-ServicesError -ErrorObject $ex
        $auditMessage = "Could not update KPN-Mobile-Services account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not update KPN-Mobile-Services account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
