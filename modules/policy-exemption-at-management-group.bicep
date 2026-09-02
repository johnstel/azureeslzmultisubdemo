targetScope = 'managementGroup'

@sys.description('Policy exemption resource name.')
@minLength(1)
@maxLength(64)
param exemptionName string

@sys.description('Policy exemption display name.')
@minLength(1)
@maxLength(128)
param displayName string

@sys.description('Policy exemption description.')
@minLength(1)
@maxLength(512)
param description string

@sys.description('Policy exemption category.')
param exemptionCategory 'Waiver' | 'Mitigated'

@sys.description('Full resource ID of the target policy assignment.')
@minLength(1)
param policyAssignmentId string

@sys.description('Expiry timestamp in UTC.')
@minLength(1)
param expiresOn string

@sys.description('Accountable exemption owner.')
@minLength(1)
@maxLength(128)
param owner string

@sys.description('Documented business or technical justification.')
@minLength(1)
@maxLength(1024)
param justification string

@sys.description('Ticket or evidence reference backing the exemption.')
@minLength(1)
@maxLength(256)
param ticketReference string

@sys.description('Optional initiative policyDefinitionReferenceIds for targeted exemptions.')
param policyDefinitionReferenceIds string[] = []

@sys.description('Metadata source for traceability.')
@minLength(1)
@maxLength(64)
param source string = 'Bicep'

@sys.description('Approver identity recorded for governance traceability.')
@minLength(1)
@maxLength(128)
param approver string

@sys.description('Creation timestamp metadata in UTC.')
@minLength(1)
param createdOn string

@sys.description('Last review timestamp metadata in UTC.')
@minLength(1)
param reviewedOn string

@sys.description('v2 governance ownership metadata.')
@minLength(1)
@maxLength(128)
param governanceOwner string = 'eslz-v2-governance'

resource exemption 'Microsoft.Authorization/policyExemptions@2024-12-01-preview' = {
  name: exemptionName
  properties: {
    displayName: displayName
    description: description
    exemptionCategory: exemptionCategory
    policyAssignmentId: policyAssignmentId
    expiresOn: expiresOn
    metadata: {
      source: source
      approver: approver
      createdOn: createdOn
      reviewedOn: reviewedOn
      governanceOwner: governanceOwner
      governanceVersion: '2.0'
      owner: owner
      justification: justification
      ticketReference: ticketReference
    }
    ...(!empty(policyDefinitionReferenceIds) ? {
      policyDefinitionReferenceIds: policyDefinitionReferenceIds
    } : {})
  }
}

output policyExemptionId string = exemption.id
