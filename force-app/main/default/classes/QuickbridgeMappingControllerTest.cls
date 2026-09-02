@IsTest
private class QuickbridgeMappingControllerTest {
  @TestSetup
  static void setupData() {
    insert new Connector_Instance__c(
      Name = 'QBO Mapping Test',
      Connector_Key__c = 'qbo',
      Connector_Label__c = 'QuickBooks Online',
      Active__c = false,
      Environment__c = 'Sandbox',
      Health_Status__c = 'Unknown',
      Named_Credential__c = 'QuickBooks_NC',
      External_Credential__c = 'QuickBooks_EC'
    );
  }

  @IsTest
  static void workspaceUsesOperationsSchemaDefaultsAndOverrides() {
    QuickbridgeMappingController.bypassSecurityForTests = true;

    QuickbridgeMappingController.MappingWorkspace workspace =
      QuickbridgeMappingController.getMappingWorkspace('qbo');

    System.assertEquals('qbo', workspace.connectorKey);
    System.assertEquals('QuickBooks Online', workspace.connectorLabel);
    System.assert(!workspace.operations.isEmpty());
    Boolean foundCustomerOutbound = false;
    for (QuickbridgeMappingController.OperationWorkspace operation : workspace.operations) {
      System.assertNotEquals(null, operation.workspaceKey);
      System.assertNotEquals(null, operation.salesforceObject);
      System.assertNotEquals(null, operation.externalObject);
      System.assert(!operation.salesforceFields.isEmpty());
      if (
        operation.operationKey == 'CustomerUpsert' &&
        operation.direction == 'Outbound'
      ) {
        foundCustomerOutbound = true;
        System.assertEquals('Account', operation.salesforceObject);
        System.assertEquals('Customer', operation.externalObject);
        System.assert(!operation.mappings.isEmpty());
      }
    }
    System.assert(foundCustomerOutbound, 'The outbound customer operation must be editable.');
  }

  @IsTest
  static void saveValidatesAndQueuesDeterministicMetadata() {
    QuickbridgeMappingController.bypassSecurityForTests = true;
    Map<String, Object> request = new Map<String, Object>{
      'connectorKey' => 'qbo',
      'operationKey' => 'CustomerUpsert',
      'operationDirection' => 'Outbound',
      'salesforceObject' => 'Account',
      'externalObject' => 'Customer',
      'rows' => new List<Object>{
        new Map<String, Object>{
          'salesforceField' => 'Name',
          'externalPath' => 'DisplayName',
          'direction' => 'Both',
          'active' => true
        },
        new Map<String, Object>{
          'salesforceField' => 'Phone',
          'externalPath' => 'PrimaryPhone.FreeFormNumber',
          'direction' => 'Outbound',
          'active' => true
        }
      }
    };

    QuickbridgeMappingController.SaveResponse response =
      QuickbridgeMappingController.saveMappings(JSON.serialize(request));

    System.assertEquals('Succeeded', response.status);
    System.assertEquals(2, response.submittedCount);
    System.assertEquals('TEST-MAPPING-DEPLOYMENT', response.deploymentId);
  }

  @IsTest
  static void unsafeAndDuplicateMappingsAreRejected() {
    QuickbridgeMappingController.bypassSecurityForTests = true;
    Map<String, Object> row = new Map<String, Object>{
      'salesforceField' => 'Name',
      'externalPath' => 'DisplayName',
      'direction' => 'Both',
      'active' => true
    };
    Map<String, Object> duplicateRequest = baseRequest();
    duplicateRequest.put('rows', new List<Object>{ row, row });
    assertRejected(JSON.serialize(duplicateRequest), 'Duplicate');

    Map<String, Object> unsafeRequest = baseRequest();
    unsafeRequest.put(
      'rows',
      new List<Object>{
        new Map<String, Object>{
          'salesforceField' => 'Name',
          'externalPath' => '../unsafe',
          'direction' => 'Outbound',
          'active' => true
        }
      }
    );
    assertRejected(JSON.serialize(unsafeRequest), 'External field paths');
    assertRejected('{bad-json', 'invalid');
  }

  @IsTest
  static void resetAndDeploymentStatusHaveSafeEmptyBehavior() {
    QuickbridgeMappingController.bypassSecurityForTests = true;

    QuickbridgeMappingController.SaveResponse cleared =
      QuickbridgeMappingController.clearMappings(
        'qbo',
        'CustomerUpsert',
        'Account',
        'Customer',
        'Outbound'
      );
    System.assertNotEquals(null, cleared.status);

    QuickbridgeMappingController.DeploymentStatus emptyStatus =
      QuickbridgeMappingController.getDeploymentStatus(null);
    System.assertEquals('Succeeded', emptyStatus.status);
    QuickbridgeMappingController.DeploymentStatus unknownStatus =
      QuickbridgeMappingController.getDeploymentStatus('not-cached');
    System.assertEquals('Unknown', unknownStatus.status);

    QuickbridgeMappingController.MappingWorkspace stripeWorkspace =
      QuickbridgeMappingController.getMappingWorkspace('stripe');
    System.assertEquals(0, stripeWorkspace.operations.size());

    try {
      QuickbridgeMappingController.getMappingWorkspace('../qbo');
      System.assert(false, 'Unsafe connector input must be rejected.');
    } catch (AuraHandledException expected) {
      System.assertNotEquals(null, expected, 'Unsafe connector input must raise an exception.');
    }
  }

  @IsTest
  static void operationAndRowValidationRejectsMismatchedMetadata() {
    QuickbridgeMappingController.bypassSecurityForTests = true;

    try {
      QuickbridgeMappingController.clearMappings(
        'qbo',
        'CustomerUpsert',
        'Contact',
        'Customer',
        'Outbound'
      );
      System.assert(false, 'A mismatched object must be rejected.');
    } catch (AuraHandledException expected) {
      System.assertNotEquals(null, expected);
    }

    Map<String, Object> wrongDirection = baseRequest();
    wrongDirection.put('operationDirection', 'Sideways');
    wrongDirection.put('rows', validRows());
    assertRejected(JSON.serialize(wrongDirection), null);

    Map<String, Object> wrongExternalObject = baseRequest();
    wrongExternalObject.put('externalObject', 'Vendor');
    wrongExternalObject.put('rows', validRows());
    assertRejected(JSON.serialize(wrongExternalObject), null);

    Map<String, Object> noRows = baseRequest();
    noRows.put('rows', new List<Object>());
    assertRejected(JSON.serialize(noRows), null);

    Map<String, Object> badField = baseRequest();
    badField.put(
      'rows',
      new List<Object>{
        new Map<String, Object>{
          'salesforceField' => 'Does_Not_Exist__c',
          'externalPath' => 'DisplayName',
          'direction' => 'Outbound',
          'active' => true
        }
      }
    );
    assertRejected(JSON.serialize(badField), null);
  }

  private static Map<String, Object> baseRequest() {
    return new Map<String, Object>{
      'connectorKey' => 'qbo',
      'operationKey' => 'CustomerUpsert',
      'operationDirection' => 'Outbound',
      'salesforceObject' => 'Account',
      'externalObject' => 'Customer'
    };
  }

  private static List<Object> validRows() {
    return new List<Object>{
      new Map<String, Object>{
        'salesforceField' => 'Name',
        'externalPath' => 'DisplayName',
        'direction' => 'Outbound',
        'active' => true
      }
    };
  }

  private static void assertRejected(String payload, String expectedMessage) {
    try {
      QuickbridgeMappingController.saveMappings(payload);
      System.assert(false, 'Invalid mapping input must be rejected.');
    } catch (AuraHandledException expected) {
      System.assertNotEquals(null, expected);
    }
  }
}