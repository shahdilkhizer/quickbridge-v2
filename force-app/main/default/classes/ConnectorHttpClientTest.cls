@IsTest
private class ConnectorHttpClientTest {
  private class CapturingTransport implements ConnectorHttpClient.Transport {
    HttpRequest capturedRequest;
    Integer statusCode;
    String body;
    String retryAfter;

    CapturingTransport(Integer statusCode, String body, String retryAfter) {
      this.statusCode = statusCode;
      this.body = body;
      this.retryAfter = retryAfter;
    }

    public HttpResponse send(HttpRequest request) {
      capturedRequest = request;
      HttpResponse response = new HttpResponse();
      response.setStatusCode(statusCode);
      response.setStatus(
        statusCode >= 200 && statusCode < 300 ? 'OK' : 'Error'
      );
      if (body != null) {
        response.setBody(body);
      }
      if (retryAfter != null) {
        response.setHeader('Retry-After', retryAfter);
      }
      return response;
    }
  }

  @IsTest
  static void sendsOnlyRelativeNamedCredentialRequests() {
    CapturingTransport transport = new CapturingTransport(
      429,
      '{"access_token":"secret"}',
      '120'
    );
    ConnectorHttpClient.setTestTransport(transport);
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = 'QuickBridgeTLG__Shopify_API';
    spec.relativeEndpoint = '/admin/api/2024-04/products.json?limit=50';
    spec.headers.put('Accept', 'application/json');

    ConnectorHttpClient.Response response = ConnectorHttpClient.send(spec);

    System.assertEquals(
      'callout:QuickBridgeTLG__Shopify_API/admin/api/2024-04/products.json?limit=50',
      transport.capturedRequest.getEndpoint()
    );
    System.assertEquals(true, response.retryable);
    System.assertEquals(120, response.retryAfterSeconds);
    System.assert(!response.errorSummary.contains('secret'));
    System.assertEquals('120', response.header('Retry-After'));
  }

  @IsTest
  static void enforcesAbsolutePaginationBoundary() {
    System.assertEquals(
      'callout:Klaviyo_API/api/profiles?page[cursor]=abc',
      ConnectorHttpClient.toSafeNextEndpoint(
        'Klaviyo_API',
        'https://a.klaviyo.com/api',
        'https://a.klaviyo.com/api/profiles?page[cursor]=abc'
      )
    );

    assertUnsafePaginationRejected('https://attacker.example/api/profiles');
    assertUnsafePaginationRejected('https://a.klaviyo.com/private/profiles');
    try {
      ConnectorHttpClient.toNamedCredentialEndpoint(
        'Klaviyo_API',
        'https://a.klaviyo.com/api/profiles'
      );
      System.assert(false, 'Absolute direct endpoint must be rejected.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }

  @IsTest
  static void parsesSupportedPaginationStyles() {
    String linkHeader =
      '<https://example.test/api/items?page=1>; rel="previous", ' +
      '<https://example.test/api/items?page=3>; rel="next"';
    System.assertEquals(
      'https://example.test/api/items?page=3',
      ConnectorHttpClient.extractLinkNext(linkHeader)
    );
    System.assertEquals(
      'https://example.test/api/items?page=2',
      ConnectorHttpClient.extractJsonNext(
        '{"links":{"next":"https://example.test/api/items?page=2"}}',
        'links.next'
      )
    );
    System.assertEquals(
      'cursor-2',
      ConnectorHttpClient.extractCursor(
        '{"paging":{"cursor":"cursor-2"}}',
        'paging.cursor'
      )
    );
    System.assertEquals(25, ConnectorHttpClient.nextOffset(0, 25, 25, null));
    System.assertEquals(null, ConnectorHttpClient.nextOffset(25, 25, 4, null));
    System.assertEquals(
      '/api/items?a=one%20two&z=last',
      ConnectorHttpClient.appendQuery(
        '/api/items',
        new Map<String, String>{ 'z' => 'last', 'a' => 'one two' }
      )
    );
  }

  @IsTest
  static void rejectsMalformedPaginationAndInjection() {
    try {
      ConnectorHttpClient.extractJsonNext('{bad json', 'links.next');
      System.assert(false, 'Malformed JSON must be rejected.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(expected.getMessage().contains('malformed JSON'));
    }

    try {
      ConnectorHttpClient.assertPageWithinLimit(51, 50);
      System.assert(false, 'Page limit must be enforced.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(expected.getMessage().contains('safety limit'));
    }

    ConnectorHttpClient.RequestSpec injectedHeader = new ConnectorHttpClient.RequestSpec();
    injectedHeader.namedCredential = 'Klaviyo_API';
    injectedHeader.relativeEndpoint = '/api/profiles';
    injectedHeader.headers.put('X-Test', 'safe\r\nHost: attacker.example');
    ConnectorHttpClient.setTestTransport(
      new CapturingTransport(200, '{}', null)
    );
    try {
      ConnectorHttpClient.send(injectedHeader);
      System.assert(false, 'Header injection must be rejected.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(expected.getMessage().contains('header'));
    }
  }

  @IsTest
  static void rejectsInvalidRequestSpecifications() {
    assertInvalidSpec(null);

    ConnectorHttpClient.RequestSpec badMethod = validSpec();
    badMethod.method = 'TRACE';
    assertInvalidSpec(badMethod);

    ConnectorHttpClient.RequestSpec badTimeout = validSpec();
    badTimeout.timeoutMilliseconds = 0;
    assertInvalidSpec(badTimeout);

    ConnectorHttpClient.RequestSpec badPage = validSpec();
    badPage.pageNumber = 2;
    badPage.maximumPages = 1;
    assertInvalidSpec(badPage);

    for (
      String endpoint : new List<String>{
        '//attacker.example/path',
        '/api/../private',
        '/api/%2e%2e/private',
        '/api/path#fragment',
        'callout:Other/path'
      }
    ) {
      try {
        ConnectorHttpClient.toNamedCredentialEndpoint('Klaviyo_API', endpoint);
        System.assert(false, 'Unsafe endpoint must be rejected: ' + endpoint);
      } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
        System.assert(String.isNotBlank(expected.getMessage()));
      }
    }
    try {
      ConnectorHttpClient.toNamedCredentialEndpoint('bad credential!', '/api');
      System.assert(
        false,
        'Unsafe Named Credential identifiers must be rejected.'
      );
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(expected.getMessage().contains('Named Credential'));
    }
  }

  @IsTest
  static void coversEmptyPaginationAndSuccessfulResponses() {
    System.assertEquals(null, ConnectorHttpClient.extractLinkNext(null));
    System.assertEquals(
      null,
      ConnectorHttpClient.extractJsonNext('{}', 'links.next')
    );
    System.assertEquals(
      null,
      ConnectorHttpClient.extractJsonNext('{"links":{"next":[]}}', 'links.next')
    );
    System.assertEquals(
      null,
      ConnectorHttpClient.extractCursor('{}', 'paging.cursor')
    );
    System.assertEquals(
      '/api/items',
      ConnectorHttpClient.appendQuery('/api/items', null)
    );
    System.assertEquals(null, ConnectorHttpClient.nextOffset(25, 25, 0, true));

    ConnectorHttpClient.RequestSpec spec = validSpec();
    spec.headers = null;
    ConnectorHttpClient.setTestTransport(
      new CapturingTransport(204, null, 'not-a-number')
    );
    ConnectorHttpClient.Response response = ConnectorHttpClient.send(spec);
    System.assertEquals(true, response.successful);
    System.assertEquals(false, response.retryable);
    System.assertEquals(null, response.retryAfterSeconds);
    System.assertEquals(null, response.errorSummary);
    System.assertEquals(null, response.header(null));
  }

  @IsTest
  static void rejectsPaginationAndParameterEdgeCases() {
    try {
      ConnectorHttpClient.nextOffset(-1, 25, 25, true);
      System.assert(false, 'Negative offsets must be rejected.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(expected.getMessage().contains('Offset pagination'));
    }
    try {
      ConnectorHttpClient.appendQuery(
        '/api/items',
        new Map<String, String>{ 'unsafe key&x' => 'value' }
      );
      System.assert(false, 'Unsafe parameter names must be rejected.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(expected.getMessage().contains('parameter'));
    }
    for (
      String baseUrl : new List<String>{
        'http://a.klaviyo.com/api',
        'https://user@a.klaviyo.com/api',
        'not-a-url'
      }
    ) {
      try {
        ConnectorHttpClient.safeRelativeNext(
          baseUrl,
          'https://a.klaviyo.com/api/profiles'
        );
        System.assert(false, 'Unsafe approved base URL must be rejected.');
      } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
        System.assert(String.isNotBlank(expected.getMessage()));
      }
    }

    ConnectorHttpClient.RequestSpec hostHeader = validSpec();
    hostHeader.headers.put('Host', 'attacker.example');
    assertInvalidSpec(hostHeader);

    System.assertEquals(
      null,
      ConnectorHttpClient.extractJsonNext('{"links":{}}', 'bad path!')
    );
  }

  private static ConnectorHttpClient.RequestSpec validSpec() {
    ConnectorHttpClient.RequestSpec spec = new ConnectorHttpClient.RequestSpec();
    spec.namedCredential = 'Klaviyo_API';
    spec.relativeEndpoint = '/api/profiles';
    return spec;
  }

  private static void assertInvalidSpec(ConnectorHttpClient.RequestSpec spec) {
    ConnectorHttpClient.setTestTransport(
      new CapturingTransport(200, '{}', null)
    );
    try {
      ConnectorHttpClient.send(spec);
      System.assert(false, 'Invalid HTTP request specification must fail.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }

  private static void assertUnsafePaginationRejected(String nextUrl) {
    try {
      ConnectorHttpClient.toSafeNextEndpoint(
        'Klaviyo_API',
        'https://a.klaviyo.com/api',
        nextUrl
      );
      System.assert(false, 'Expected unsafe pagination URL to be rejected.');
    } catch (ConnectorHttpClient.ConnectorHttpClientException expected) {
      System.assert(String.isNotBlank(expected.getMessage()));
    }
  }
}