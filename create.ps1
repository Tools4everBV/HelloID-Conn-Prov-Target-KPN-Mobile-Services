#################################################
# HelloID-Conn-Prov-Target-KPN-Mobile-Services-Create
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
    $outputContext.AccountReference = 'Currently not available'

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

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        # remove subscriber. from accountfield
        $correlationField = ($actionContext.CorrelationConfiguration.AccountField -split '\.')[1]
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Get one user to see retrieve total users
        $splatGetUsers = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers?from=0&to=1"
            Method  = 'GET'
            Headers = $headers
        }
        $usersTotal = (Invoke-RestMethod @splatGetUsers).total

        # Get users
        $splatGetUsers = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers?from=0&to=$($usersTotal)"
            Method  = 'GET'
            Headers = $headers
        }
        $users = (Invoke-RestMethod @splatGetUsers).result
        $correlatedAccount = $users | Where-Object { $_.$correlationField -eq $correlationValue }

        # Validate costcenter number to costcenter id in KPN-mobile-services
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
    }

    if ($null -ne $correlatedAccount) {
        $action = 'CorrelateAccount'
    } elseif ($null -eq $actionContext.Data.groupId) {
        $action = 'CostcenterValidationError'
    } else {
        $action = 'CreateAccount'
    }

    # Process
    switch ($action) {
        'CreateAccount' {
            $splatCreateSubscriber = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers"
                Method      = 'POST'
                Body        = ($actionContext.Data | ConvertTo-Json -Depth 10)
                Headers     = $headers
                ContentType = 'application/json'
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating KPN-Mobile-Services account'

                $null = Invoke-RestMethod @splatCreateSubscriber

                # Wait 5 seconds before getting user because it takes a while for the get call to return a newly created user
                Start-Sleep -Seconds 5
                # Get users to get created account
                $splatGetUsers = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers?from=0&to=$($usersTotal +1)"
                    Method  = 'GET'
                    Headers = $headers
                }
                $users = (Invoke-RestMethod @splatGetUsers).result
                $createdAccount = $users | Where-Object { $_.employeeNumber -eq $actionContext.Data.subscriber.employeeNumber }

                $outputContext.Data = $createdAccount
                $outputContext.AccountReference = $createdAccount.Id
            } else {
                Write-Information '[DryRun] Create and correlate KPN-Mobile-Services account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating KPN-Mobile-Services account'

            $outputContext.Data = $correlatedAccount
            $outputContext.AccountReference = $correlatedAccount.Id
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }

        'CostcenterValidationError' {
            throw "Could not find costcenter with costcenterNumber [$($personContext.Person.PrimaryContract.CostCenter.Code)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $action
            Message = $auditLogMessage
            IsError = $false
        })
} catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-KPN-Mobile-ServicesError -ErrorObject $ex
        $auditMessage = "Could not create or correlate KPN-Mobile-Services account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not create or correlate KPN-Mobile-Services account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}