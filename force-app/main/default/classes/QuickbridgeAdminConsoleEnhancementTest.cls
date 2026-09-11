@IsTest
private class QuickbridgeAdminConsoleEnhancementTest {
  private static String createAdminSession() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeAdminSecurity.bypassRateLimitForTests = true;
    return QuickbridgeAdminSecurity.createSession('admin@example.com')
      .sessionToken;
  }

  private static PaymentInvoiceMappingController.MappingRow mapping(
    String sourceField,
    String targetField
  ) {
    PaymentInvoiceMappingController.MappingRow row = new PaymentInvoiceMappingController.MappingRow();
    row.sourceField = sourceField;
    row.targetField = targetField;
    return row;
  }

  private static Scheduled_Integration_Job__c schedule(String keyValue) {
    return new Scheduled_Integration_Job__c(
      Logical_Job_Key__c = keyValue,
      Scheduler_Name__c = keyValue,
      Integration_Type__c = 'QuickBooks',
      Source_Object__c = 'Account',
      Direction__c = 'Inbound',
      Frequency_Value__c = 5,
      Frequency_Type__c = 'Minutes',
      Status__c = 'Ready',
      Next_Run_At__c = System.now().addMinutes(5),
      Created_DateTime__c = System.now()
    );
  }

  @IsTest
  static void manualRunIsCorrelatedAndAggregated() {
    Scheduled_Integration_Job__c job = schedule('observable-run');
    insert job;
    IntegrationRunService.ManualRunRequest requested = IntegrationRunService.requestManualRuns(
      'qbo',
      'QuickBooks'
    );
    System.assertEquals(1, requested.scheduleCount);
    Scheduled_Integration_Job__c queued = [
      SELECT Pending_Run_Key__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :job.Id
    ];
    System.assertNotEquals(null, queued.Pending_Run_Key__c);
    Id runId = IntegrationRunService.startForSchedule(
      job.Id,
      'qbo',
      queued.Pending_Run_Key__c,
      null
    );
    ConnectorExecutionResult execution = ConnectorExecutionResult.success();
    execution.processedCount = 5;
    execution.successfulCount = 4;
    execution.failedCount = 1;
    execution.errorSummary = 'Bearer sensitive-token failed';
    IntegrationRunService.completeForSchedule(job.Id, execution);
    IntegrationRunService.RunGroupSnapshot snapshot = IntegrationRunService.getGroupSnapshot(
      requested.groupKey
    );
    System.assertEquals(IntegrationRunService.STATUS_PARTIAL, snapshot.status);
    System.assertEquals(5, snapshot.processedCount);
    System.assertEquals(4, snapshot.successfulCount);
    System.assertEquals(1, snapshot.failedCount);
    System.assertEquals(
      false,
      [SELECT Message__c FROM Integration_Run__c WHERE Id = :runId]
        .Message__c.contains('sensitive-token')
    );
  }

  @IsTest
  static void duplicateManualRunIsRejectedAndCapacityKeepsQueuedState() {
    insert schedule('duplicate-run');
    IntegrationRunService.ManualRunRequest first = IntegrationRunService.requestManualRuns(
      'qbo',
      'QuickBooks'
    );
    System.assertEquals(
      'Queued',
      [
        SELECT Status__c
        FROM Integration_Run__c
        WHERE Run_Group_Key__c = :first.groupKey
        LIMIT 1
      ]
      .Status__c
    );
    try {
      IntegrationRunService.requestManualRuns('qbo', 'QuickBooks');
      System.assert(false, 'Expected duplicate request rejection.');
    } catch (AuraHandledException expected) {
      System.assert(expected.getMessage().contains('already pending'));
    }
  }

  @IsTest
  static void queuedRunTelemetrySupportsSingleAndBulkTransitions() {
    insert new List<Scheduled_Integration_Job__c>{
      schedule('telemetry-one'),
      schedule('telemetry-two')
    };
    IntegrationRunService.ManualRunRequest requested = IntegrationRunService.requestManualRuns(
      'qbo',
      'QuickBooks'
    );
    List<Integration_Run__c> runs = [
      SELECT Run_Key__c, Scheduled_Job__c
      FROM Integration_Run__c
      WHERE Run_Group_Key__c = :requested.groupKey
      ORDER BY Run_Key__c
    ];
    IntegrationRunService.markQueued(
      runs[0].Scheduled_Job__c,
      runs[0].Run_Key__c,
      UserInfo.getUserId()
    );
    IntegrationRunService.markQueued(
      new Map<String, Id>{ runs[1].Run_Key__c => UserInfo.getUserId() }
    );
    IntegrationRunService.failQueuedRun(
      runs[0].Run_Key__c,
      'Bearer first-secret failed'
    );
    IntegrationRunService.failQueuedRuns(
      new Map<String, String>{
        runs[1].Run_Key__c => 'Bearer second-secret failed'
      }
    );
    IntegrationRunService.RunGroupSnapshot snapshot = IntegrationRunService.getGroupSnapshot(
      requested.groupKey
    );
    System.assertEquals(IntegrationRunService.STATUS_FAILED, snapshot.status);
    System.assertEquals(2, snapshot.failedCount);
    System.assertEquals(false, snapshot.message.contains('secret'));
    System.assertEquals(
      null,
      IntegrationRunService.getGroupSnapshot(null).status
    );
  }

  @IsTest
  static void recurrencePreviewAndErrorSignatureAreSanitized() {
    String sessionToken = createAdminSession();
    Datetime startAt = Datetime.newInstanceGmt(2026, 9, 11, 0, 0, 0);
    QuickbridgeScheduleController.Preview preview = QuickbridgeScheduleController.previewSchedule(
      sessionToken,
      2,
      'Hours',
      startAt
    );
    System.assertEquals(3, preview.nextRuns.size());
    System.assertEquals(startAt.addHours(2), preview.nextRuns[0]);
    String first = IntegrationErrorLogService.signatureFor(
      'qbo',
      'CustomerUpsert',
      'Transport',
      'Bearer abc123 Order 100 failed',
      503
    );
    String second = IntegrationErrorLogService.signatureFor(
      'qbo',
      'CustomerUpsert',
      'Transport',
      'Bearer xyz789 Order 200 failed',
      503
    );
    System.assertEquals(first, second);
    System.assertEquals(64, first.length());
  }

  @IsTest
  static void configControllerRejectsMalformedAndIncompleteRequests() {
    QuickbridgeAdminSecurity.bypassPermissionsForTests = true;
    QuickbridgeConfigController.bypassSecurityForTests = true;
    try {
      QuickbridgeConfigController.getConnectorConfiguration('qbo');
      System.assert(false, 'A missing connector instance must be rejected.');
    } catch (AuraHandledException expected) {
      System.assertNotEquals(null, expected);
    }
    try {
      QuickbridgeConfigController.saveConnectorConfiguration('qbo', '{bad');
      System.assert(false, 'Malformed configuration must be rejected.');
    } catch (AuraHandledException expected) {
      System.assertNotEquals(null, expected);
    }
    try {
      QuickbridgeConfigController.saveConnectorConfiguration(
        'qbo',
        '{"notSupported":"value"}'
      );
      System.assert(false, 'Unknown configuration keys must be rejected.');
    } catch (AuraHandledException expected) {
      System.assertNotEquals(null, expected);
    }
    try {
      QuickbridgeConfigController.replayWorkItem(null);
      System.assert(false, 'A missing work item must be rejected.');
    } catch (AuraHandledException expected) {
      System.assertNotEquals(null, expected);
    }
  }

  @IsTest
  static void paymentEvidenceUsesOnlyValidatedMappedFields() {
    Account customer = new Account(Name = 'Evidence customer');
    insert customer;
    Order sourceOrder = new Order(
      AccountId = customer.Id,
      EffectiveDate = Date.today(),
      Status = 'Draft'
    );
    insert sourceOrder;
    insert new Invoice__c(
      Order__c = sourceOrder.Id,
      Payment_Provider__c = 'stripe',
      Hosted_Payment_URL__c = 'https://payments.example.test/session',
      Status__c = 'Paid'
    );
    insert new Portal_Payment_Transaction__c(
      Order__c = sourceOrder.Id,
      Payment_Type__c = 'Stripe',
      Provider_Event_Key__c = 'stripe:event-one'
    );
    PaymentInvoiceMappingController.GatewayMappingConfig config = new PaymentInvoiceMappingController.GatewayMappingConfig();
    config.gateway = 'stripe';
    config.invoiceObject = 'Invoice__c';
    config.invoiceSourceLookupField = 'Order__c';
    config.transactionObject = 'Portal_Payment_Transaction__c';
    config.transactionSourceLookupField = 'Order__c';
    config.invoiceMappings = new List<PaymentInvoiceMappingController.MappingRow>{
      mapping('paymentProvider', 'Payment_Provider__c'),
      mapping('hostedPaymentUrl', 'Hosted_Payment_URL__c'),
      mapping('status', 'Status__c')
    };
    config.transactionMappings = new List<PaymentInvoiceMappingController.MappingRow>{
      mapping('providerEventKey', 'Provider_Event_Key__c')
    };
    PaymentOperationalEvidenceService.testConfigOverride = config;
    PaymentOperationalEvidenceService.Evidence evidence = PaymentOperationalEvidenceService.inspect(
      'stripe'
    );
    System.assertEquals(true, evidence.hostedPaymentObserved);
    System.assertEquals(true, evidence.webhookObserved);
    System.assertEquals(true, evidence.exactlyOneTransactionObserved);
    System.assertEquals(true, evidence.paidInvoiceObserved);
    System.assert(evidence.message.contains('evidence were observed'));

    config.invoiceMappings[0].targetField = 'Missing_Field__c';
    PaymentOperationalEvidenceService.Evidence invalid = PaymentOperationalEvidenceService.inspect(
      'stripe'
    );
    System.assert(invalid.message.contains('unavailable'));
  }

  @IsTest
  static void triageGroupsSanitizesPaginatesAndRejectsTerminalRetry() {
    String sessionToken = createAdminSession();
    String signature = IntegrationErrorLogService.signatureFor(
      'qbo',
      'CustomerUpsert',
      'Authentication',
      'Bearer secret-value failed',
      401
    );
    insert new List<Error_Log__c>{
      new Error_Log__c(
        Connector_Key__c = 'qbo',
        Operation_Key__c = 'CustomerUpsert',
        Error_Signature__c = signature,
        Error_Category__c = 'Authentication',
        Error_Message__c = 'Bearer secret-value failed',
        Is_Retryable__c = false,
        Retry_Status__c = 'Failed',
        Retry_Count__c = 1,
        Http_Status_Code__c = 401,
        Source_Object__c = 'Account',
        Source_Record_Id__c = 'not-an-id'
      ),
      new Error_Log__c(
        Connector_Key__c = 'qbo',
        Operation_Key__c = 'CustomerUpsert',
        Error_Signature__c = signature,
        Error_Category__c = 'Authentication',
        Error_Message__c = 'Bearer another-secret failed',
        Is_Retryable__c = false,
        Retry_Status__c = 'Failed',
        Retry_Count__c = 2,
        Http_Status_Code__c = 401,
        Source_Object__c = 'Account',
        Source_Record_Id__c = 'not-an-id'
      )
    };
    QuickbridgeErrorTriageController.TriagePage grouped = QuickbridgeErrorTriageController.getPage(
      sessionToken,
      'qbo',
      '{"category":"Authentication","sourceObject":"Account","retryStatus":"Failed"}',
      null,
      10,
      'All'
    );
    System.assertEquals(1, grouped.rows.size());
    System.assertEquals(2, grouped.rows[0].occurrenceCount);
    System.assertEquals('settings', grouped.rows[0].routeScreen);
    System.assertEquals(null, grouped.rows[0].recordUrl);
    System.assertEquals(
      false,
      grouped.rows[0].message.contains('secret-value')
    );

    QuickbridgeErrorTriageController.TriagePage firstPage = QuickbridgeErrorTriageController.getPage(
      sessionToken,
      'qbo',
      null,
      null,
      1,
      'Pending'
    );
    System.assertNotEquals(null, firstPage.nextCursor);
    QuickbridgeErrorTriageController.TriagePage secondPage = QuickbridgeErrorTriageController.getPage(
      sessionToken,
      'qbo',
      null,
      firstPage.nextCursor,
      1,
      'Pending'
    );
    System.assertEquals(1, secondPage.rows.size());
    List<QuickbridgeErrorTriageController.RetryResult> retryResults = QuickbridgeErrorTriageController.retry(
      sessionToken,
      new List<Id>{ grouped.rows[0].id }
    );
    System.assertEquals(false, retryResults[0].successful);
    System.assert(retryResults[0].message.contains('terminal'));
  }

  @IsTest
  static void triageBulkRetryReturnsPerRecordResults() {
    String sessionToken = createAdminSession();
    Integration_Work_Item__c work = new Integration_Work_Item__c(
      Unique_Key__c = 'qbo:CustomerUpsert:retry-one',
      Integration__c = 'qbo',
      Operation__c = 'CustomerUpsert',
      Status__c = 'Failed',
      Source_Object__c = 'Account',
      Source_Record_Id__c = 'record-one',
      Last_Error__c = 'safe failure'
    );
    insert work;
    List<Error_Log__c> errors = new List<Error_Log__c>{
      new Error_Log__c(
        Connector_Key__c = 'qbo',
        Operation_Key__c = 'CustomerUpsert',
        Error_Category__c = 'Mapping',
        Error_Message__c = 'retry this',
        Is_Retryable__c = true,
        Retry_Status__c = 'Pending',
        Source_Object__c = 'Account',
        Source_Record_Id__c = 'record-one'
      ),
      new Error_Log__c(
        Connector_Key__c = 'qbo',
        Operation_Key__c = 'CustomerUpsert',
        Error_Category__c = 'Mapping',
        Error_Message__c = 'missing work',
        Is_Retryable__c = true,
        Retry_Status__c = 'Pending',
        Source_Object__c = 'Account',
        Source_Record_Id__c = 'record-two'
      )
    };
    insert errors;
    QuickbridgeErrorTriageController.bypassReadinessForTests = true;
    List<QuickbridgeErrorTriageController.RetryResult> results = QuickbridgeErrorTriageController.retry(
      sessionToken,
      new List<Id>{ errors[0].Id, errors[1].Id }
    );
    System.assertEquals(2, results.size());
    System.assertEquals(true, results[0].successful);
    System.assertEquals(false, results[1].successful);
    System.assert(results[1].message.contains('could not be found'));
    System.assertEquals(
      IntegrationWorkService.STATUS_PENDING,
      [SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :work.Id]
      .Status__c
    );
  }

  @IsTest
  static void scheduledCapabilityExecutionPersistsRunningTelemetry() {
    Integration_Operation__mdt operation = [
      SELECT Salesforce_Object__c, Direction__c
      FROM Integration_Operation__mdt
      WHERE Connector_Key__c = 'meta' AND Active__c = TRUE
      LIMIT 1
    ];
    Scheduled_Integration_Job__c job = new Scheduled_Integration_Job__c(
      Logical_Job_Key__c = 'meta-scheduled-telemetry',
      Scheduler_Name__c = 'Meta scheduled telemetry',
      Integration_Type__c = 'Meta',
      Source_Object__c = operation.Salesforce_Object__c,
      Direction__c = operation.Direction__c,
      Frequency_Value__c = 5,
      Frequency_Type__c = 'Minutes',
      Status__c = 'Claimed',
      Lease_Token__c = 'meta-lease',
      Lease_Expires_At__c = System.now().addMinutes(5),
      Next_Run_At__c = System.now(),
      Created_DateTime__c = System.now()
    );
    insert job;
    ConnectorCapabilityRouter.registerTestAdapter(
      'meta',
      'scheduler.operation',
      'MetaScheduledOperationAdapter'
    );
    new IntegrationScheduleProcessor(job.Id, 'meta-lease').execute(null);
    ConnectorCapabilityRouter.clearTestAdapters();
    Scheduled_Integration_Job__c running = [
      SELECT Status__c, Processor_Job_Id__c
      FROM Scheduled_Integration_Job__c
      WHERE Id = :job.Id
    ];
    System.assertEquals('Running', running.Status__c);
    System.assertNotEquals(null, running.Processor_Job_Id__c);
    System.assertEquals(
      IntegrationRunService.STATUS_RUNNING,
      [
        SELECT Status__c
        FROM Integration_Run__c
        WHERE Scheduled_Job__c = :job.Id
        LIMIT 1
      ]
      .Status__c
    );
  }

  @IsTest
  static void historicalErrorBackfillAddsExactContextAndSignature() {
    Error_Log__c historical = new Error_Log__c(
      External_Reference__c = 'inbound:qbo:CustomerUpsert:legacy',
      Error_Category__c = 'Mapping',
      Error_Message__c = 'legacy mapping failed',
      Is_Retryable__c = true,
      Retry_Status__c = 'Pending'
    );
    insert historical;
    Test.startTest();
    Database.executeBatch(new ErrorLogContextBackfillBatch(), 50);
    Test.stopTest();
    historical = [
      SELECT Connector_Key__c, Operation_Key__c, Error_Signature__c
      FROM Error_Log__c
      WHERE Id = :historical.Id
    ];
    System.assertEquals('qbo', historical.Connector_Key__c);
    System.assertEquals('CustomerUpsert', historical.Operation_Key__c);
    System.assertEquals(64, historical.Error_Signature__c.length());
  }
}