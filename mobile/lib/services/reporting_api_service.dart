import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_utils.dart' as api_utils;
import 'auth_service.dart';

class ReportSubmissionException implements Exception {
  final String message;

  const ReportSubmissionException(this.message);

  @override
  String toString() => message;
}

class ReportingApiService {
  ReportingApiService({
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

  Future<Map<String, dynamic>> submitIncidentReport({
    required String userHash,
    required String incidentType,
    required int severity,
    required double latitude,
    required double longitude,
    String? description,
    String? accessToken,
  }) async {
    final Uri uri = Uri.parse('$_baseUrl/reports');
    final Map<String, dynamic> payload = <String, dynamic>{
      'user_hash': userHash,
      'incident_type': incidentType,
      'severity': severity,
      'lat': latitude,
      'lon': longitude,
      'description': description ?? '',
      'metadata': <String, dynamic>{'source': 'mobile_app'},
    };

    final String? token = accessToken ?? await _tokenProvider();

    http.Response response = await _postReport(uri, token, payload);

    if (response.statusCode == 401 && accessToken == null) {
      final String? refreshed = await _refreshProvider();
      if (refreshed != null && refreshed != token) {
        response = await _postReport(uri, refreshed, payload);
      }
    }

    try {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 401) {
          throw ReportSubmissionException(api_utils.kSessionExpiredMessage);
        }
        throw const ReportSubmissionException(
          'Report could not be submitted. Please try again.',
        );
      }

      final Map<String, dynamic>? parsed = _parseJsonMap(response.body);
      if (parsed == null) {
        throw const ReportSubmissionException(
          'Report could not be submitted. Please try again.',
        );
      }
      return parsed;
    } on ReportSubmissionException {
      rethrow;
    } on SocketException catch (_) {
      throw const ReportSubmissionException(
        'No internet connection. Please check your network and try again.',
      );
    } on TimeoutException catch (_) {
      throw const ReportSubmissionException(
        'The server took too long to respond. Please try again.',
      );
    } catch (_) {
      throw const ReportSubmissionException(
        'Report could not be submitted. Please try again.',
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

  Future<Map<String, dynamic>?> submitEmergencyAlert({
    required String userHash,
    required double latitude,
    required double longitude,
    String? message,
    List<Map<String, String>> trustedContacts = const <Map<String, String>>[],
    int contactsNotified = 0,
    String? accessToken,
  }) async {
    final Uri uri = Uri.parse('$_baseUrl/reports/emergency');
    final Map<String, dynamic> payload = <String, dynamic>{
      'user_hash': userHash,
      'lat': latitude,
      'lon': longitude,
      'message': message,
      'trusted_contacts': trustedContacts,
      'contacts_notified': contactsNotified,
      'metadata': <String, dynamic>{'source': 'mobile_app'},
    };

    final String? token = accessToken ?? await _tokenProvider();

    return _postJson(uri, payload, accessToken: token);
  }

  Future<Map<String, dynamic>?> _postJson(
    Uri uri,
    Map<String, dynamic> payload, {
    String? accessToken,
  }) async {
    try {
      http.Response response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              if (accessToken != null) 'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(payload),
          )
          .timeout(_timeout);

      if (response.statusCode == 401 && accessToken != null) {
        final String? refreshed = await _refreshProvider();
        if (refreshed != null && refreshed != accessToken) {
          response = await _client
              .post(
                uri,
                headers: <String, String>{
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $refreshed',
                },
                body: jsonEncode(payload),
              )
              .timeout(_timeout);
        }
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('ReportingApiService: POST $uri returned '
            '${response.statusCode}');
        return null;
      }

      return _parseJsonMap(response.body);
    } catch (e) {
      debugPrint('ReportingApiService: POST request failed for $uri: $e');
      return null;
    }
  }

  Map<String, dynamic>? _parseJsonMap(String responseBody) =>
      api_utils.tryParseJsonMap(responseBody);
}
