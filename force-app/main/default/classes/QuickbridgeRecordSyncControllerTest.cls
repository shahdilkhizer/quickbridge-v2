@IsTest
private class QuickbridgeRecordSyncControllerTest {

  private class MockHttpResponse implements HttpCalloutMock {
    private Integer statusCode;
    private String body;

    public MockHttpResponse(Integer statusCode, String body) {
      this.statusCode = statusCode;
      this.body = body;
    }

    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(statusCode);
      res.setBody(body);
      return res;
    }
  }

  @IsTest
  static void testSyncToProviderSuccess() {
    Account acc = new Account(Name = 'Sync Test Outbound Account');
    insert acc;

    String mockResponseBody = '{"Customer":{"Id":"555","DisplayName":"Sync Test Outbound Account"}}';
    Test.setMock(HttpCalloutMock.class, new MockHttpResponse(200, mockResponseBody));

    Test.startTest();
    QuickbridgeRecordSyncController.SyncResult result =
      QuickbridgeRecordSyncController.syncToProvider(acc.Id, 'qbo');
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assertEquals(true, result.success);
    System.assertEquals('555', result.externalId);

    Account updatedAcc = [SELECT Id, QuickbookID__c FROM Account WHERE Id = :acc.Id];
    System.assertEquals('555', updatedAcc.QuickbookID__c);
  }

  @IsTest
  static void testSyncFromProviderSuccess() {
    Account acc = new Account(Name = 'Sync Test Inbound Account', QuickbookID__c = '777');
    insert acc;

    String mockResponseBody = '{"Customer":{"Id":"777","DisplayName":"Refreshed Account Name"}}';
    Test.setMock(HttpCalloutMock.class, new MockHttpResponse(200, mockResponseBody));

    Test.startTest();
    QuickbridgeRecordSyncController.SyncResult result =
      QuickbridgeRecordSyncController.syncFromProvider(acc.Id, 'qbo');
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assertEquals(true, result.success);
  }

  @IsTest
  static void testSyncFromProviderUnlinked() {
    Account acc = new Account(Name = 'Unlinked Account');
    insert acc;

    Test.startTest();
    QuickbridgeRecordSyncController.SyncResult result =
      QuickbridgeRecordSyncController.syncFromProvider(acc.Id, 'qbo');
    Test.stopTest();

    System.assertNotEquals(null, result);
    System.assertEquals(false, result.success);
    System.assert(result.message.contains('not yet linked'));
  }

  @IsTest
  static void testNullRecordId() {
    Test.startTest();
    QuickbridgeRecordSyncController.SyncResult resOut =
      QuickbridgeRecordSyncController.syncToProvider(null, 'qbo');
    QuickbridgeRecordSyncController.SyncResult resIn =
      QuickbridgeRecordSyncController.syncFromProvider(null, 'qbo');
    Test.stopTest();

    System.assertEquals(false, resOut.success);
    System.assertEquals(false, resIn.success);
  }
}
