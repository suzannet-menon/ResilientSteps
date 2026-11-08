import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_utils.dart' as api_utils;
import 'auth_service.dart';

class WasteReportSubmissionException implements Exception {
  final String message;

  const WasteReportSubmissionException(this.message);

  @override
  String toString() => message;
}

class WasteCategory {
  final String code;
  final String label;
  final String? description;

  const WasteCategory({
    required this.code,
    required this.label,
    this.description,
  });

  factory WasteCategory.fromJson(Map<String, dynamic> json) {
    return WasteCategory(
      code: json['code'] as String? ?? '',
      label: json['label'] as String? ?? '',
      description: json['description'] as String?,
    );
  }
}

class WasteReportingApiService {
  WasteReportingApiService({
    http.Client? client,
    String? baseUrl,
    Future<String?> Function()? tokenProvider,
    Future<String?> Function()? refreshProvider,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl ?? _envBaseUrl,
       _tokenProvider = tokenProvider ?? AuthService.instance.getFreshAccessToken,
       _refreshProvider = refreshProvider ?? AuthService.instance.refreshAccessToken;

  static const String _envBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const Duration _timeout = Duration(seconds: 10);

  final http.Client _client;
  final String _baseUrl;
  final Future<String?> Function() _tokenProvider;
  final Future<String?> Function() _refreshProvider;

  Future<List<WasteCategory>> fetchCategories() async {
    final Uri uri = Uri.parse('$_baseUrl/waste/categories');

    try {
      final http.Response response = await _client.get(uri).timeout(_timeout);

      if (response.statusCode == 200) {
        final List<dynamic>? parsed = api_utils.tryParseJsonList(response.body);
        if (parsed != null) {
          return parsed
              .map((dynamic item) => WasteCategory.fromJson(item as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (_) {}

    return const <WasteCategory>[
      WasteCategory(code: 'overflowing_bin', label: 'Overflowing Bin'),
      WasteCategory(code: 'illegal_dumping', label: 'Illegal Dumping'),
      WasteCategory(code: 'construction_debris', label: 'Construction Debris'),
      WasteCategory(code: 'garbage_burning', label: 'Garbage Burning'),
      WasteCategory(code: 'dead_animal', label: 'Dead Animal'),
    ];
  }

  Future<Map<String, dynamic>> submitWasteReport({
    required String category,
    required int severity,
    required double latitude,
    required double longitude,
    String? description,
    String? accessToken,
  }) async {
    final Uri uri = Uri.parse('$_baseUrl/waste/reports');
    final Map<String, dynamic> payload = <String, dynamic>{
      'category': category,
      'severity': severity,
      'lat': latitude,
      'lon': longitude,
      'description': description ?? '',
      'metadata': <String, dynamic>{'source': 'mobile_app'},
    };

    final String? token = accessToken ?? await _tokenProvider();

    try {
      http.Response response = await _postReport(uri, token, payload);

      if (response.statusCode == 401 && accessToken == null) {
        final String? refreshed = await _refreshProvider();
        if (refreshed != null && refreshed != token) {
          response = await _postReport(uri, refreshed, payload);
        }
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) {
          throw WasteReportSubmissionException(api_utils.kSessionExpiredMessage);
        }
        throw const WasteReportSubmissionException(
          'Waste report could not be submitted. Please try again.',
        );
      }

      final Map<String, dynamic>? parsed = api_utils.tryParseJsonMap(response.body);
      if (parsed == null) {
        throw const WasteReportSubmissionException(
          'Waste report could not be submitted. Invalid server response.',
        );
      }
      return parsed;
    } on SocketException catch (_) {
      throw const WasteReportSubmissionException(
        'No internet connection. Please check your network and try again.',
      );
    } on TimeoutException catch (_) {
      throw const WasteReportSubmissionException(
        'Request timed out. Please try again.',
      );
    } on WasteReportSubmissionException {
      rethrow;
    } catch (e) {
      throw WasteReportSubmissionException(
        'Unexpected error submitting report: $e',
      );
    }
  }

  Future<http.Response> _postReport(
    Uri uri,
    String? token,
    Map<String, dynamic> payload,
  ) {
    return _client
        .post(
          uri,
          headers: <String, String>{
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode(payload),
        )
        .timeout(_timeout);
  }

  Future<List<Map<String, dynamic>>> fetchRecentReports({int limit = 20}) async {
    final Uri uri = Uri.parse('$_baseUrl/waste/reports/recent?limit=$limit');

    try {
      final http.Response response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode == 200) {
        final List<dynamic>? parsed = api_utils.tryParseJsonList(response.body);
        if (parsed != null) {
          return parsed.cast<Map<String, dynamic>>();
        }
      }
    } catch (_) {}

    return <Map<String, dynamic>>[];
  }
}
