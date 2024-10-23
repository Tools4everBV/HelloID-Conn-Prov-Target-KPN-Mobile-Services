##################################################
# HelloID-Conn-Prov-Target-KPN-Mobile-Services-Delete
# PowerShell V2
##################################################

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

    Write-Information 'Verifying if a KPN-Mobile-Services account exists'
    $splatGetUser = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)"
        Method  = 'GET'
        Headers = $headers
    }
    $correlatedAccount = (Invoke-RestMethod @splatGetUser)

    if ($null -ne $correlatedAccount) {
        $action = 'DeleteAccount'
    } else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'DeleteAccount' {
            $splatDeleteUser = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/hierarchy/subscribers/$($actionContext.References.Account)/delete"
                Method      = 'POST'
                Headers     = $headers
                Body        = ($actionContext.Data | ConvertTo-Json -Depth 10)
                ContentType = 'application/json'
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Deleting KPN-Mobile-Services account with accountReference: [$($actionContext.References.Account)]"
                $correlatedAccount = (Invoke-RestMethod @splatDeleteUser)
            } else {
                Write-Information "[DryRun] Delete KPN-Mobile-Services account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'Delete account was successful'
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "KPN-Mobile-Services account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "KPN-Mobile-Services account: [$($actionContext.References.Account)] could not be found, possibly indicating that it could be deleted"
                    IsError = $false
                })
            break
        }
    }
} catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-KPN-Mobile-ServicesError -ErrorObject $ex
        $auditMessage = "Could not delete KPN-Mobile-Services account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not delete KPN-Mobile-Services account. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}