import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/route_segment_safety.dart';
import '../models/scored_route.dart';
import 'api_utils.dart' as api_utils;

class RoutingService {
  RoutingService({http.Client? client, String? apiBaseUrl})
    : _client = client ?? http.Client(),
      _apiBaseUrl = apiBaseUrl ?? _baseUrl;

  static const String _baseUrl = String.fromEnvironment('API_BASE_URL');
  static const Duration _requestTimeout = Duration(seconds: 12);

  /// Exposed for tests that verify payload parsing without network calls.
  ScoredRoute? scoredRouteFromPayload(
    Map<String, dynamic>? payload,
    List<LatLng> routePoints,
  ) => _scoredRouteFromPayload(payload, routePoints);

  final http.Client _client;
  final String _apiBaseUrl;
  final Distance _distance = const Distance();

  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    return _fetchRoutePoints(start, end);
  }

  Future<ScoredRoute?> getSafestRoute(LatLng start, LatLng end) async {
    // Try unified /route-safe endpoint first.
    final Map<String, dynamic>? scorePayload = await _fetchRouteSafety(
      start,
      end,
    );
    List<LatLng>? routePoints;
    if (scorePayload != null) {
      final Object? coordsRaw = scorePayload['coordinates'];
      if (coordsRaw is List) {
        routePoints = <LatLng>[];
        for (final dynamic item in coordsRaw) {
          if (item is List && item.length >= 2) {
            final double? lat = _asDouble(item[0]);
            final double? lon = _asDouble(item[1]);
            if (lat != null && lon != null) {
              routePoints.add(LatLng(lat, lon));
            }
          }
        }
      }
    }

    Map<String, dynamic>? finalScorePayload = scorePayload;
    if (routePoints == null || routePoints.length < 2) {
      // Fallback: fetch route points first, then risk details.
      routePoints = await _fetchRoutePoints(start, end);
      if (routePoints.length < 2) {
        return null;
      }
      finalScorePayload = await _fetchRouteRisk(routePoints);
      if (finalScorePayload == null) {
        return null;
      }
    }

    final ScoredRoute? scored = _scoredRouteFromPayload(
      finalScorePayload,
      routePoints,
    );
    if (scored == null) {
      return null;
    }
    return scored;
  }

  /// Re-scores an existing route's geometry against current incident data.
  ///
  /// Used during active navigation so newly verified reports are reflected in
  /// the displayed safety/comfort numbers without changing the planned path.
  /// Returns null when the rescore request fails or carries no safety score.
  Future<ScoredRoute?> rescoreRoute(List<LatLng> routePoints) async {
    if (routePoints.length < 2) {
      return null;
    }
    final Map<String, dynamic>? payload = await _fetchRouteRisk(routePoints);
    if (payload == null) {
      return null;
    }
    return _scoredRouteFromPayload(payload, routePoints);
  }

  ScoredRoute? _scoredRouteFromPayload(
    Map<String, dynamic>? payload,
    List<LatLng> routePoints,
  ) {
    final double? safetyScore = _asDouble(payload?['safety_score']);
    if (safetyScore == null) {
      return null;
    }

    final double totalDistanceMeters =
        (_asDouble(payload?['distance_km']) ?? 0) > 0
        ? (_asDouble(payload?['distance_km']) ?? 0) * 1000
        : _polylineDistanceMeters(routePoints);
    final List<RouteSegmentSafety> segments = _parseRouteSegments(
      payload?['segments'],
      fallbackSafetyScore: safetyScore,
    );

    final ScoredRoute route = ScoredRoute(
      points: routePoints,
      segments: segments,
      totalDistanceMeters: totalDistanceMeters,
      averageSafetyScore: safetyScore,
      totalRisk: 100 - safetyScore,
      durationMinutes: _asDouble(payload?['duration_minutes']),
      warning: payload?['warning']?.toString(),
      comfortScore: _asDouble(payload?['comfort_score']),
      comfortLevel: payload?['comfort_level']?.toString(),
      baselineSafetyScore: _asDouble(payload?['base_safety_score']),
      incidentScoreDelta: _asDouble(payload?['incident_score_delta']),
      incidentPoints: _parseIncidentPoints(payload?['incident_points']),
    );
    return route;
  }

  /// R-104: verified report coordinates matched to the route's segments.
  List<RouteIncidentPoint> _parseIncidentPoints(Object? raw) {
    if (raw is! List) {
      return const <RouteIncidentPoint>[];
    }
    final List<RouteIncidentPoint> points = <RouteIncidentPoint>[];
    for (final dynamic item in raw) {
      final Map<String, dynamic>? point = _coerceMap(item);
      final double? lat = _asDouble(point?['lat']);
      final double? lon = _asDouble(point?['lon']);
      if (lat == null || lon == null) {
        continue;
      }
      final double? severity = _asDouble(point?['severity']);
      points.add(
        RouteIncidentPoint(
          point: LatLng(lat, lon),
          id: point?['id']?.toString(),
          category: point?['category']?.toString(),
          severity: severity?.round(),
        ),
      );
    }
    return points;
  }

  Future<List<LatLng>> _fetchRoutePoints(LatLng start, LatLng end) async {
    final Uri uri = Uri.parse('$_apiBaseUrl/route').replace(
      queryParameters: <String, String>{
        'start_lat': start.latitude.toString(),
        'start_lon': start.longitude.toString(),
        'end_lat': end.latitude.toString(),
        'end_lon': end.longitude.toString(),
      },
    );

    final http.Response? response = await _safeGet(uri);
    if (response == null || response.statusCode != 200) {
      return <LatLng>[];
    }

    final Map<String, dynamic>? payload = _tryParseJsonMap(response.body);
    if (payload == null) {
      return <LatLng>[];
    }

    final Object? safest = payload['safest'];
    if (safest is! List) {
      return <LatLng>[];
    }

    final List<LatLng> points = <LatLng>[];
    for (final dynamic item in safest) {
      final Map<String, dynamic>? point = _coerceMap(item);
      if (point == null) {
        continue;
      }
      final double? lat = _asDouble(point['lat']);
      final double? lon = _asDouble(point['lon']);
      if (lat == null || lon == null) {
        continue;
      }
      points.add(LatLng(lat, lon));
    }
    return points;
  }

  Future<Map<String, dynamic>?> _fetchRouteSafety(
    LatLng start,
    LatLng end,
  ) async {
    final Uri uri = Uri.parse('$_apiBaseUrl/route-safe').replace(
      queryParameters: <String, String>{
        'start_lat': start.latitude.toString(),
        'start_lon': start.longitude.toString(),
        'end_lat': end.latitude.toString(),
        'end_lon': end.longitude.toString(),
      },
    );

    final http.Response? response = await _safeGet(uri);
    if (response == null || response.statusCode != 200) {
      return null;
    }
    return _tryParseJsonMap(response.body);
  }

  Future<Map<String, dynamic>?> _fetchRouteRisk(
    List<LatLng> coordinates,
  ) async {
    final Uri uri = Uri.parse('$_apiBaseUrl/route/risk');

    try {
      final http.Response response = await _client
          .post(
            uri,
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'coordinates': coordinates
                  .map(
                    (LatLng point) => <String, double>{
                      'lat': point.latitude,
                      'lon': point.longitude,
                    },
                  )
                  .toList(growable: false),
            }),
          )
          .timeout(_requestTimeout);
      if (response.statusCode != 200) {
        return null;
      }
      return _tryParseJsonMap(response.body);
    } catch (e) {
      debugPrint('RoutingService: segment safety request failed: $e');
      return null;
    }
  }

  Future<http.Response?> _safeGet(Uri uri) async {
    final http.Response? first = await _attemptGet(uri);
    if (first != null) {
      return first;
    }
    // Transient first-call failures (cold backend, slow DB round trip) get a
    // single immediate retry before falling back to the legacy endpoints.
    return _attemptGet(uri);
  }

  Future<http.Response?> _attemptGet(Uri uri) async {
    try {
      return await _client.get(uri).timeout(_requestTimeout);
    } catch (e) {
      debugPrint('RoutingService: GET request failed for $uri: $e');
      return null;
    }
  }

  Map<String, dynamic>? _tryParseJsonMap(String body) =>
      api_utils.tryParseJsonMap(body);

  Map<String, dynamic>? _coerceMap(Object? value) => api_utils.coerceMap(value);

  double? _asDouble(Object? value) => api_utils.asDouble(value);

  bool _asBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final String normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1';
    }
    return false;
  }

  List<RouteSegmentSafety> _parseRouteSegments(
    Object? rawSegments, {
    required double fallbackSafetyScore,
  }) {
    if (rawSegments is! List) {
      return const <RouteSegmentSafety>[];
    }

    final List<RouteSegmentSafety> segments = <RouteSegmentSafety>[];
    for (final dynamic item in rawSegments) {
      final Map<String, dynamic>? segment = _coerceMap(item);
      final Map<String, dynamic>? start = _coerceMap(segment?['start']);
      final Map<String, dynamic>? end = _coerceMap(segment?['end']);
      if (segment == null || start == null || end == null) {
        continue;
      }

      final double? startLat = _asDouble(start['lat']);
      final double? startLon = _asDouble(start['lon']);
      final double? endLat = _asDouble(end['lat']);
      final double? endLon = _asDouble(end['lon']);
      if (startLat == null ||
          startLon == null ||
          endLat == null ||
          endLon == null) {
        continue;
      }

      final bool matched = _asBool(segment['matched']);
      final Map<String, dynamic>? zone = _coerceMap(segment['zone']);
      final double? baseSafetyScore = _asDouble(segment['base_safety_score']);
      final double safetyScore =
          _asDouble(segment['safety_score']) ??
          baseSafetyScore ??
          fallbackSafetyScore;
      final double incidentWeight = _asDouble(segment['incident_weight']) ?? 0;
      final double incidentPenalty =
          _asDouble(segment['incident_penalty']) ?? 0;
      final double? zoneRiskScore = _asDouble(zone?['risk_score']);
      final double lightingHeuristic = _parseLightingHeuristic(
        segment['lighting'],
      );

      segments.add(
        RouteSegmentSafety(
          start: LatLng(startLat, startLon),
          end: LatLng(endLat, endLon),
          distanceMeters: _asDouble(segment['length_m']) ?? 0,
          safetyScore: safetyScore,
          incidentRisk: incidentWeight,
          timeOfDayRisk: 0,
          lightingLevel: lightingHeuristic,
          crowdDensity: zoneRiskScore ?? 0,
          distanceWeight: _asDouble(segment['match_distance_m']) ?? 0,
          safetyPenalty: incidentPenalty,
          risk: (100 - safetyScore).clamp(0, 100).toDouble(),
          segmentId: segment['road_segment_id']?.toString(),
          safetyLevel: _deriveSafetyLevel(
            safetyScore: safetyScore,
            zoneRiskLevel: zone?['risk_level']?.toString(),
            matched: matched,
          ),
          baseSafetyScore: baseSafetyScore,
          incidentDensity: _asDouble(segment['incident_count']),
          lightingHeuristic: lightingHeuristic,
          distanceToQuery: _asDouble(segment['match_distance_m']),
          shadeScore: _asDouble(segment['shade_score']),
          heatPenalty: _asDouble(segment['heat_penalty']),
          comfortScore: _asDouble(segment['comfort_score']),
        ),
      );
    }

    return segments;
  }

  double _parseLightingHeuristic(Object? value) {
    final double? numericValue = _asDouble(value);
    if (numericValue != null) {
      return numericValue;
    }
    if (value is! String) {
      return 0;
    }

    switch (value.trim().toLowerCase()) {
      case 'good':
      case 'bright':
      case 'well_lit':
      case 'well-lit':
        return 1;
      case 'moderate':
      case 'fair':
        return 0.6;
      case 'poor':
      case 'dim':
      case 'low':
        return 0.25;
      default:
        return 0;
    }
  }

  String _deriveSafetyLevel({
    required double safetyScore,
    required bool matched,
    String? zoneRiskLevel,
  }) {
    if (!matched) {
      return 'UNKNOWN';
    }

    final String normalizedZoneLevel = (zoneRiskLevel ?? '')
        .trim()
        .toUpperCase();
    if (normalizedZoneLevel == 'SAFE' ||
        normalizedZoneLevel == 'CAUTIOUS' ||
        normalizedZoneLevel == 'RISKY') {
      return normalizedZoneLevel;
    }

    if (safetyScore < 40) {
      return 'RISKY';
    }
    if (safetyScore < 70) {
      return 'CAUTIOUS';
    }
    return 'SAFE';
  }

  double _polylineDistanceMeters(List<LatLng> points) {
    if (points.length < 2) {
      return 0;
    }

    double total = 0;
    for (int i = 0; i < points.length - 1; i++) {
      total += _distance(points[i], points[i + 1]);
    }
    return total;
  }
}
