################################################################
# HelloID-Conn-Prov-Target-KPN-GrantPermission-Product 
# PowerShell V2
################################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions

## Contact.Business.Email is required
if($personContext.Person.Contact.Business.Email -eq $null){
    write-error "Email is needed for the confirmation email, fill this attribute in the source."
}

#Gebruik de 'en' taal variant
$KPNProductToOrder = "Smartphone Subscription"
$KPNCategory = "MOBILE"
$KPNTemplate = "Smartphone EU - Unlimited abonnement"
$eSimConfirmationCode = "0000"

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

    if ([string]::IsNullOrEmpty($($personContext.Person.Contact.Business.Email))) {
        throw 'Person has no e-mail address which is required for a SIM'
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

    Write-Information "Verifying if a KPN account exists and if user already has product: $KPNProductToOrder"

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

    if ($KPNProduct.id -ne "") {
        $action = 'SkipProcessing'
    }
    else {
        $action = 'GrantPermission'
    }

    #$action = 'GrantPermission'

    # Process
    switch ($action) {
        'GrantPermission' {
            # Make sure to test with special characters and if needed; add utf8 encoding.
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Granting KPN permission: [$($actionContext.References.Permission.DisplayName)] - [$($actionContext.References.Permission.Reference)]"
                
                # Modify Basket and iniate session
                $Headers.Add('Content-Type', 'application/json')

                $Basketbody = @{
                    accountGroupId = $($actionContext.References.Account)
                } | ConvertTo-Json -Depth 5

                $splatSetBasket = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $Basketbody
                } 
    
                $Basket = (Invoke-RestMethod @splatSetBasket)

                <### Find product to add to basket -- Dit moet netter met een filter op de getproducts, maar het lukte me niet: https://app.swaggerhub.com/apis-docs/kpn/MobileServicesManagement-KPN/v11#/rest-contracting-controller/getMainProductsUsingGET
                #$filter = [System.Web.HttpUtility]::UrlEncode('PRODUCT_NAME:Smartphone Subscription')
                
                $splatGetProducts = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket/main-products?sessionId=$($Basket.sessionId)&category=$KPNCategory"
                    Method  = 'GET'
                    Headers = $headers
                    
                }
            
                $Products = (Invoke-RestMethod @splatGetProducts).result

                foreach ($Product in $Products) {
                    if ($Product.name.en -eq $KPNProductToOrder) {
                        $KPNSKU = $Product
                    }
                } #>

                <### Add product to Basket
                $BasketBody = @{
                    productActions = @(
                        @{
                            productId = "$($KPNSKU.id)"
                            amount    = 1
                            type      = "PUT"
                        }
                    )
                } | ConvertTo-Json -Depth 5

                $splatUpdateBasket = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket?sessionId=$($Basket.sessionId)"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $Basketbody
                } 
    
                $Basket = (Invoke-RestMethod @splatUpdateBasket) #>

                #Template aanroepen en toevoegen
                $splatBasketTemplates = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket/templates?sessionId=$($Basket.sessionId)&mainProductCategory=$KPNCategory"
                    Method  = 'get'
                    Headers = $headers
                    
                }
                
                $BasketTemplates = (Invoke-RestMethod @splatBasketTemplates).result   
                
                foreach ($Template in $BasketTemplates) {
                    if ($Template.name -eq $KPNTemplate) {
                        $TemplateToUse = $Template
                    }
                }

                # Add Template to Basket
                $BasketBody = @{
                    templateId = $($TemplateToUse.id)
                } | ConvertTo-Json -Depth 5

                $splatUpdateBasket = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket?sessionId=$($Basket.sessionId)"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $Basketbody
                } 
    
                $Basket = (Invoke-RestMethod @splatUpdateBasket) 

                #Set e-Sim characteristics
                $BasketBody = @{
                    characteristicActions = @(
                        @{
                            name  = "eSim"
                            value = $true
                        }
                    )
                } | ConvertTo-Json -Depth 5

                $splatUpdateBasket = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket?sessionId=$($Basket.sessionId)"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $Basketbody
                } 
    
                $Basket = (Invoke-RestMethod @splatUpdateBasket) #>

               #Set e-Sim eSimEmail
                $BasketBody = @{
                    characteristicActions = @(
                        @{
                            name  = "eSimEmail"
                            value = $($personContext.Person.Contact.Business.Email)
                        }
                    )
                } | ConvertTo-Json -Depth 5

                $splatUpdateBasket = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket?sessionId=$($Basket.sessionId)"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $Basketbody
                } 
    
                $Basket = (Invoke-RestMethod @splatUpdateBasket) #>

                #Set e-Sim eSimConfirmationCode
                $BasketBody = @{
                    characteristicActions = @(
                        @{
                            name  = "eSimConfirmationCode"
                            value = $eSimConfirmationCode
                        }
                    )
                } | ConvertTo-Json -Depth 5

                $splatUpdateBasket = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket?sessionId=$($Basket.sessionId)"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $Basketbody
                } 
    
                $Basket = (Invoke-RestMethod @splatUpdateBasket)#>

                ## Overzicht
                $splatSetBasketContent = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket?sessionId=$($Basket.sessionId)"
                    Method  = 'get'
                    Headers = $headers
                    
                }

                $BasketContent = (Invoke-RestMethod @splatSetBasketContent)

                ##Order the basket!
                $Date = (Get-Date).ToString('ddMMyyyy')

                $BasketBody = @{
                    referenceNumber = "HelloID-$Date"
                } | ConvertTo-Json -Depth 5

                $splatOrderBasket = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/mobile/kpn/mobileservices/contracting/basket/order?sessionId=$($Basket.sessionId)"
                    Method  = 'POST'
                    Headers = $headers
                    Body    = $Basketbody
                } 
    
                $OrderBasket = (Invoke-RestMethod @splatOrderBasket)

            }
            else {
                Write-Information "[DryRun] Grant KPN permission: [$($actionContext.References.Permission.DisplayName)] - [$($actionContext.References.Permission.Reference)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Grant permission - SIMcard (Template: $KPNTemplate) was successful"
                    IsError = $false
                })
        }

        'SkipProcessing' {
            Write-Information "KPN account: SIMcard (Template: $KPNTemplate) already has product: $KPNProductToOrder"

            ## Opslaan van het ID?

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "KPN account: SIMcard (Template: $KPNTemplate) already has product: $KPNProductToOrder"
                    IsError = $false
                })
            break
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