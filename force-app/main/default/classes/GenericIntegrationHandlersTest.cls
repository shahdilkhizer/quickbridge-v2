@IsTest
private class GenericIntegrationHandlersTest {
  private class CapturingTransport implements ConnectorHttpClient.Transport {
    public String endpoint;
    public String method;
    public String body;
    private Integer statusCode;
    private String responseBody;
    private String retryAfter;

    CapturingTransport(Integer statusValue, String bodyValue, String retryAfterValue) {
      statusCode = statusValue;
      responseBody = bodyValue;
      retryAfter = retryAfterValue;
    }

    public HttpResponse send(HttpRequest request) {
      endpoint = request.getEndpoint();
      method = request.getMethod();
      body = request.getBody();
      HttpResponse response = new HttpResponse();
      response.setStatusCode(statusCode);
      response.setStatus(statusCode >= 200 && statusCode < 300 ? 'OK' : 'Error');
      if (responseBody != null) {
        response.setBody(responseBody);
      }
      if (retryAfter != null) {
        response.setHeader('Retry-After', retryAfter);
      }
      return response;
    }
  }

  private class ThrowingTransport implements ConnectorHttpClient.Transport {
    public HttpResponse send(HttpRequest request) {
      throw new CalloutException('Read timed out');
    }
  }

  @IsTest
  static void inboundHandlerUsesConfiguredMappingsAndPersistsRows() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
    definition.httpMethod = 'GET';
    GenericIntegrationRuntime.registerTestDefinition(definition);
    CapturingTransport transport = new CapturingTransport(
      200,
      '{"data":[{"id":"remote-1","name":"Configured Inbound Account"}]}',
      null
    );
    ConnectorHttpClient.setTestTransport(transport);

    try {
      ConnectorExecutionRequest request = requestFor('Inbound');
      InboundIntegrationHandler handler = new InboundIntegrationHandler(request);
      handler.start(null);
      handler.execute(null, new List<Integer>{ 1 });

      List<Account> accounts = [
        SELECT Id, Name
        FROM Account
        WHERE Name = 'Configured Inbound Account'
      ];
      System.assertEquals(1, accounts.size());
      System.assertEquals('callout:Test_App/v1/contacts?source=unit', transport.endpoint);
      System.assertEquals('GET', transport.method);
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void outboundHandlerBuildsConfiguredRequestAndMapsResponse() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.registerTestDefinition(baseDefinition());
    Account source = new Account(Name = 'Configured Outbound Account');
    insert source;

    CapturingTransport transport = new CapturingTransport(
      200,
      '{"id":"remote-2"}',
      null
    );
    ConnectorHttpClient.setTestTransport(transport);

    try {
      ConnectorExecutionRequest request = requestFor('Outbound');
      request.recordIds = new List<Id>{ source.Id };
      OutboundIntegrationHandler handler = new OutboundIntegrationHandler(request);
      handler.execute(null, new List<SObject>{ source });

      System.assertEquals('callout:Test_App/v1/contacts?source=unit', transport.endpoint);
      System.assertEquals('POST', transport.method);
      Map<String, Object> sentBody = (Map<String, Object>) JSON.deserializeUntyped(
        transport.body
      );
      System.assertEquals('Configured Outbound Account', sentBody.get('name'));

      Account updated = [SELECT Website FROM Account WHERE Id = :source.Id];
      System.assertEquals('remote-2', updated.Website);
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void configurationRejectsUnsafeTransformsAndEndpoints() {
    GenericIntegrationRuntime.OperationDefinition unsafeTransform = baseDefinition();
    unsafeTransform.mappings[0].transform = 'Apex.ClassName';
    assertDefinitionRejected(unsafeTransform, 'transform');

    GenericIntegrationRuntime.OperationDefinition unsafeEndpoint = baseDefinition();
    unsafeEndpoint.relativeEndpoint = 'https://attacker.example/v1/contacts';
    assertDefinitionRejected(unsafeEndpoint, 'endpoint');

    GenericIntegrationRuntime.OperationDefinition unsafePages = baseDefinition();
    unsafePages.maximumPages = ConnectorHttpClient.ABSOLUTE_MAX_PAGES + 1;
    assertDefinitionRejected(unsafePages, 'pages');
  }

  @IsTest
  static void inboundEventUsesIdempotencyPathAndIgnoresDuplicate() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
    definition.persistenceMode = 'None';
    definition.salesforceObject = null;
    definition.inboundIdempotencyPath = 'event_id';
    definition.operationKey = 'idempotentEvent';
    definition.mappings = new List<GenericIntegrationRuntime.MappingRule>();
    GenericIntegrationRuntime.registerTestDefinition(definition);

    try {
      InboundIntegrationHandler.EventResponse first = InboundIntegrationHandler.receiveEvent(
        'generic-test',
        'idempotentEvent',
        '{"event_id":"evt-1","value":"one"}',
        new Map<String, String>()
      );
      InboundIntegrationHandler.EventResponse second = InboundIntegrationHandler.receiveEvent(
        'generic-test',
        'idempotentEvent',
        '{"event_id":"evt-1","value":"one"}',
        new Map<String, String>()
      );

      System.assertEquals(200, first.statusCode);
      System.assertEquals(200, second.statusCode);
      System.assertEquals('Duplicate event ignored.', second.message);
      System.assertEquals('generic-test:idempotentEvent:evt-1', second.idempotencyKey);
    } finally {
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void inboundEventRejectsInvalidSignatureConfiguration() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
    definition.operationKey = 'signedEvent';
    definition.persistenceMode = 'None';
    definition.salesforceObject = null;
    definition.mappings = new List<GenericIntegrationRuntime.MappingRule>();
    definition.inboundSignatureHeader = 'X-Signature';
    definition.inboundSignatureAlgorithm = 'HMACSHA256';
    definition.inboundSecretKey = 'MissingSecret';
    definition.inboundMaxAgeSeconds = 300;
    GenericIntegrationRuntime.registerTestDefinition(definition);

    try {
      InboundIntegrationHandler.EventResponse response = InboundIntegrationHandler.receiveEvent(
        'generic-test',
        'signedEvent',
        '{"event_id":"evt-2"}',
        new Map<String, String>()
      );
      System.assertEquals(401, response.statusCode);
      System.assert(String.isNotBlank(response.message));
    } finally {
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void outboundHandlerSupportsBatchStartCollectionAndFinish() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
    definition.direction = 'Outbound';
    definition.requestCardinality = 'Collection';
    GenericIntegrationRuntime.registerTestDefinition(definition);
    List<Account> accounts = new List<Account>{
      new Account(Name = 'Collection Account One'),
      new Account(Name = 'Collection Account Two')
    };
    insert accounts;

    CapturingTransport transport = new CapturingTransport(
      200,
      '{"id":"collection-1"}',
      null
    );
    ConnectorHttpClient.setTestTransport(transport);
    try {
      ConnectorExecutionRequest request = requestFor('Outbound');
      request.recordIds = new List<Id>{ accounts[0].Id, accounts[1].Id };
      OutboundIntegrationHandler handler = new OutboundIntegrationHandler(request);
      System.assertNotEquals(null, handler.start(null));
      handler.execute(null, new List<SObject>{ accounts[0], accounts[1] });
      handler.finish(null);

      List<Object> sentBody = (List<Object>) JSON.deserializeUntyped(transport.body);
      System.assertEquals(2, sentBody.size());
      System.assertEquals('POST', transport.method);
      List<Account> updated = [
        SELECT Website
        FROM Account
        WHERE Id IN :request.recordIds
      ];
      System.assertEquals(2, updated.size());
      for (Account accountValue : updated) {
        System.assertEquals('collection-1', accountValue.Website);
      }
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void outboundHandlerSupportsBinaryAndRetryableResponses() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition binaryDefinition = baseDefinition();
    binaryDefinition.direction = 'Outbound';
    binaryDefinition.responseContentType = 'Binary';
    GenericIntegrationRuntime.registerTestDefinition(binaryDefinition);
    Account source = new Account(Name = 'Binary Outbound Account');
    insert source;

    CapturingTransport binaryTransport = new CapturingTransport(200, 'AA==', null);
    ConnectorHttpClient.setTestTransport(binaryTransport);
    try {
      ConnectorExecutionRequest request = requestFor('Outbound');
      request.recordIds = new List<Id>{ source.Id };
      new OutboundIntegrationHandler(request).execute(
        null,
        new List<SObject>{ source }
      );
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }

    GenericIntegrationRuntime.OperationDefinition retryDefinition = baseDefinition();
    retryDefinition.direction = 'Outbound';
    GenericIntegrationRuntime.registerTestDefinition(retryDefinition);
    ConnectorHttpClient.setTestTransport(new CapturingTransport(429, '{"error":"busy"}', '7'));
    try {
      ConnectorExecutionRequest request = requestFor('Outbound');
      request.recordIds = new List<Id>{ source.Id };
      new OutboundIntegrationHandler(request).execute(
        null,
        new List<SObject>{ source }
      );
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void inboundHandlerSupportsBinaryResponsesAndCompletion() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
    definition.direction = 'Inbound';
    definition.httpMethod = 'GET';
    definition.responseContentType = 'Binary';
    GenericIntegrationRuntime.registerTestDefinition(definition);
    ConnectorHttpClient.setTestTransport(new CapturingTransport(200, 'AA==', null));
    try {
      ConnectorExecutionRequest request = requestFor('Inbound');
      InboundIntegrationHandler handler = new InboundIntegrationHandler(request);
      handler.start(null);
      handler.execute(null, new List<Integer>{ 1 });
      handler.finish(null);
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void runtimeBuildsTemplatesAndTypedMappings() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition templateDefinition = baseDefinition();
    templateDefinition.direction = 'Outbound';
    templateDefinition.requestTemplate = '{"name":"{{Name}}","constant":"yes"}';
    templateDefinition.queryParamsJson = '{"source":"unit"}';
    templateDefinition.cursorQueryParam = 'cursor';
    templateDefinition.pageQueryParam = 'page';
    GenericIntegrationRuntime.MappingRule booleanOutbound = mapping(
      'Outbound',
      'Account',
      'AccountNumber',
      'active',
      false
    );
    booleanOutbound.transform = 'Boolean';
    booleanOutbound.defaultValue = 'true';
    templateDefinition.mappings.add(booleanOutbound);
    GenericIntegrationRuntime.registerTestDefinition(templateDefinition);
    Account source = new Account(Name = 'Template Account');
    insert source;

    try {
      ConnectorExecutionRequest request = requestFor('Outbound');
      request.cursor = 'next-1';
      request.pageNumber = 2;
      String body = GenericIntegrationRuntime.buildRequestBody(
        templateDefinition,
        new List<SObject>{ source },
        request
      );
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
      System.assertEquals('Template Account', parsed.get('name'));
      templateDefinition.requestTemplate = null;
      Map<String, Object> mappedBody = (Map<String, Object>) JSON.deserializeUntyped(
        GenericIntegrationRuntime.buildRequestBody(
          templateDefinition,
          new List<SObject>{ source },
          request
        )
      );
      System.assertEquals(true, mappedBody.get('active'));
      System.assertEquals('next-1', GenericIntegrationRuntime.queryParametersFor(
        templateDefinition,
        request
      ).get('cursor'));
      System.assertEquals('2', GenericIntegrationRuntime.queryParametersFor(
        templateDefinition,
        request
      ).get('page'));
      System.assertEquals(
        '/v1/contacts?cursor=next-1&page=2&source=unit',
        ConnectorHttpClient.appendQuery(
          templateDefinition.relativeEndpoint,
          GenericIntegrationRuntime.queryParametersFor(templateDefinition, request)
        )
      );
    } finally {
      GenericIntegrationRuntime.clearTestDefinitions();
    }

    GenericIntegrationRuntime.OperationDefinition typedDefinition = baseDefinition();
    typedDefinition.direction = 'Inbound';
    typedDefinition.httpMethod = 'GET';
    typedDefinition.mappings = new List<GenericIntegrationRuntime.MappingRule>();
    GenericIntegrationRuntime.MappingRule nameMapping = mapping(
      'Inbound',
      'Account',
      'Name',
      'name',
      true
    );
    GenericIntegrationRuntime.MappingRule revenueMapping = mapping(
      'Inbound',
      'Account',
      'AnnualRevenue',
      'revenue',
      false
    );
    revenueMapping.transform = 'Decimal';
    GenericIntegrationRuntime.MappingRule employeesMapping = mapping(
      'Inbound',
      'Account',
      'NumberOfEmployees',
      'employees',
      false
    );
    employeesMapping.transform = 'Integer';
    typedDefinition.mappings.add(nameMapping);
    typedDefinition.mappings.add(revenueMapping);
    typedDefinition.mappings.add(employeesMapping);
    GenericIntegrationRuntime.registerTestDefinition(typedDefinition);
    try {
      ConnectorExecutionResult result = GenericIntegrationRuntime.persistInbound(
        typedDefinition,
        '{"data":[{"name":"Typed Account","revenue":"12.50","employees":"7","partner":"true"}]}'
      );
      System.assertEquals(1, result.successfulCount);
      Account typed = [
        SELECT Name, AnnualRevenue, NumberOfEmployees
        FROM Account
        WHERE Name = 'Typed Account'
        LIMIT 1
      ];
      System.assertEquals(12.50, typed.AnnualRevenue);
      System.assertEquals(7, typed.NumberOfEmployees);
    } finally {
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void runtimeHandlesDmlPaginationRetryAndValidationEdges() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
    definition.direction = 'Bidirectional';
    definition.cursorQueryParam = 'cursor';
    definition.pageQueryParam = 'page';
    definition.sinceQueryParam = 'since';
    GenericIntegrationRuntime.registerTestDefinition(definition);
    try {
      ConnectorExecutionRequest request = requestFor('Outbound');
      request.recordIds = new List<Id>();
      try {
        GenericIntegrationRuntime.buildSourceQuery(definition, request);
        System.assert(false, 'Outbound queries must be bounded by explicit IDs.');
      } catch (GenericIntegrationRuntime.GenericIntegrationRuntimeException expected) {
        System.assert(expected.getMessage().contains('explicit record IDs'));
      }

      request.scopeSize = 0;
      assertRequestLimitRejected(request, 'Scope size');
      request.scopeSize = 50;
      request.pageNumber = 0;
      assertRequestLimitRejected(request, 'Page number');
      request.pageNumber = 1;
      request.retryAttempt = 6;
      assertRequestLimitRejected(request, 'Retry attempt');
      request.retryAttempt = 0;
      request.cursor = ''.leftPad(4001, 'x');
      assertRequestLimitRejected(request, 'Cursor');

      request.cursor = 'next-page';
      request.sinceValue = Datetime.newInstanceGmt(2026, 1, 2, 3, 4, 5);
      Map<String, String> parameters = GenericIntegrationRuntime.queryParametersFor(
        definition,
        request
      );
      System.assertEquals('next-page', parameters.get('cursor'));
      System.assertEquals('1', parameters.get('page'));
      System.assert(parameters.get('since').startsWith('2026-01-02T03:04:05'));

      Map<String, String> headers = GenericIntegrationRuntime.headersFor(definition);
      System.assertEquals('application/json', headers.get('Accept'));
      System.assertEquals('application/json', headers.get('Content-Type'));
      System.assertEquals(1, GenericIntegrationRuntime.responseRows(
        definition,
        '{"data":{"id":"single"}}'
      ).size());
      System.assertEquals('value', GenericIntegrationRuntime.valueAtPath(
        JSON.deserializeUntyped('{"outer":{"inner":"value"}}'),
        'outer.inner'
      ));

      ConnectorExecutionResult malformedRows = GenericIntegrationRuntime.persistInbound(
        definition,
        '{"data":["not-an-object"]}'
      );
      System.assertEquals(1, malformedRows.failedCount);

      GenericIntegrationRuntime.OperationDefinition noneDefinition = baseDefinition();
      noneDefinition.persistenceMode = 'None';
      System.assertEquals(0, GenericIntegrationRuntime.persistInbound(
        noneDefinition,
        '{"data":[{"name":"Ignored"}]}'
      ).processedCount);

      Account requiredAccount = new Account(Name = 'DML Failure Coverage');
      insert requiredAccount;
      GenericIntegrationRuntime.OperationDefinition failingUpdate = baseDefinition();
      failingUpdate.mappings = new List<GenericIntegrationRuntime.MappingRule>();
      GenericIntegrationRuntime.MappingRule responseName = mapping(
        'Response',
        'Account',
        'Name',
        'name',
        false
      );
      responseName.nullBehavior = 'Include';
      failingUpdate.mappings.add(responseName);
      failingUpdate.responseIdPath = null;
      ConnectorExecutionResult failedUpdate = GenericIntegrationRuntime.persistOutboundResponses(
        failingUpdate,
        new List<SObject>{ requiredAccount },
        new List<String>{ '{"name":null}' }
      );
      System.assertEquals(1, failedUpdate.failedCount);
      System.assertEquals('UPDATE', failedUpdate.dmlOperation);
      System.assertEquals(requiredAccount.Id, failedUpdate.retryRecordIds[0]);

      ConnectorHttpClient.setTestTransport(new CapturingTransport(
        200,
        '{"paging":{"next":"cursor-2"}}',
        null
      ));
      ConnectorHttpClient.RequestSpec responseSpec = new ConnectorHttpClient.RequestSpec();
      responseSpec.namedCredential = 'Test_App';
      responseSpec.relativeEndpoint = '/v1/contacts';
      ConnectorHttpClient.Response response = ConnectorHttpClient.send(responseSpec);
      definition.paginationType = 'Cursor';
      definition.nextPath = 'paging.next';
      System.assertEquals('cursor-2', GenericIntegrationRuntime.nextCursor(
        definition,
        response,
        request,
        1
      ));
      definition.paginationType = 'Offset';
      definition.pageSize = 2;
      request.cursor = '4';
      System.assertEquals('6', GenericIntegrationRuntime.nextCursor(
        definition,
        response,
        request,
        2
      ));
      System.assertEquals(null, GenericIntegrationRuntime.nextCursor(
        definition,
        response,
        request,
        1
      ));

      definition.retryStatuses = '408,429,503';
      System.assertEquals(true, GenericIntegrationRuntime.isRetryable(definition, 429));
      System.assertEquals(false, GenericIntegrationRuntime.isRetryable(definition, 500));
      definition.retryStatuses = 'bad';
      try {
        GenericIntegrationRuntime.isRetryable(definition, 500);
        System.assert(false, 'Malformed retry statuses must fail readiness.');
      } catch (GenericIntegrationRuntime.GenericIntegrationRuntimeException expected) {
        System.assert(expected.getMessage().contains('Retry status'));
      }
      definition.retryStatuses = null;
      definition.retryDelaySeconds = 999999;
      System.assertEquals(86400, GenericIntegrationRuntime.retryDelaySeconds(definition, null));
      try {
        GenericIntegrationRuntime.validateInboundEvent(definition, null, null);
        System.assert(false, 'Blank webhook payloads must fail.');
      } catch (GenericIntegrationRuntime.GenericIntegrationRuntimeException expected) {
        System.assert(expected.getMessage().contains('payload'));
      }
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void handlersCoverTerminalRetryPaginationAndCalloutFailures() {
    GenericIntegrationRuntime.clearTestDefinitions();
    Account source = new Account(Name = 'Handler Branch Account');
    insert source;
    try {
      OutboundIntegrationHandler missingOutbound = new OutboundIntegrationHandler(null);
      System.assertNotEquals(null, missingOutbound.start(null));
      missingOutbound.execute(null, new List<SObject>{ source });
      missingOutbound.finish(null);

      ConnectorExecutionRequest oversizedRequest = requestFor('Outbound');
      GenericIntegrationRuntime.OperationDefinition outboundDefinition = baseDefinition();
      outboundDefinition.direction = 'Outbound';
      GenericIntegrationRuntime.registerTestDefinition(outboundDefinition);
      List<SObject> oversizedScope = new List<SObject>();
      for (Integer indexValue = 0; indexValue < 101; indexValue++) {
        oversizedScope.add(new Account(Name = 'Oversized ' + indexValue));
      }
      OutboundIntegrationHandler oversized = new OutboundIntegrationHandler(oversizedRequest);
      oversized.execute(null, oversizedScope);
      oversized.finish(null);

      ConnectorHttpClient.setTestTransport(new ThrowingTransport());
      oversizedRequest.recordIds = new List<Id>{ source.Id };
      oversizedRequest.retryAttempt = 5;
      OutboundIntegrationHandler throwing = new OutboundIntegrationHandler(oversizedRequest);
      throwing.execute(null, new List<SObject>{ source });
      throwing.finish(null);
      ConnectorHttpClient.clearTestTransport();

      ConnectorHttpClient.setTestTransport(new CapturingTransport(400, '{"error":"invalid"}', null));
      OutboundIntegrationHandler permanent = new OutboundIntegrationHandler(oversizedRequest);
      permanent.execute(null, new List<SObject>{ source });
      permanent.finish(null);
      ConnectorHttpClient.clearTestTransport();

      GenericIntegrationRuntime.clearTestDefinitions();
      GenericIntegrationRuntime.OperationDefinition inboundDefinition = baseDefinition();
      inboundDefinition.direction = 'Inbound';
      inboundDefinition.httpMethod = 'GET';
      inboundDefinition.paginationType = 'Cursor';
      inboundDefinition.nextPath = 'paging.next';
      inboundDefinition.maximumPages = 1;
      GenericIntegrationRuntime.registerTestDefinition(inboundDefinition);
      ConnectorExecutionRequest inboundRequest = requestFor('Inbound');
      ConnectorHttpClient.setTestTransport(new CapturingTransport(
        200,
        '{"data":[{"name":"Page Limit Account"}],"paging":{"next":"again"}}',
        null
      ));
      InboundIntegrationHandler pageLimit = new InboundIntegrationHandler(inboundRequest);
      pageLimit.start(null);
      pageLimit.execute(null, new List<Integer>{ 1 });
      pageLimit.finish(null);

      ConnectorHttpClient.setTestTransport(new CapturingTransport(429, '{"error":"busy"}', '5'));
      inboundRequest.retryAttempt = 5;
      InboundIntegrationHandler retryExhausted = new InboundIntegrationHandler(inboundRequest);
      retryExhausted.start(null);
      retryExhausted.execute(null, new List<Integer>{ 1 });
      retryExhausted.finish(null);

      InboundIntegrationHandler missingInbound = new InboundIntegrationHandler(null);
      System.assertEquals(0, ((List<Integer>) missingInbound.start(null)).size());
      missingInbound.execute(null, new List<Integer>{ 1 });
      missingInbound.finish(null);

      InboundIntegrationHandler.EventResponse missingId = InboundIntegrationHandler.receiveEvent(
        'generic-test',
        'contactSync',
        '{"name":"missing id"}',
        new Map<String, String>()
      );
      System.assertEquals(200, missingId.statusCode);
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void handlersScheduleBoundedRetriesAndNextInboundPage() {
    GenericIntegrationRuntime.clearTestDefinitions();
    Account source = new Account(Name = 'Async Handoff Account');
    insert source;
    try {
      GenericIntegrationRuntime.OperationDefinition outboundDefinition = baseDefinition();
      outboundDefinition.direction = 'Outbound';
      GenericIntegrationRuntime.registerTestDefinition(outboundDefinition);
      ConnectorExecutionRequest outboundRequest = requestFor('Outbound');
      outboundRequest.recordIds = new List<Id>{ source.Id };
      outboundRequest.retryAttempt = 0;
      outboundRequest.scopeSize = 500;
      ConnectorHttpClient.setTestTransport(new CapturingTransport(
        429,
        '{"error":"busy"}',
        '61'
      ));
      OutboundIntegrationHandler outboundRetry = new OutboundIntegrationHandler(
        outboundRequest
      );
      outboundRetry.execute(null, new List<SObject>{ source });
      outboundRetry.finish(null);

      Scheduled_Integration_Job__c outboundSchedule = claimedSchedule(
        'Outbound Lease Rejected',
        'current-outbound-token',
        'Out'
      );
      insert outboundSchedule;
      outboundRequest.scheduleId = outboundSchedule.Id;
      outboundRequest.leaseToken = 'stale-outbound-token';
      System.assertNotEquals(null, new OutboundIntegrationHandler(outboundRequest).start(null));

      GenericIntegrationRuntime.clearTestDefinitions();
      GenericIntegrationRuntime.OperationDefinition inboundDefinition = baseDefinition();
      inboundDefinition.direction = 'Inbound';
      inboundDefinition.httpMethod = 'GET';
      inboundDefinition.paginationType = 'Cursor';
      inboundDefinition.nextPath = 'paging.next';
      inboundDefinition.maximumPages = 3;
      GenericIntegrationRuntime.registerTestDefinition(inboundDefinition);
      ConnectorExecutionRequest inboundRequest = requestFor('Inbound');
      ConnectorHttpClient.setTestTransport(new CapturingTransport(
        200,
        '{"data":[{"name":"Async Next Page"}],"paging":{"next":"cursor-next"}}',
        null
      ));
      InboundIntegrationHandler inboundPage = new InboundIntegrationHandler(inboundRequest);
      inboundPage.start(null);
      inboundPage.execute(null, new List<Integer>{ 1 });
      inboundPage.finish(null);

      ConnectorHttpClient.setTestTransport(new CapturingTransport(
        429,
        '{"error":"busy"}',
        '61'
      ));
      inboundRequest.retryAttempt = 0;
      InboundIntegrationHandler inboundRetry = new InboundIntegrationHandler(inboundRequest);
      inboundRetry.start(null);
      inboundRetry.execute(null, new List<Integer>{ 1 });
      inboundRetry.finish(null);

      Scheduled_Integration_Job__c inboundSchedule = claimedSchedule(
        'Inbound Lease Rejected',
        'current-inbound-token',
        'In'
      );
      insert inboundSchedule;
      inboundRequest.scheduleId = inboundSchedule.Id;
      inboundRequest.leaseToken = 'stale-inbound-token';
      System.assertEquals(
        0,
        ((List<Integer>) new InboundIntegrationHandler(inboundRequest).start(null)).size()
      );
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void handlersCompleteWorkItemsAndRejectMissingWebhookIdentity() {
    GenericIntegrationRuntime.clearTestDefinitions();
    Account source = new Account(Name = 'Work Item Handler Account');
    insert source;
    IntegrationWorkRequest workRequest = new IntegrationWorkRequest();
    workRequest.connectorKey = 'generic-test';
    workRequest.operationKey = 'contactSync';
    workRequest.sourceObject = 'Account';
    workRequest.sourceRecordId = source.Id;
    Id workItemId = IntegrationWorkService.enqueue(
      new List<IntegrationWorkRequest>{ workRequest }
    )[0];
    try {
      GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
      definition.direction = 'Outbound';
      GenericIntegrationRuntime.registerTestDefinition(definition);
      ConnectorExecutionRequest request = requestFor('Outbound');
      request.recordIds = new List<Id>{ source.Id };
      request.workItemId = workItemId;
      ConnectorHttpClient.setTestTransport(new CapturingTransport(
        400,
        '{"error":"invalid"}',
        null
      ));
      OutboundIntegrationHandler handler = new OutboundIntegrationHandler(request);
      handler.execute(null, new List<SObject>{ source });
      handler.finish(null);
      System.assertEquals('Failed', [
        SELECT Status__c FROM Integration_Work_Item__c WHERE Id = :workItemId
      ].Status__c);

      GenericIntegrationRuntime.clearTestDefinitions();
      GenericIntegrationRuntime.OperationDefinition webhook = baseDefinition();
      webhook.direction = 'Inbound';
      webhook.operationKey = 'identityRequired';
      webhook.persistenceMode = 'None';
      webhook.salesforceObject = null;
      webhook.mappings = new List<GenericIntegrationRuntime.MappingRule>();
      webhook.inboundIdempotencyPath = 'event.id';
      GenericIntegrationRuntime.registerTestDefinition(webhook);
      InboundIntegrationHandler.EventResponse rejected =
        InboundIntegrationHandler.receiveEvent(
          'generic-test',
          'identityRequired',
          '{"event":{}}',
          new Map<String, String>()
        );
      System.assertEquals(500, rejected.statusCode);
      System.assert(rejected.result.hasFailures());
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  @IsTest
  static void inboundHandlerRejectsRepeatedCursor() {
    GenericIntegrationRuntime.clearTestDefinitions();
    GenericIntegrationRuntime.OperationDefinition definition = baseDefinition();
    definition.direction = 'Inbound';
    definition.httpMethod = 'GET';
    definition.paginationType = 'Cursor';
    definition.nextPath = 'paging.next';
    definition.maximumPages = 3;
    GenericIntegrationRuntime.registerTestDefinition(definition);
    Scheduled_Integration_Job__c schedule = claimedSchedule(
      'Repeated Cursor',
      'repeated-token',
      'In'
    );
    insert schedule;
    ConnectorHttpClient.setTestTransport(new CapturingTransport(
      200,
      '{"data":[{"name":"Repeated Cursor Account"}],"paging":{"next":"same"}}',
      null
    ));
    try {
      ConnectorExecutionRequest request = requestFor('Inbound');
      request.cursor = 'same';
      request.scheduleId = schedule.Id;
      request.leaseToken = 'repeated-token';
      InboundIntegrationHandler handler = new InboundIntegrationHandler(request);
      handler.start(null);
      handler.execute(null, new List<Integer>{ 1 });
      handler.finish(null);
      Scheduled_Integration_Job__c failed = [
        SELECT Status__c, Last_Error__c
        FROM Scheduled_Integration_Job__c
        WHERE Id = :schedule.Id
      ];
      System.assertEquals('Failed', failed.Status__c);
      System.assert(failed.Last_Error__c.contains('repeated cursor'));
    } finally {
      ConnectorHttpClient.clearTestTransport();
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }

  private static void assertRequestLimitRejected(
    ConnectorExecutionRequest request,
    String expectedText
  ) {
    try {
      GenericIntegrationRuntime.validateRequestLimits(request);
      System.assert(false, expectedText + ' must be validated.');
    } catch (GenericIntegrationRuntime.GenericIntegrationRuntimeException expected) {
      System.assert(expected.getMessage().contains(expectedText));
    }
  }

  private static Scheduled_Integration_Job__c claimedSchedule(
    String keyValue,
    String token,
    String direction
  ) {
    return new Scheduled_Integration_Job__c(
      Logical_Job_Key__c = keyValue,
      Scheduler_Name__c = keyValue,
      Integration_Type__c = 'QuickBooks',
      Source_Object__c = 'contactSync',
      Direction__c = direction,
      Frequency_Value__c = 5,
      Frequency_Type__c = 'Minutes',
      Status__c = 'Claimed',
      Lease_Token__c = token,
      Lease_Expires_At__c = System.now().addMinutes(10),
      Next_Run_At__c = System.now().addMinutes(-1)
    );
  }

  private static GenericIntegrationRuntime.OperationDefinition baseDefinition() {
    GenericIntegrationRuntime.OperationDefinition definition = new GenericIntegrationRuntime.OperationDefinition();
    definition.connectorKey = 'generic-test';
    definition.operationKey = 'contactSync';
    definition.direction = 'Bidirectional';
    definition.salesforceObject = 'Account';
    definition.externalEntity = 'Contact';
    definition.namedCredential = 'Test_App';
    definition.approvedBaseUrl = 'https://api.example.test/v1';
    definition.relativeEndpoint = '/v1/contacts';
    definition.httpMethod = 'POST';
    definition.headersJson = '{"X-Test":"safe"}';
    definition.queryParamsJson = '{"source":"unit"}';
    definition.responseCollectionPath = 'data';
    definition.responseIdPath = 'id';
    definition.responseContentType = 'JSON';
    definition.persistenceMode = 'Upsert';
    definition.requestCardinality = 'Record';
    definition.paginationType = 'Cursor';
    definition.nextPath = 'paging.next';
    definition.maximumPages = 3;
    definition.mappings = new List<GenericIntegrationRuntime.MappingRule>{
      mapping('Inbound', 'Account', 'Name', 'name', true),
      mapping('Outbound', 'Account', 'Name', 'name', true),
      mapping('Response', 'Account', 'Website', 'id', false)
    };
    return definition;
  }

  private static GenericIntegrationRuntime.MappingRule mapping(
    String direction,
    String salesforceObject,
    String salesforceField,
    String externalPath,
    Boolean required
  ) {
    GenericIntegrationRuntime.MappingRule mapping = new GenericIntegrationRuntime.MappingRule();
    mapping.connectorKey = 'generic-test';
    mapping.operationKey = 'contactSync';
    mapping.direction = direction;
    mapping.salesforceObject = salesforceObject;
    mapping.salesforceField = salesforceField;
    mapping.externalPath = externalPath;
    mapping.transform = 'String';
    mapping.required = required;
    mapping.nullBehavior = 'Ignore';
    return mapping;
  }

  private static ConnectorExecutionRequest requestFor(String direction) {
    ConnectorExecutionRequest request = new ConnectorExecutionRequest();
    request.connectorKey = 'generic-test';
    request.operationKey = 'contactSync';
    request.direction = direction;
    request.salesforceObject = 'Account';
    request.externalEntity = 'Contact';
    request.pageNumber = 1;
    return request;
  }

  private static void assertDefinitionRejected(
    GenericIntegrationRuntime.OperationDefinition definition,
    String expectedArea
  ) {
    GenericIntegrationRuntime.clearTestDefinitions();
    try {
      GenericIntegrationRuntime.registerTestDefinition(definition);
      System.assert(false, 'Unsafe configuration must be rejected: ' + expectedArea);
    } catch (Exception expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    } finally {
      GenericIntegrationRuntime.clearTestDefinitions();
    }
  }
}