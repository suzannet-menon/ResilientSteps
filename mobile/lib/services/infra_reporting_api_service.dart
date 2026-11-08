import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_utils.dart' as api_utils;
import 'auth_service.dart';

class InfraReportSubmissionException implements Exception {
  final String message;

  const InfraReportSubmissionException(this.message);

  @override
  String toString() => message;
}

class InfraCategory {
  final String code;
  final String label;
  final String? description;

  const InfraCategory({
    required this.code,
    required this.label,
    this.description,
  });

  factory InfraCategory.fromJson(Map<String, dynamic> json) {
    return InfraCategory(
      code: json['code'] as String? ?? '',
      label: json['label'] as String? ?? '',
      description: json['description'] as String?,
    );
  }
}

class InfraReportingApiService {
  InfraReportingApiService({
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

  Future<List<InfraCategory>> fetchCategories() async {
    final Uri uri = Uri.parse('$_baseUrl/infra/categories');

    try {
      final http.Response response = await _client.get(uri).timeout(_timeout);

      if (response.statusCode == 200) {
        final List<dynamic>? parsed = api_utils.tryParseJsonList(response.body);
        if (parsed != null) {
          return parsed
              .map((dynamic item) => InfraCategory.fromJson(item as Map<String, dynamic>))
              .toList();
        }
      }
    } catch (_) {
      // Fallback categories if backend API is unreachable or during initial setup
    }

    return const <InfraCategory>[
      InfraCategory(code: 'pothole', label: 'Pothole'),
      InfraCategory(code: 'streetlight', label: 'Broken Streetlight'),
      InfraCategory(code: 'footpath', label: 'Damaged Footpath'),
      InfraCategory(code: 'fallen_tree', label: 'Fallen Tree'),
      InfraCategory(code: 'traffic_signal', label: 'Broken Traffic Signal'),
      InfraCategory(code: 'water_leak', label: 'Water Leak'),
      InfraCategory(code: 'waterlogging', label: 'Waterlogging / Flooding'),
      InfraCategory(code: 'obstruction', label: 'Road Obstruction'),
    ];
  }

  Future<Map<String, dynamic>> submitInfraReport({
    required String category,
    required int severity,
    required double latitude,
    required double longitude,
    String? description,
    String? accessToken,
  }) async {
    final Uri uri = Uri.parse('$_baseUrl/infra/reports');
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
          throw InfraReportSubmissionException(api_utils.kSessionExpiredMessage);
        }
        throw const InfraReportSubmissionException(
          'Infrastructure report could not be submitted. Please try again.',
        );
      }

      final Map<String, dynamic>? parsed = api_utils.tryParseJsonMap(response.body);
      if (parsed == null) {
        throw const InfraReportSubmissionException(
          'Infrastructure report could not be submitted. Invalid server response.',
        );
      }
      return parsed;
    } on SocketException catch (_) {
      throw const InfraReportSubmissionException(
        'No internet connection. Please check your network and try again.',
      );
    } on TimeoutException catch (_) {
      throw const InfraReportSubmissionException(
        'Request timed out. Please try again.',
      );
    } on InfraReportSubmissionException {
      rethrow;
    } catch (e) {
      throw InfraReportSubmissionException(
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
    final Uri uri = Uri.parse('$_baseUrl/infra/reports/recent?limit=$limit');

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
