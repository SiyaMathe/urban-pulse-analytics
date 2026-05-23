// =============================================================================
// Urban Pulse Analytics — Azure Infrastructure
// Provisions: SQL Server + DB, Function App, App Service, Storage Account,
//             Application Insights, Static Web App
// =============================================================================

targetScope = 'resourceGroup'

@description('Environment name (dev/staging/production)')
@allowed(['dev', 'staging', 'production'])
param environment string = 'dev'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('SQL Server admin password')
@secure()
param sqlAdminPassword string

@description('SQL Server admin login')
param sqlAdminLogin string = 'sqladmin'

var prefix       = 'urbanpulse-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id)

// =============================================================================
// Storage Account (Queues + Blob for Bronze layer)
// =============================================================================
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'upstorage${uniqueSuffix}'
  location: location
  sku: { name: environment == 'production' ? 'Standard_GRS' : 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

// Sensor readings queue
resource readingsQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-01-01' = {
  name: '${storageAccount.name}/default/sensor-readings-queue'
  properties: {}
}

// Dead-letter queue
resource deadLetterQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-01-01' = {
  name: '${storageAccount.name}/default/sensor-readings-deadletter'
  properties: {}
}

// Bronze layer blob container
resource bronzeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${storageAccount.name}/default/bronze-raw'
  properties: {
    publicAccess: 'None'
  }
}

// =============================================================================
// Application Insights (Monitoring)
// =============================================================================
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// =============================================================================
// Azure SQL Server + Database
// =============================================================================
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: '${prefix}-sql-${uniqueSuffix}'
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
  }
}

// Allow Azure services to connect
resource sqlFirewallAzure 'Microsoft.Sql/servers/firewallRules@2023-05-01-preview' = {
  name: 'AllowAzureServices'
  parent: sqlServer
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  name: 'UrbanPulseAnalytics'
  parent: sqlServer
  location: location
  sku: {
    name: environment == 'production' ? 'S2' : 'S0'
    tier: 'Standard'
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: environment == 'production' ? 53687091200 : 2147483648
    zoneRedundant: environment == 'production'
  }
}

// =============================================================================
// App Service Plan (shared by Function App + Web App)
// =============================================================================
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-plan'
  location: location
  sku: {
    name: environment == 'production' ? 'P1v3' : 'B1'
    tier: environment == 'production' ? 'PremiumV3' : 'Basic'
  }
  properties: {
    reserved: false   // Windows
  }
}

// =============================================================================
// Azure Function App
// =============================================================================
resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${prefix}-functions-${uniqueSuffix}'
  location: location
  kind: 'functionapp'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      netFrameworkVersion: 'v8.0'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
        {
          name: 'AZURE_STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'AZURE_SQL_CONNECTION_STRING'
          value: 'Server=${sqlServer.properties.fullyQualifiedDomainName};Database=UrbanPulseAnalytics;User Id=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

// =============================================================================
// REST API Web App
// =============================================================================
resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${prefix}-api-${uniqueSuffix}'
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      netFrameworkVersion: 'v8.0'
      appSettings: [
        {
          name: 'AZURE_SQL_CONNECTION_STRING'
          value: 'Server=${sqlServer.properties.fullyQualifiedDomainName};Database=UrbanPulseAnalytics;User Id=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

// =============================================================================
// Static Web App (Dashboard)
// =============================================================================
resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: '${prefix}-dashboard'
  location: 'eastus2'  // Static Web Apps not available in all regions
  sku: {
    name: environment == 'production' ? 'Standard' : 'Free'
    tier: environment == 'production' ? 'Standard' : 'Free'
  }
  properties: {}
}

// =============================================================================
// Outputs (consumed by CD pipeline)
// =============================================================================
output functionappName   string = functionApp.name
output webappName        string = webApp.name
output sqlServerName     string = sqlServer.properties.fullyQualifiedDomainName
output storageAccountName string = storageAccount.name
output appInsightsKey    string = appInsights.properties.InstrumentationKey
output dashboardUrl      string = 'https://${staticWebApp.properties.defaultHostname}'
output apiUrl            string = 'https://${webApp.properties.defaultHostName}'
output functionsUrl      string = 'https://${functionApp.properties.defaultHostName}'
