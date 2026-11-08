/// Shared API response parsing utilities.
///
/// These helpers were previously duplicated across routing_service.dart,
/// safety_heatmap_service.dart, and reporting_api_service.dart.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Message used when the server rejects a submitting request with 401 even
/// after a token refresh, i.e. the session cannot be renewed automatically.
const String kSessionExpiredMessage =
    'Your session has expired. Please sign in again and try again.';

/// Attempts to parse a JSON string as a [Map<String, dynamic>].
/// Returns null on parse failure or non-map results.
Map<String, dynamic>? tryParseJsonMap(String body) {
  try {
    final dynamic decoded = jsonDecode(body);
    return coerceMap(decoded);
  } catch (e) {
    debugPrint('api_utils: JSON parse failed: $e');
    return null;
  }
}

/// Attempts to parse a JSON string as a [List<dynamic>].
/// Returns null on parse failure or non-list results.
List<dynamic>? tryParseJsonList(String body) {
  try {
    final dynamic decoded = jsonDecode(body);
    if (decoded is List) {
      return decoded;
    }
    return null;
  } catch (e) {
    debugPrint('api_utils: JSON list parse failed: $e');
    return null;
  }
}

/// Coerces an [Object?] to a [Map<String, dynamic>] if possible.
/// Handles both typed and untyped maps. Returns null for non-map values.
Map<String, dynamic>? coerceMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (dynamic key, dynamic val) => MapEntry(key.toString(), val),
    );
  }
  return null;
}

/// Safely converts a value to [double].
/// Handles [num] and [String] types. Returns null for everything else.
double? asDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

