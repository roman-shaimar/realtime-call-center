targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string
@description('Location for OpenAI resources (if empty uses primary location)')
param aiResourceLocation string
@description('Principal Id of the local user to assign application roles. Leave empty to skip.')
param principalId string
@description('Id of the user or app to assign application roles')
param resourceGroupName string = ''
param openaiName string = ''
param containerAppsEnvironmentName string = ''
param containerRegistryName string = ''

// param searchEndpoint string = ''
param searchServiceName string = ''
param searchServiceLocation string = ''
@allowed(['free', 'basic', 'standard', 'standard2', 'standard3', 'storage_optimized_l1', 'storage_optimized_l2'])
param searchServiceSkuName string

param searchIndexName string
param searchSemanticConfiguration string

/* Azure communication resource details */
@description('Name of the Azure Communication service')
param acsServiceName string = ''

param searchServiceSemanticRankerLevel string
var actualSearchServiceSemanticRankerLevel = (searchServiceSkuName == 'free')
  ? 'disabled'
  : searchServiceSemanticRankerLevel

param searchIdentifierField string
param searchContentField string
param searchTitleField string
param searchEmbeddingField string
param searchUseVectorQuery bool

@description('Name of the AI search index to be created or updated, must be lowercase.')
param indexName string = 'voicerag-intvect'

@description('Datasource definition as base64 encoded json.')
param dataSource string = loadFileAsBase64('definitions/datasource.json')

@description('Index definition as base64 encoded json.')
param index string = loadFileAsBase64('definitions/index.json')

@description('Skillset definition as base64 encoded json.')
param skillset string = loadFileAsBase64('definitions/skillset.json')

@description('Indexer definition as base64 encoded json.')
param indexer string = loadFileAsBase64('definitions/indexer.json')

param storageAccountName string = ''
param storageContainerName string = 'content'
param storageSkuName string = 'Standard_LRS'

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

var aiSearchIndexDeploymentScriptName = 'aiSearchIndexDeploymentScript-${resourceToken}'
var tags = { 'azd-env-name': environmentName, 'app': 'audio-agents', 'tracing': 'yes' }
var principalType = 'User'

param logAnalyticsName string = ''
param applicationInsightsName string = ''
param completionDeploymentModelName string = 'gpt-4o-realtime-preview'
param completionModelName string = 'gpt-4o-realtime-preview'
param completionModelVersion string = '2024-12-17'
param openaiApiVersion string = '2024-10-01-preview'
param embeddingDeploymentCapacity int
param embedModel string = 'text-embedding-3-large'
param modelDeployments array = [
  {
    name: completionDeploymentModelName
    sku: {
      name: 'GlobalStandard'
      capacity: 1
    }
    model: {
      format: 'OpenAI'      
      name: completionModelName
      version: completionModelVersion
    }
  }
  {
    name: embedModel
    model: {
      format: 'OpenAI'
      name: embedModel
      version: '1'
    }
    sku: {
      name: 'Standard'
      capacity: embeddingDeploymentCapacity
    }
  }
]

// Organize resources in a resource group
resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}


// Container apps host (including container registry)
module containerApps './core/host/container-apps.bicep' = {
  name: 'container-apps'
  scope: resourceGroup
  params: {
    name: 'app'
    containerAppsEnvironmentName: !empty(containerAppsEnvironmentName) ? containerAppsEnvironmentName : '${abbrs.appManagedEnvironments}${resourceToken}'
    containerRegistryName: !empty(containerRegistryName) ? containerRegistryName : '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    logAnalyticsWorkspaceName: monitoring.outputs.logAnalyticsWorkspaceName
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    identityName: '${abbrs.managedIdentityUserAssignedIdentities}api-agents'
  }
}

module openai './ai/openai.bicep' = {
  name: 'openai'
  scope: resourceGroup
  params: {
    location: !empty(aiResourceLocation) ? aiResourceLocation : location
    tags: tags
    customDomainName: !empty(openaiName) ? openaiName : '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    name: !empty(openaiName) ? openaiName : '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    deployments: modelDeployments
  }
}


module monitoring './core/monitor/monitoring.bicep' = {
  name: 'monitoring'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    logAnalyticsName: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
  }
}

module security 'core/security/security-main.bicep' = {
  name: 'security'
  scope: resourceGroup
  params: {
    openaiName: openai.outputs.openaiName
    containerRegistryName: containerApps.outputs.registryName
    principalIds: [
      containerApps.outputs.identityPrincipalId
      searchService.outputs.systemAssignedMIPrincipalId
      principalId
    ]
  }
}


module searchService 'br/public:avm/res/search/search-service:0.7.1' =  {
  name: 'search-service'
  scope: resourceGroup
  params: {
    name: !empty(searchServiceName) ? searchServiceName : '${abbrs.searchSearchServices}${resourceToken}'
    location:  !empty(searchServiceLocation) ? searchServiceLocation : location
    tags: tags
    disableLocalAuth: false
    authOptions: {
      aadorApiKey: {
        aadAuthFailureMode: 'http403'
      }
    }
    sku: searchServiceSkuName
    replicaCount: 1
    semanticSearch: actualSearchServiceSemanticRankerLevel
    // An outbound managed identity is required for integrated vectorization to work,
    // and is only supported on non-free tiers:
    managedIdentities: { systemAssigned: true }
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'Search Index Data Reader'
        principalId: principalId
        principalType: principalType
      }
      {
        roleDefinitionIdOrName: 'Search Index Data Contributor'
        principalId: principalId
        principalType: principalType
      }
      {
        roleDefinitionIdOrName: 'Search Service Contributor'
        principalId: principalId
        principalType: principalType
      }
      {
        roleDefinitionIdOrName: 'Search Service Contributor'
        principalId: containerApps.outputs.identityPrincipalId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}


module storage 'br/public:avm/res/storage/storage-account:0.9.1' = {
  name: 'storage'
  scope: resourceGroup
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: storageSkuName
    publicNetworkAccess: 'Enabled' // Necessary for uploading documents to storage container
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    blobServices: {
      deleteRetentionPolicyDays: 2
      deleteRetentionPolicyEnabled: true
      containers: [
        {
          name: storageContainerName
          publicAccess: 'None'
        }
        {
          name: 'prompt'
          publicAccess: 'None'
        }
      ]
    }
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'Storage Blob Data Reader'
        principalId: searchService.outputs.systemAssignedMIPrincipalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: 'Storage Blob Data Reader'
        principalId: principalId
        principalType: principalType
      } 
      {
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
        principalId: principalId
        principalType: principalType
      }      
    ]
  }
}

module communicationService 'core/communicationservice/communication-services.bicep' = {
  name: 'communicationservice'
  scope: resourceGroup
  params: {
      communicationServiceName: !empty(acsServiceName) ? acsServiceName : '${abbrs.azureCommunicationService}${resourceToken}'
  }
}

module eventGrid './core/eventgrid/eventgrid.bicep' = {
  name: 'eventgrid'
  scope: resourceGroup
  params: {
    communicationServiceName: communicationService.outputs.communicationServiceName
    location: communicationService.outputs.location
    tags: tags
  }
}

module aiSearchIndexDeploymentScript 'br/public:avm/res/resources/deployment-script:0.4.0' = {
  name: 'aiSearchIndexDeploymentScript'
  scope: resourceGroup
  params: {
    kind: 'AzurePowerShell'
    name: aiSearchIndexDeploymentScriptName
    azPowerShellVersion: '9.7'
    location: resourceGroup.location
    managedIdentities: {
      userAssignedResourcesIds: [
        containerApps.outputs.identityResourceId
      ]
    }
    cleanupPreference: 'OnExpiration'
    retentionInterval: 'PT1H'
    scriptContent: loadTextContent('scripts/setupindex.ps1')
    arguments: '-index \\"${index}\\" -indexer \\"${indexer}\\" -datasource \\"${dataSource}\\" -skillset \\"${skillset}\\" -searchServiceName \\"${searchService.outputs.name}\\" -dataSourceContainerName \\"${storageContainerName}\\" -dataSourceConnectionString \\"ResourceId=${storage.outputs.resourceId};\\" -indexName \\"${indexName}\\" -AzureOpenAIResourceUri \\"${openai.outputs.openaiEndpoint}\\" -indexerEmbeddingModelId \\"${embedModel}\\" -embeddingModelName \\"${embedModel}\\" -searchEmbeddingModelId \\"${embedModel}\\"'
  }
}

// Outputs
output ACS_CONNECTION_STRING string = communicationService.outputs.primaryConnectionString
output ACS_ENDPOINT string = communicationService.outputs.endpoint
output ACS_SERVICE_NAME string = communicationService.outputs.communicationServiceName


output AZURE_LOCATION string = location
output AZURE_AI_SERVICE_LOCATION string = openai.outputs.location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = resourceGroup.name

output OPENAI_API_TYPE string = 'azure'
output AZURE_OPENAI_VERSION string = openaiApiVersion
output AZURE_OPENAI_API_KEY string = openai.outputs.openaiKey
output AZURE_OPENAI_ENDPOINT string = openai.outputs.openaiEndpoint
output AZURE_OPENAI_COMPLETION_MODEL string = completionModelName
output AZURE_OPENAI_COMPLETION_DEPLOYMENT_NAME string = completionDeploymentModelName

output AZURE_OPENAI_EMBEDDING_DEPLOYMENT string = embedModel
output AZURE_OPENAI_EMBEDDING_MODEL string = embedModel

output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output APPLICATIONINSIGHTS_NAME string = monitoring.outputs.applicationInsightsName
output PRINCIPAL_ID string = principalId

output AZURE_STORAGE_ENDPOINT string = 'https://${storage.outputs.name}.blob.core.windows.net/'
output AZURE_STORAGE_ACCOUNT string = storage.outputs.name

output AZURE_STORAGE_CONTAINER string = storageContainerName
output AZURE_SEARCH_ENDPOINT string = 'https://${searchService.outputs.name}.search.windows.net'
output AZURE_SEARCH_INDEX string = searchIndexName
output AZURE_SEARCH_SEMANTIC_CONFIGURATION string = searchSemanticConfiguration
output AZURE_SEARCH_IDENTIFIER_FIELD string = searchIdentifierField
output AZURE_SEARCH_CONTENT_FIELD string = searchContentField
output AZURE_SEARCH_TITLE_FIELD string = searchTitleField
output AZURE_SEARCH_EMBEDDING_FIELD string = searchEmbeddingField
output AZURE_SEARCH_USE_VECTOR_QUERY bool = searchUseVectorQuery
// #disable-next-line outputs-should-not-contain-secrets
// output AZURE_SEARCH_API_KEY string = aiSearch.listAdminKeys().primaryKey
