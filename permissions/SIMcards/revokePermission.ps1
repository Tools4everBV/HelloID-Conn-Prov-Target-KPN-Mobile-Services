#################################################################
# HelloID-Conn-Prov-Target-KPN-RevokePermission-SIM
# PowerShell V2
#################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#Gebruik de 'en' taal variant

#Let op: Revoke script moet alle producten intrekken die op het template in de grant worden gezet. In dit geval alleen Smartphone subscription
$KPNProductToOrder = "Smartphone Subscription"

#region functions
function Resolve-KPN-GripError {
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

# Begin
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


    Write-Information "Verifying if a KPN account exists and if user has product: $KPNProductToOrder"

    # Get user
    $splatGetUser = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = $headers
    }

    $user = (Invoke-RestMethod @splatGetUser)
    
   
    if ($null -eq $user) {
        $action = 'NotFound'
    }
    else {
        #Check if user has product
        $KPNProduct = $null

        $splatGetContracts = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)/contracts"
            Method  = 'GET'
            Headers = $headers
        }
    
        $Contracts = (Invoke-RestMethod @splatGetContracts).result

        foreach ($Contract in $Contracts) {
            if ($Contract.Product.en -eq $KPNProductToOrder) {
                $KPNProduct = $Contract
            }
        }
        
    }

    if ($KPNProduct -ne $null) {
        $action = 'RevokePermission'
    }
    else {
        $action = 'SkipProcessing'
    }

    # Process
    switch ($action) {
        'RevokePermission' {

            # Make sure to test with special characters and if needed; add utf8 encoding.
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Revoking KPN product: $KPNProductToOrder. Product will be blocked, not terminated."
                
                ##Block the SIM card!
                $Date = (Get-Date).ToString('ddMMyyyy')

                $BlockBody = @{
                    contractId      = $($KPNProduct.id)
                    referenceNumber = "HelloID-$Date"
                } | ConvertTo-Json -Depth 5

                $splatBlockProduct = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/order/blocksim"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $BlockBody
                } 
    
                $BlockProduct = (Invoke-RestMethod @splatBlockProduct)

            }
            else {
                Write-Information "[DryRun] Revoke KPN permission: [$($actionContext.References.Permission.DisplayName)] - [$($actionContext.References.Permission.Reference)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Revoke permission [$($actionContext.References.Permission.DisplayName)] was successful"
                    IsError = $false
                })
        }

        'NotFound' {
            Write-Information "KPN account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "KPN account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                    IsError = $true
                })
            break
        }

        'SkipProcessing' {
            Write-Information "KPN account: [$($actionContext.References.Account)] does not have: $KPNProductToOrder, revoke process skipped"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "KPN account: [$($actionContext.References.Account)] does not have: $KPNProductToOrder, revoke process skipped"
                    IsError = $false
                })
            break
        }
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-KPN-GripError -ErrorObject $ex
        $auditMessage = "Could not create or correlate KPN-Grip account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not create or correlate KPN-Grip account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}