targetScope = 'resourceGroup'

resource paidStorageAccount 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: 'paidfixture'
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}
