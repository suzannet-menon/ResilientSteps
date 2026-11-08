import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mobile/services/reporting_api_service.dart';

ReportingApiService _buildService({
  required http.Client client,
  List<String?> returnedTokens = const <String?>[],
  List<String> refreshTokens = const <String>[],
}) {
  int tokenIndex = 0;
  int refreshIndex = 0;
  return ReportingApiService(
    client: client,
    baseUrl: 'http://test.local',
    tokenProvider: () async {
      if (tokenIndex >= returnedTokens.length) {
        return null;
      }
      return returnedTokens[tokenIndex++];
    },
    refreshProvider: () async {
      if (refreshIndex >= refreshTokens.length) {
        return null;
      }
      return refreshTokens[refreshIndex++];
    },
  );
}

void main() {
  group('ReportingApiService 401 handling', () {
    test('401 -> refresh -> retry with new Bearer token -> success', () async {
      final List<String?> authHeaders = <String?>[];
      final http.Client client = MockClient((http.BaseRequest request) async {
        authHeaders.add(request.headers['Authorization']);
        if (authHeaders.length == 1) {
          return http.Response('{"detail":"token expired"}', 401);
        }
        return http.Response('{"id": "rep-1", "status": "ok"}', 201);
      });

      final ReportingApiService service = _buildService(
        client: client,
        returnedTokens: <String?>['stale-token'],
        refreshTokens: <String>['fresh-token'],
      );

      final Map<String, dynamic> result = await service.submitIncidentReport(
        userHash: 'user-1',
        incidentType: 'harassment',
        severity: 3,
        latitude: 18.52,
        longitude: 73.85,
        description: 'test',
      );

      expect(result['id'], 'rep-1');
      expect(authHeaders.length, 2, reason: 'should POST twice (retry)');
      expect(authHeaders[0], 'Bearer stale-token');
      expect(authHeaders[1], 'Bearer fresh-token');
    });

    test('401 twice -> throw session-expired message, no generic message',
        () async {
      final http.Client client = MockClient(
        (http.BaseRequest request) async =>
            http.Response('{"detail":"token expired"}', 401),
      );

      final ReportingApiService service = _buildService(
        client: client,
        returnedTokens: <String?>['stale-token'],
        refreshTokens: <String>['fresh-token'],
      );

      await expectLater(
        service.submitIncidentReport(
          userHash: 'user-1',
          incidentType: 'harassment',
          severity: 3,
          latitude: 18.52,
          longitude: 73.85,
        ),
        throwsA(
          isA<ReportSubmissionException>().having(
            (ReportSubmissionException e) => e.message,
            'message',
            contains('session has expired'),
          ),
        ),
      );
    });

    test('explicit accessToken is used as-is, and no refresh retry', () async {
      final List<String?> authHeaders = <String?>[];
      final http.Client client = MockClient((http.BaseRequest request) async {
        authHeaders.add(request.headers['Authorization']);
        return http.Response('{"id": "rep-2"}', 200);
      });

      final ReportingApiService service = ReportingApiService(
        client: client,
        baseUrl: 'http://test.local',
      );

      final Map<String, dynamic> result = await service.submitIncidentReport(
        userHash: 'user-1',
        incidentType: 'harassment',
        severity: 2,
        latitude: 18.52,
        longitude: 73.85,
        accessToken: 'forced-token',
      );

      expect(result['id'], 'rep-2');
      expect(authHeaders, <String?>['Bearer forced-token']);
    });
  });
}
