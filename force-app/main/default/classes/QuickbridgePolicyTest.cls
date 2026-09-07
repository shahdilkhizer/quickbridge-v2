@IsTest
private class QuickbridgePolicyTest {
  private class TimeoutException extends Exception {}

  @IsTest
  static void executionRequestNormalizesAndRejectsWrongObjectIds() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = definitionFor('Bidirectional');
    GenericIntegrationRuntime.registerTestDefinition(definition);
    Account accountValue = new Account(Name = 'Request Validation');
    insert accountValue;

    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = 'TestConnector';
    request.operationKey = 'AccountSync';
    request.direction = 'out';
    request.salesforceObject = 'Account';
    request.externalEntity = 'Customer';
    request.recordIds.add(accountValue.Id);
    request.cursor = 'cursor';
    request.sinceValue = System.now();
    request.initialSync = true;
    request.scopeSize = 25;
    request.payload = '{"safe":true}';
    request.correlationKey = 'correlation';
    request.leaseToken = 'lease';
    request.pageNumber = 2;
    request.retryAttempt = 1;

    request.validate();
    ConnectorExecutionRequest normalized = request.normalizedCopy();
    System.assertEquals('Outbound', normalized.direction);
    System.assertEquals('test-connector', normalized.connectorKey);
    System.assertEquals(1, normalized.recordIds.size());
    System.assert(normalized.operationIdentity().contains('accountsync'));
    System.assertEquals(Schema.Account.SObjectType,
      ConnectorExecutionRequest.resolveSObjectType('Account'));
    System.assertEquals(Schema.Invoice__c.SObjectType,
      ConnectorExecutionRequest.resolveSObjectType('QuickBridgeTLG__Invoice__c'));
    System.assertEquals(null, ConnectorExecutionRequest.resolveSObjectType('Missing_Object__c'));
    System.assertEquals(null, ConnectorExecutionRequest.resolveSObjectType(null));

    Product2 productValue = new Product2(Name = 'Wrong ID');
    insert productValue;
    request.recordIds = new List<Id>{ productValue.Id };
    try {
      request.validate();
      System.assert(false, 'Wrong object IDs must fail.');
    } catch (ConnectorExecutionRequest.ConnectorExecutionRequestException expected) {
      System.assert(expected.getMessage().contains('does not belong'));
    }
    GenericIntegrationRuntime.clearTestDefinitions();
  }

  @IsTest
  static void retryPolicyClassifiesEveryRequiredStatusAndBackoff() {
    Map<Integer, Boolean> expectations = new Map<Integer, Boolean>{
      200 => false, 400 => false, 401 => false, 403 => false, 404 => false,
      408 => true, 429 => true, 500 => true, 502 => true, 503 => true, 504 => true
    };
    for (Integer statusCode : expectations.keySet()) {
      IntegrationRetryPolicy.RetryDecision decision = IntegrationRetryPolicy.classify(statusCode);
      System.assertEquals(expectations.get(statusCode), decision.retryable, String.valueOf(statusCode));
      System.assertEquals(statusCode, decision.httpStatusCode);
      System.assertEquals(expectations.get(statusCode), IntegrationRetryPolicy.isRetryable(statusCode));
    }
    System.assertEquals(false, IntegrationRetryPolicy.classify((Integer) null).retryable);
    System.assertEquals(false, IntegrationRetryPolicy.classify((Exception) null).retryable);
    System.assertEquals(true, IntegrationRetryPolicy.isRateLimited(429));
    System.assertEquals(true, IntegrationRetryPolicy.isPermanentFailure(422));
    System.assertEquals(true, IntegrationRetryPolicy.isRetryableMessage('UNABLE_TO_LOCK_ROW'));
    System.assertEquals(503, IntegrationRetryPolicy.httpStatusCodeFromMessage('HTTP 503 unavailable'));
    System.assertEquals(null, IntegrationRetryPolicy.httpStatusCodeFromMessage('no status'));

    IntegrationRetryPolicy.StatusCodeException statusException =
      IntegrationRetryPolicy.exceptionForStatus(429, 'rate limited');
    System.assertEquals(true, IntegrationRetryPolicy.classify(statusException).retryable);
    System.assertEquals(true, IntegrationRetryPolicy.classify(new TimeoutException('request timed out')).retryable);
    System.assertEquals(false, IntegrationRetryPolicy.classify(new TimeoutException('validation failed')).retryable);
    System.assert(IntegrationRetryPolicy.nextAttemptAt(0) > System.now());
    System.assert(IntegrationRetryPolicy.nextAttemptAt(99) <= System.now().addMinutes(61));

    Integration_Work_Item__c configured = new Integration_Work_Item__c(Max_Attempts__c = 3);
    System.assertEquals(3, IntegrationRetryPolicy.getMaxAttempts(configured));
    System.assertEquals(5, IntegrationRetryPolicy.getMaxAttempts(null));
  }

  @IsTest
  static void heartbeatAndScheduleTerminalPathsAreLeaseSafe() {
    IntegrationHeartbeat.suppressRescheduleForTests = true;
    Test.startTest();
    new IntegrationHeartbeat().execute(null);
    Test.stopTest();

    IntegrationHeartbeat.ensureScheduled();
    IntegrationHeartbeat.ensureScheduled();
    System.assertEquals(1, [
      SELECT COUNT() FROM CronTrigger
      WHERE CronJobDetail.Name = :IntegrationHeartbeat.JOB_NAME
        AND State NOT IN ('DELETED', 'COMPLETE', 'ERROR')
    ]);

    Scheduled_Integration_Job__c success = claimedSchedule('Schedule Success', 'success-token');
    insert success;
    System.assertEquals(false, ConnectorScheduleService.markRunning(success.Id, 'stale', null));
    System.assertEquals(true, ConnectorScheduleService.markRunning(success.Id, 'success-token', null, 900));
    ConnectorScheduleService.complete(success.Id, 'success-token', ConnectorExecutionResult.success());
    Scheduled_Integration_Job__c completed = [
      SELECT Status__c, Lease_Token__c, Next_Run_At__c FROM Scheduled_Integration_Job__c WHERE Id = :success.Id
    ];
    System.assertEquals('Active', completed.Status__c);
    System.assertEquals(null, completed.Lease_Token__c);
    System.assertNotEquals(null, completed.Next_Run_At__c);

    Scheduled_Integration_Job__c failure = claimedSchedule('Schedule Failure', 'failure-token');
    insert failure;
    ConnectorExecutionResult failedResult = ConnectorExecutionResult.failed('authorization: Bearer hidden', false, null);
    ConnectorScheduleService.complete(failure.Id, 'failure-token', failedResult);
    Scheduled_Integration_Job__c failed = [
      SELECT Status__c, Last_Error__c, Lease_Token__c FROM Scheduled_Integration_Job__c WHERE Id = :failure.Id
    ];
    System.assertEquals('Failed', failed.Status__c);
    System.assert(!failed.Last_Error__c.contains('hidden'));
    System.assertEquals(null, failed.Lease_Token__c);

    ConnectorScheduleService.complete(null, null, null);
    ConnectorScheduleService.completeSuccess(null, null);
    ConnectorScheduleService.completeFailure(null, null, null);
  }

  @IsTest
  static void staleScheduleProcessorExitsWithoutWork() {
    Scheduled_Integration_Job__c schedule = claimedSchedule('Stale Processor', 'current-token');
    insert schedule;
    new IntegrationScheduleProcessor(schedule.Id, 'stale-token').execute(null);
    System.assertEquals('Claimed', [
      SELECT Status__c FROM Scheduled_Integration_Job__c WHERE Id = :schedule.Id
    ].Status__c);
  }

  @IsTest
  static void validScheduleProcessorRecordsReadinessFailure() {
    Scheduled_Integration_Job__c schedule = claimedSchedule(
      'Missing Operation Processor',
      'valid-token'
    );
    schedule.Source_Object__c = 'OperationThatDoesNotExist';
    insert schedule;
    new IntegrationScheduleProcessor(schedule.Id, 'valid-token').execute(null);
    Scheduled_Integration_Job__c failed = [
      SELECT Status__c, Last_Error__c, Lease_Token__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :schedule.Id
    ];
    System.assertEquals('Failed', failed.Status__c);
    System.assert(String.isNotBlank(failed.Last_Error__c));
    System.assertEquals(null, failed.Lease_Token__c);
  }

  @IsTest
  static void eventApiRejectsMismatchedRecordsAndIgnoresInvalidContexts() {
    Account accountValue = new Account(Name = 'Event API Coverage');
    insert accountValue;
    IntegrationEventApi.dispatch(null, 'afterInsert', new List<SObject>{ accountValue }, null);
    IntegrationEventApi.dispatch('Account', 'beforeInsert', new List<SObject>{ accountValue }, null);
    IntegrationEventApi.dispatch('Account', 'afterInsert', new List<SObject>(), null);

    Product2 productValue = new Product2(Name = 'Mismatched Event API');
    insert productValue;
    try {
      IntegrationEventApi.dispatch(
        'Account',
        'afterInsert',
        new List<SObject>{ productValue },
        null
      );
      System.assert(false, 'Trigger records must match the declared object.');
    } catch (IntegrationEventApi.IntegrationEventException expected) {
      System.assert(expected.getMessage().contains('do not match'));
    }
    try {
      IntegrationEventApi.dispatch(
        'Missing_Object__c',
        'afterInsert',
        new List<SObject>{ accountValue },
        null
      );
      System.assert(false, 'Unsupported objects must fail closed.');
    } catch (IntegrationEventApi.IntegrationEventException expected) {
      System.assert(expected.getMessage().contains('Unsupported'));
    }
  }

  @IsTest
  static void eventApiOnlyQueuesWatchedFieldChanges() {
    // Opt in explicitly; deployed operations default to record-save sync disabled.
    IntegrationEventApi.testOperations = [
      SELECT Connector_Key__c, Operation_Key__c, Salesforce_Object__c, Direction__c,
        External_Entity__c, Salesforce_External_Id_Field__c, Active__c, Run_On_Record_Save__c
      FROM Integration_Operation__mdt WHERE Active__c = true
    ];
    for (Integration_Operation__mdt operation : IntegrationEventApi.testOperations) {
      operation.Run_On_Record_Save__c = true;
    }
    insert new Connector_Instance__c(
      Name = 'QBO Event Policy',
      Connector_Key__c = 'qbo',
      Connector_Label__c = 'QuickBooks Online',
      Active__c = true,
      Named_Credential__c = 'QuickBooks_NC'
    );
    Account original = new Account(Name = 'Watched Event Original');
    insert original;
    delete [
      SELECT Id FROM Integration_Work_Item__c
      WHERE Source_Salesforce_Id__c = :String.valueOf(original.Id)
    ];

    Account unchanged = original.clone(true, true, false, false);
    IntegrationEventApi.dispatch(
      'Account',
      'afterUpdate',
      new List<SObject>{ unchanged },
      new Map<Id, SObject>{ original.Id => original }
    );
    System.assertEquals(0, [
      SELECT COUNT() FROM Integration_Work_Item__c
      WHERE Source_Salesforce_Id__c = :String.valueOf(original.Id)
    ]);

    Account changed = original.clone(true, true, false, false);
    changed.Name = 'Watched Event Changed';
    IntegrationEventApi.dispatch(
      'Account',
      'afterUpdate',
      new List<SObject>{ changed },
      new Map<Id, SObject>{ original.Id => original }
    );
    System.assert([
      SELECT COUNT() FROM Integration_Work_Item__c
      WHERE Source_Salesforce_Id__c = :String.valueOf(original.Id)
    ] > 0);

    IntegrationEventApi.dispatch(
      'Account',
      'afterUpdate',
      new List<SObject>{ changed },
      null
    );
    IntegrationEventApi.dispatch(
      'Account',
      'afterDelete',
      new List<SObject>{ original },
      new Map<Id, SObject>{ original.Id => original }
    );

    System.assertEquals(false, IntegrationEventApi.qualifies(
      changed,
      new Map<Id, SObject>{ original.Id => original },
      'afterUpdate',
      new Set<String>()
    ));
    Set<String> watched = new Set<String>();
    IntegrationEventApi.addWatchedField(watched, null);
    IntegrationEventApi.addWatchedField(watched, 'Parent.Name');
    IntegrationEventApi.addWatchedField(watched, 'Integration_Success__c');
    System.assertEquals(0, watched.size());

    Invoice__c invoiceValue = new Invoice__c();
    insert invoiceValue;
    Invoice_Line__c invoiceLine = new Invoice_Line__c(
      Invoice__c = invoiceValue.Id,
      Quantity__c = 2
    );
    insert invoiceLine;
    System.assert([
      SELECT COUNT()
      FROM Integration_Work_Item__c
      WHERE Source_Salesforce_Id__c = :String.valueOf(invoiceValue.Id)
        AND Operation__c = 'CustomInvoiceUpsert'
    ] > 0, 'A line change must queue its configured parent operation.');
  }

  private static GenericIntegrationRuntime.OperationDefinition definitionFor(String direction) {
    GenericIntegrationRuntime.OperationDefinition definition = new GenericIntegrationRuntime.OperationDefinition();
    definition.connectorKey = 'test-connector';
    definition.operationKey = 'AccountSync';
    definition.direction = direction;
    definition.salesforceObject = 'Account';
    definition.externalEntity = 'Customer';
    definition.namedCredential = 'Test_NC';
    definition.relativeEndpoint = '/customers';
    definition.httpMethod = 'POST';
    definition.persistenceMode = 'None';
    return definition;
  }

  private static Scheduled_Integration_Job__c claimedSchedule(String keyValue, String token) {
    return new Scheduled_Integration_Job__c(
      Logical_Job_Key__c = keyValue,
      Scheduler_Name__c = keyValue,
      Integration_Type__c = 'QuickBooks',
      Source_Object__c = 'CustomerUpsert',
      Direction__c = 'Inbound',
      Frequency_Value__c = 5,
      Frequency_Type__c = 'Minutes',
      Status__c = 'Claimed',
      Lease_Token__c = token,
      Lease_Expires_At__c = System.now().addMinutes(10),
      Next_Run_At__c = System.now().addMinutes(-1)
    );
  }
}