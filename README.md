# HelloID-Conn-Prov-Target-KPN-Mobile-Services

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="https://github.com/Tools4everBV/HelloID-Conn-Prov-Target-KPN-Mobile-Services/blob/main/Logo.png?raw=true">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-KPN-Mobile-Services](#helloid-conn-prov-target-kpn-mobile-services)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Getting started](#getting-started)
    - [Provisioning PowerShell V2 connector](#provisioning-powershell-v2-connector)
      - [Correlation configuration](#correlation-configuration)
      - [Field mapping](#field-mapping)
    - [Connection settings](#connection-settings)
    - [Prerequisites](#prerequisites)
    - [Remarks](#remarks)
  - [Setup the connector](#setup-the-connector)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-KPN-Mobile-Services_ is a _target_ connector. _KPN-Mobile-Services_ provides a set of REST API's that allow you to programmatically interact with its data. The HelloID connector uses the API endpoints listed in the table below.

| Endpoint                          | Description                                |
| --------------------------------- | ------------------------------------------ |
| /hierarchy/subscribers            | Subscriber account management              |
| /hierarchy/children               | Locations management                       |
| /subscribers/{ID}/delete          | Deletes the subscriber                     |
| /hierarchy/subscribers/{ID}/move" | Moves the subscriber to different location |

The following lifecycle actions are available:

| Action             | Description                                                                                                          |
| ------------------ | -------------------------------------------------------------------------------------------------------------------- |
| create.ps1         | PowerShell _create_ lifecycle action for creating a subscriber and setting the correct costcenter                    |
| delete.ps1         | PowerShell _delete_ lifecycle action for deleting the subscriber                                                     |
| update.ps1         | PowerShell _update_ lifecycle action for updating the subscriber and moving the subscriber to the correct costcenter |
| configuration.json | Default _configuration.json_                                                                                         |
| fieldMapping.json  | Default _fieldMapping.json_                                                                                          |

## Getting started

### Provisioning PowerShell V2 connector

#### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _KPN-Mobile-Services_ to a person in _HelloID_.

To properly setup the correlation:

1. Open the `Correlation` tab.

2. Specify the following configuration:

    | Setting                   | Value                             |
    | ------------------------- | --------------------------------- |
    | Enable correlation        | `True`                            |
    | Person correlation field  | `PersonContext.Person.ExternalId` |
    | Account correlation field | `employeeNumber`                  |

> [!NOTE]
> The possible properties to use with the filter are: `FIRSTNAME, LASTNAME, SURNAME_PREFIX, CONTRACTS, DEBTORNAME, FIXED_NUMBER, EMPLOYEE_NUMBER.` If you want to use a different correlation property instead of `EMPLOYEE_NUMBER`, you can change the filter in the get request inside the `create.ps1` script. Keep in mind that the property needs to be in capital letters. For more information see the API documentation.

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

#### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

### Connection settings

The following settings are required to connect to the API.

| Setting      | Description                        | Mandatory |
| ------------ | ---------------------------------- | --------- |
| ClientId     | The UserName to connect to the API | Yes       |
| ClientSecret | The Password to connect to the API | Yes       |
| BaseUrl      | The URL to the API                 | Yes       |

### Prerequisites
- Connection setting
- Costcenter property on the contract needs to have an value 

### Remarks
- Creating a subscriber may take several minutes, and the creation response does not provide an ID for the next action. Since actions have a maximum duration of 30 seconds, the script will check after 15 seconds whether the user is available. If not, it will throw an error. Be careful not to retry immediately, as this could result in creating a duplicate subscriber.

- The GET call for correlation uses a filter that operates with "contains". Therefore, the PowerShell script performs an additional filtering step using "equals".

- The "get children" API request works similarly to the "get subscribers" request, which is why there are two GET calls for subscribers in both the create and update scripts.

- The body of the "update subscriber" API call requires all properties that are set in the "create" action lifecycle. If any properties are missing in the body, they will reset to their default values (e.g., strings will become empty, and integers will become null).

- The property GroupId gets mapped to none in the fieldmapping because this is mapped in the code. The groupId is filled with the value of the internal ID of a cost center. We retrieve the cost center based on the cost center number in the field mapping.

## Setup the connector

> _How to setup the connector in HelloID._ Are special settings required. Like the _primary manager_ settings for a source connector.

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP]
>  _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com/forum/helloid-connectors/provisioning/5278-helloid-provisioning-target-kpn-mobile-services)_.

> [!TIP]
>  _For more information about the KPN mobile services API, please refer to [swagger](https://app.swaggerhub.com/apis-docs/kpn/MobileServicesManagement-KPN/v11)_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/

