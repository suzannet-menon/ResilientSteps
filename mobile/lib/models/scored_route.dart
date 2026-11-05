import 'package:latlong2/latlong.dart';

import 'route_segment_safety.dart';

/// Heat-index bands matching the backend tiers in
/// `backend/app/modules/walksafe/services/weather_service.py` (HEAT_TIERS):
/// penalty 5 ≈ feels-like 28 °C, 12 ≈ 32 °C, 20 ≈ 38 °C, 30 ≈ 42 °C.
String? heatIndexLabelForPenalty(double? penalty) {
  if (penalty == null) {
    return null;
  }
  if (penalty < 1) {
    return 'Pleasant';
  }
  if (penalty < 12) {
    return 'Mild';
  }
  if (penalty < 20) {
    return 'High';
  }
  return 'Extreme';
}

/// Displayable tree-canopy shade label. Tiny non-zero averages (below 0.5%)
/// are shown as "<1%" instead of rounding to a misleading "0%".
String shadeLabelFor(ScoredRoute? route) {
  final double? avg = route?.averageShadeScore;
  if (avg == null) {
    return '-';
  }
  final int pct = avg.round().clamp(0, 100);
  if (pct == 0 && avg > 0) {
    return '<1%';
  }
  return '$pct%';
}

/// A verified safety report whose coordinate matched a road segment of the
/// route (R-104). Used to drop report pins on the map and explain the
/// before/after safety delta.
class RouteIncidentPoint {
  const RouteIncidentPoint({
    required this.point,
    this.id,
    this.category,
    this.severity,
  });

  final LatLng point;
  final String? id;
  final String? category;
  final int? severity;

  String get tooltipLabel {
    final String? normalized = category?.trim();
    final String name = normalized == null || normalized.isEmpty
        ? 'Verified report'
        : _humanCategory(normalized);
    return severity == null ? name : '$name (severity $severity)';
  }

  static String _humanCategory(String raw) {
    final String spaced = raw.replaceAll('_', ' ').trim();
    if (spaced.isEmpty) {
      return spaced;
    }
    return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }
}

class ScoredRoute {
  const ScoredRoute({
    required this.points,
    required this.segments,
    required this.totalDistanceMeters,
    required this.averageSafetyScore,
    required this.totalRisk,
    this.durationMinutes,
    this.warning,
    this.comfortScore,
    this.comfortLevel,
    this.baselineSafetyScore,
    this.incidentScoreDelta,
    this.incidentPoints = const <RouteIncidentPoint>[],
  });

  final List<LatLng> points;
  final List<RouteSegmentSafety> segments;
  final double totalDistanceMeters;
  final double averageSafetyScore;
  final double totalRisk;
  final double? durationMinutes;
  final String? warning;
  final double? comfortScore;
  final String? comfortLevel;

  /// Route safety score before any verified-report penalties (backend
  /// `base_safety_score`). Null on older/degraded payloads. R-104.
  final double? baselineSafetyScore;

  /// How many points the verified reports cost: baseline minus the shown
  /// score. Null or <= 0 means the reports are not visibly affecting it.
  final double? incidentScoreDelta;

  /// Coordinates of the verified reports that were matched to this route's
  /// segments (backend `incident_points`).
  final List<RouteIncidentPoint> incidentPoints;

  /// Human-readable comfort summary, or null when the backend has no comfort
  /// data for this route. The UI keeps its existing rendering path when null.
  String? get comfortSummary {
    final double? score = comfortScore;
    if (score == null) {
      return null;
    }

    final List<String> reasons = <String>[];
    final List<double> shadeValues = segments
        .map((RouteSegmentSafety segment) => segment.shadeScore)
        .whereType<double>()
        .toList(growable: false);
    if (shadeValues.isNotEmpty) {
      final double averageShade =
          shadeValues.reduce((double a, double b) => a + b) /
          shadeValues.length;
      if (averageShade >= 60) {
        reasons.add('well shaded');
      } else if (averageShade >= 30) {
        reasons.add('some shade');
      } else {
        reasons.add('little shade');
      }
    }

    final List<double> heatValues = segments
        .map((RouteSegmentSafety segment) => segment.heatPenalty)
        .whereType<double>()
        .toList(growable: false);
    if (heatValues.isNotEmpty) {
      final double maxHeat = heatValues.reduce(
        (double a, double b) => a > b ? a : b,
      );
      if (maxHeat >= 20) {
        reasons.add('high heat');
      } else if (maxHeat >= 5) {
        reasons.add('moderate heat');
      } else {
        reasons.add('low heat');
      }
    }

    final String? detail = reasons.isNotEmpty
        ? reasons.join(', ')
        : comfortLevel;
    final String suffix = detail == null || detail.trim().isEmpty
        ? ''
        : ' — $detail';
    return '${score.round()}% comfortable$suffix';
  }

  /// Average real tree-canopy shade across matched segments (0–100), or null
  /// when the backend returned no shade scores for this route.
  double? get averageShadeScore {
    final List<double> values = segments
        .map((RouteSegmentSafety segment) => segment.shadeScore)
        .whereType<double>()
        .toList(growable: false);
    if (values.isEmpty) {
      return null;
    }
    final double total = values.reduce(
      (double a, double b) => a + b,
    );
    return total / values.length;
  }

  /// Number of route legs that matched a scored road segment (known shade).
  int get shadeMatchedCount =>
      segments.where((RouteSegmentSafety segment) => segment.shadeScore != null).length;

  int get shadeLegCount => segments.length;

  /// Share of route legs with known shade data (0–100), or null when the
  /// route has no legs or no shade metadata at all.
  int? get shadeCoveragePct {
    if (segments.isEmpty) {
      return null;
    }
    final bool hasShadeField = segments.any(
      (RouteSegmentSafety segment) => segment.shadeScore != null,
    );
    if (!hasShadeField) {
      return null;
    }
    return ((shadeMatchedCount / segments.length) * 100).round().clamp(0, 100);
  }

  /// Highest heat penalty along the route, or null when the backend returned
  /// no heat data (older deployments or weather lookup degraded).
  double? get maxHeatPenalty {
    final List<double> values = segments
        .map((RouteSegmentSafety segment) => segment.heatPenalty)
        .whereType<double>()
        .toList(growable: false);
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((double a, double b) => a > b ? a : b);
  }

  /// Human label for the route's worst heat conditions, or null when the
  /// backend has no heat data yet.
  String? get heatIndexLabel => heatIndexLabelForPenalty(maxHeatPenalty);
}
