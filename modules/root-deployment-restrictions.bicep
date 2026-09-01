targetScope = 'managementGroup'

@description('Prefix used for stable initiative and assignment names.')
@minLength(3)
@maxLength(24)
param namePrefix string

@description('Full resource ID of the in-repository public IP audit policy definition.')
@minLength(1)
param auditPublicIpPolicyDefinitionId string

@description('Change-controlled Azure regions allowed by the customer deployment profile.')
@minLength(1)
param allowedLocations string[]

@description('Change-controlled resource types allowed by the customer deployment profile.')
@minLength(1)
param allowedResourceTypes string[]

@description('Change-controlled virtual machine size SKUs allowed by the customer deployment profile.')
@minLength(1)
param allowedVmSkus string[]

@description('Keep DoNotEnforce until the customer allowlists and policy impact are approved.')
param enforcementMode 'Default' | 'DoNotEnforce' = 'DoNotEnforce'

var allowedLocationsPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'e56962a6-4747-49cd-b67b-bf8b01975c4c'
)
var allowedResourceTypesPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'a08ec900-254a-4555-9bf5-e42af04b5c5c'
)
var allowedVmSkusPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'cccc23c7-8427-4f53-ad12-b6a63eb452b3'
)
var managedDisksPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  '06a78e20-9358-41c9-923c-fb736d382a4d'
)

module initiative 'policy-initiative.bicep' = {
  name: 'root-deployment-restrictions'
  params: {
    initiativeName: '${namePrefix}-deploy-restrictions'
    initiativeDisplayName: 'Demo - root deployment restrictions'
    initiativeDescription: 'Customer deployment guardrails inherited from the dedicated demo root. Deny controls remain non-enforcing until change-controlled allowlists are approved.'
    initiativeCategory: 'Demo Landing Zone'
    initiativeVersion: '2.0.0'
    initiativeParameters: {
      allowedLocations: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed locations'
          description: 'Change-controlled customer region allowlist.'
          strongType: 'location'
        }
      }
      allowedResourceTypes: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed resource types'
          description: 'Change-controlled allowlist including required child and remediation resource types.'
        }
      }
      allowedVmSkus: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed virtual machine size SKUs'
          description: 'Change-controlled customer VM SKU allowlist.'
        }
      }
    }
    policyDefinitionGroups: [
      {
        name: 'deployment-restrictions'
        displayName: 'Deployment restrictions'
        category: 'Governance'
        description: 'Audit-first location, resource type, compute, and public exposure controls.'
      }
    ]
    policyDefinitionReferences: [
      {
        policyDefinitionId: allowedLocationsPolicyDefinitionId
        policyDefinitionReferenceId: 'allowed-locations'
        parameters: {
          listOfAllowedLocations: {
            value: '[parameters(\'allowedLocations\')]'
          }
          effect: {
            value: 'Deny'
          }
        }
        groupNames: [
          'deployment-restrictions'
        ]
      }
      {
        policyDefinitionId: allowedResourceTypesPolicyDefinitionId
        policyDefinitionReferenceId: 'allowed-resource-types'
        parameters: {
          listOfResourceTypesAllowed: {
            value: '[parameters(\'allowedResourceTypes\')]'
          }
          effect: {
            value: 'Deny'
          }
        }
        groupNames: [
          'deployment-restrictions'
        ]
      }
      {
        policyDefinitionId: allowedVmSkusPolicyDefinitionId
        policyDefinitionReferenceId: 'allowed-vm-skus'
        parameters: {
          listOfAllowedSKUs: {
            value: '[parameters(\'allowedVmSkus\')]'
          }
        }
        groupNames: [
          'deployment-restrictions'
        ]
      }
      {
        policyDefinitionId: managedDisksPolicyDefinitionId
        policyDefinitionReferenceId: 'audit-managed-disks'
        parameters: {}
        groupNames: [
          'deployment-restrictions'
        ]
      }
      {
        policyDefinitionId: auditPublicIpPolicyDefinitionId
        policyDefinitionReferenceId: 'audit-public-ip'
        parameters: {}
        groupNames: [
          'deployment-restrictions'
        ]
      }
    ]
  }
}

module assignment 'policy-assignment.bicep' = {
  name: 'assign-root-deployment-restrictions'
  params: {
    assignmentName: 'demo-deploy-restrictions'
    displayName: 'Demo - root deployment restrictions'
    description: 'Applies audit-first customer deployment restrictions throughout both subscription branches under the dedicated demo root.'
    policyDefinitionId: initiative.outputs.policySetDefinitionId
    enforcementMode: enforcementMode
    parameters: {
      allowedLocations: {
        value: allowedLocations
      }
      allowedResourceTypes: {
        value: allowedResourceTypes
      }
      allowedVmSkus: {
        value: allowedVmSkus
      }
    }
    nonComplianceMessages: [
      {
        message: 'Deploy regional resources only in a change-controlled approved location.'
        policyDefinitionReferenceId: 'allowed-locations'
      }
      {
        message: 'Deploy only change-controlled approved resource types, including required child resources.'
        policyDefinitionReferenceId: 'allowed-resource-types'
      }
      {
        message: 'Select a change-controlled approved virtual machine size SKU.'
        policyDefinitionReferenceId: 'allowed-vm-skus'
      }
      {
        message: 'Virtual machines should use managed disks.'
        policyDefinitionReferenceId: 'audit-managed-disks'
      }
      {
        message: 'Public IP address creation requires review.'
        policyDefinitionReferenceId: 'audit-public-ip'
      }
    ]
  }
}

output policySetDefinitionId string = initiative.outputs.policySetDefinitionId
output policyAssignmentId string = assignment.outputs.policyAssignmentId
