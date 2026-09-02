@isTest
private class HmacRequestVerifierTest {
  private static final String SECRET = 'super-secret-signing-key';
  private static final String BODY = '{"action":"deactivate","methods":["stripe"]}';

  private static String nowTs() {
    return String.valueOf(Datetime.now().getTime() / 1000);
  }

  @isTest
  static void validSignaturePasses() {
    String ts = nowTs();
    String sig = HmacRequestVerifier.computeSignature(ts, BODY, SECRET);

    Test.startTest();
    HmacRequestVerifier.Result r = HmacRequestVerifier.verify(
      BODY,
      sig,
      ts,
      SECRET,
      300
    );
    Test.stopTest();

    System.assertEquals(true, r.ok, 'Valid signature should pass.');
    System.assertEquals(200, r.statusCode);
  }

  @isTest
  static void missingHeadersAre401() {
    HmacRequestVerifier.Result noSig = HmacRequestVerifier.verify(
      BODY,
      null,
      nowTs(),
      SECRET,
      300
    );
    HmacRequestVerifier.Result noTs = HmacRequestVerifier.verify(
      BODY,
      'deadbeef',
      null,
      SECRET,
      300
    );
    System.assertEquals(401, noSig.statusCode);
    System.assertEquals(401, noTs.statusCode);
    System.assertEquals(false, noSig.ok);
    System.assertEquals(false, noTs.ok);
  }

  @isTest
  static void blankSecretIs503() {
    HmacRequestVerifier.Result r = HmacRequestVerifier.verify(
      BODY,
      'deadbeef',
      nowTs(),
      '',
      300
    );
    System.assertEquals(503, r.statusCode, 'Misconfig -> 503.');
    System.assertEquals(false, r.ok);
  }

  @isTest
  static void staleTimestampIs401() {
    String staleTs = String.valueOf(
      (Datetime.now().getTime() / 1000) - 1000
    ); // > 300s old
    String sig = HmacRequestVerifier.computeSignature(staleTs, BODY, SECRET);

    HmacRequestVerifier.Result r = HmacRequestVerifier.verify(
      BODY,
      sig,
      staleTs,
      SECRET,
      300
    );
    System.assertEquals(401, r.statusCode, 'Stale timestamp -> 401.');
    System.assertEquals(false, r.ok);
  }

  @isTest
  static void wrongSecretFails() {
    String ts = nowTs();
    String sig = HmacRequestVerifier.computeSignature(ts, BODY, 'other-secret');

    HmacRequestVerifier.Result r = HmacRequestVerifier.verify(
      BODY,
      sig,
      ts,
      SECRET,
      300
    );
    System.assertEquals(401, r.statusCode, 'Signature mismatch -> 401.');
    System.assertEquals(false, r.ok);
  }

  @isTest
  static void nonHexSignatureFails() {
    String ts = nowTs();
    HmacRequestVerifier.Result r = HmacRequestVerifier.verify(
      BODY,
      'not-a-hex-signature!!',
      ts,
      SECRET,
      300
    );
    System.assertEquals(401, r.statusCode);
    System.assertEquals(false, r.ok);
  }

  @isTest
  static void invalidTimestampFormatIs401() {
    String sig = HmacRequestVerifier.computeSignature('abc', BODY, SECRET);
    HmacRequestVerifier.Result r = HmacRequestVerifier.verify(
      BODY,
      sig,
      'abc',
      SECRET,
      300
    );
    System.assertEquals(401, r.statusCode);
  }

  @isTest
  static void getHeaderValueIsCaseInsensitive() {
    RestRequest req = new RestRequest();
    req.headers.put('X-QB-Signature', 'abc123');
    System.assertEquals(
      'abc123',
      HmacRequestVerifier.getHeaderValue(req, 'x-qb-signature')
    );
    System.assertEquals(
      null,
      HmacRequestVerifier.getHeaderValue(req, 'Missing-Header')
    );
  }
}