targetScope = 'tenant'

@description('Dedicated demo-root management group ID. The example never targets the tenant root.')
@minLength(1)
param demoRootManagementGroupId string

@description('Prefix used by the existing in-repository custom policy definitions.')
@minLength(3)
@maxLength(24)
param namePrefix string = 'eslz-demo'

var allowedLocationsBuiltInPolicyDefinitionId = tenantResourceId(
  'Microsoft.Authorization/policyDefinitions',
  'e56962a6-4747-49cd-b67b-bf8b01975c4c'
)
var auditPublicIpCustomPolicyDefinitionId = managementGroupResourceId(
  demoRootManagementGroupId,
  'Microsoft.Authorization/policyDefinitions',
  '${namePrefix}-audit-public-ip'
)

module organizationalAuditInitiative '../modules/policy-initiative.bicep' = {
  name: 'organizational-audit-initiative'
  scope: managementGroup(demoRootManagementGroupId)
  params: {
    initiativeName: '${namePrefix}-organizational-audit'
    initiativeDisplayName: 'Demo - organizational audit controls'
    initiativeDescription: 'Composes a verified built-in control and an in-repository custom control without assigning or enforcing the initiative.'
    initiativeCategory: 'Demo Landing Zone'
    initiativeVersion: '2.0.0'
    initiativeParameters: {
      allowedLocations: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed locations'
          description: 'Continental-US Azure regions evaluated by the built-in allowed-locations policy.'
          strongType: 'location'
        }
        defaultValue: [
          'centralus'
          'eastus'
          'eastus2'
          'northcentralus'
          'southcentralus'
          'westcentralus'
          'westus'
          'westus2'
          'westus3'
        ]
      }
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Allowed locations effect'
          description: 'Audit is the safe default; enforcement requires a separately reviewed assignment.'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
    }
    policyDefinitionGroups: [
      {
        name: 'deployment-visibility'
        displayName: 'Deployment visibility'
        category: 'Governance'
        description: 'Audit-safe controls that surface deployment posture without remediation or paid services.'
      }
    ]
    policyDefinitionReferences: [
      {
        policyDefinitionId: allowedLocationsBuiltInPolicyDefinitionId
        policyDefinitionReferenceId: 'allowed-locations-audit'
        parameters: {
          listOfAllowedLocations: {
            value: '[parameters(\'allowedLocations\')]'
          }
          effect: {
            value: '[parameters(\'effect\')]'
          }
        }
        groupNames: [
          'deployment-visibility'
        ]
      }
      {
        policyDefinitionId: auditPublicIpCustomPolicyDefinitionId
        policyDefinitionReferenceId: 'audit-public-ip'
        parameters: {}
        groupNames: [
          'deployment-visibility'
        ]
      }
    ]
  }
}

output policySetDefinitionId string = organizationalAuditInitiative.outputs.policySetDefinitionId
output policySetDefinitionName string = organizationalAuditInitiative.outputs.policySetDefinitionName
output policyDefinitionReferenceIds string[] = organizationalAuditInitiative.outputs.policyDefinitionReferenceIds
