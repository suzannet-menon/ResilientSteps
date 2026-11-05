import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

class NavigationMath {
  NavigationMath._();

  static const double _earthRadiusMeters = 6371000;
  static const Distance _distance = Distance();

  static double? normalizeHeading(double? heading) {
    if (heading == null || !heading.isFinite) {
      return null;
    }

    final double normalized = heading % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  static double headingDeltaDegrees(double from, double to) {
    return ((to - from + 540) % 360) - 180;
  }

  static double blendHeading(
    double previous,
    double next, {
    double factor = 0.24,
  }) {
    final double normalizedPrevious = normalizeHeading(previous) ?? 0;
    final double normalizedNext = normalizeHeading(next) ?? normalizedPrevious;
    final double clampedFactor = factor.clamp(0.0, 1.0).toDouble();
    final double delta = headingDeltaDegrees(
      normalizedPrevious,
      normalizedNext,
    );
    return normalizeHeading(normalizedPrevious + (delta * clampedFactor)) ??
        normalizedNext;
  }

  static RouteProgressSplit? splitRouteByNearestPoint(
    LatLng point,
    List<LatLng> routePoints,
  ) {
    if (routePoints.isEmpty) {
      return null;
    }

    if (routePoints.length == 1) {
      return RouteProgressSplit(
        projectedPoint: routePoints.first,
        segmentIndex: 0,
        distanceAlongRouteMeters: 0,
        completedPoints: List<LatLng>.unmodifiable(<LatLng>[routePoints.first]),
        remainingPoints: List<LatLng>.unmodifiable(<LatLng>[routePoints.first]),
      );
    }

    double bestDistance = double.infinity;
    double distanceAlongRoute = 0;
    double bestDistanceAlongRoute = 0;
    int bestSegmentIndex = 0;
    LatLng bestProjectedPoint = routePoints.first;

    for (int index = 0; index < routePoints.length - 1; index++) {
      final LatLng start = routePoints[index];
      final LatLng end = routePoints[index + 1];
      final _SegmentProjection projection = _projectOntoSegment(
        point,
        start,
        end,
      );

      if (projection.distanceMeters < bestDistance) {
        bestDistance = projection.distanceMeters;
        bestProjectedPoint = projection.point;
        bestSegmentIndex = index;
        bestDistanceAlongRoute =
            distanceAlongRoute + projection.distanceAlongSegmentMeters;
      }

      distanceAlongRoute += projection.segmentLengthMeters;
    }

    final List<LatLng> completedPoints = <LatLng>[routePoints.first];
    for (int index = 1; index <= bestSegmentIndex; index++) {
      completedPoints.add(routePoints[index]);
    }
    _appendDistinctPoint(completedPoints, bestProjectedPoint);

    final List<LatLng> remainingPoints = <LatLng>[];
    _appendDistinctPoint(remainingPoints, bestProjectedPoint);
    for (
      int index = bestSegmentIndex + 1;
      index < routePoints.length;
      index++
    ) {
      _appendDistinctPoint(remainingPoints, routePoints[index]);
    }

    return RouteProgressSplit(
      projectedPoint: bestProjectedPoint,
      segmentIndex: bestSegmentIndex,
      distanceAlongRouteMeters: bestDistanceAlongRoute,
      completedPoints: List<LatLng>.unmodifiable(completedPoints),
      remainingPoints: List<LatLng>.unmodifiable(remainingPoints),
    );
  }

  static double distanceToPolylineMeters(
    LatLng point,
    List<LatLng> routePoints,
  ) {
    if (routePoints.isEmpty) {
      return double.infinity;
    }

    if (routePoints.length == 1) {
      return _distance(point, routePoints.first);
    }

    double minDistance = double.infinity;
    for (int index = 0; index < routePoints.length - 1; index++) {
      final double segmentDistance = _distancePointToSegmentMeters(
        point,
        routePoints[index],
        routePoints[index + 1],
      );
      if (segmentDistance < minDistance) {
        minDistance = segmentDistance;
      }
    }

    return minDistance;
  }

  static LatLng nearestPointOnPolyline(
    LatLng point,
    List<LatLng> routePoints,
  ) {
    if (routePoints.isEmpty) {
      return point;
    }

    if (routePoints.length == 1) {
      return routePoints.first;
    }

    double bestDistance = double.infinity;
    LatLng bestPoint = routePoints.first;
    for (int index = 0; index < routePoints.length - 1; index++) {
      final _SegmentProjection projection = _projectOntoSegment(
        point,
        routePoints[index],
        routePoints[index + 1],
      );
      if (projection.distanceMeters < bestDistance) {
        bestDistance = projection.distanceMeters;
        bestPoint = projection.point;
      }
    }
    return bestPoint;
  }

  static double distanceMeters(LatLng start, LatLng end) =>
      _distance(start, end);

  static double polylineDistanceMeters(List<LatLng> points) {
    if (points.length < 2) {
      return 0;
    }

    double total = 0;
    for (int index = 0; index < points.length - 1; index++) {
      total += distanceMeters(points[index], points[index + 1]);
    }
    return total;
  }

  static LatLng interpolateBetween(LatLng start, LatLng end, double t) {
    final double clampedT = t.clamp(0.0, 1.0).toDouble();
    final _ProjectedPoint projectedEnd = _projectRelativeTo(start, end);
    return _unprojectRelativeTo(
      start,
      _ProjectedPoint(
        x: projectedEnd.x * clampedT,
        y: projectedEnd.y * clampedT,
      ),
    );
  }

  static LatLng offsetPoint(
    LatLng origin, {
    required double distanceMeters,
    required double headingDegrees,
  }) {
    final double headingRadians = _degreesToRadians(headingDegrees);
    return _unprojectRelativeTo(
      origin,
      _ProjectedPoint(
        x: math.sin(headingRadians) * distanceMeters,
        y: math.cos(headingRadians) * distanceMeters,
      ),
    );
  }

  static double rerouteThresholdMeters(
    double accuracyMeters, {
    double minimum = 40,
    double maximum = 80,
  }) {
    final double safeAccuracy = accuracyMeters.isFinite && accuracyMeters > 0
        ? accuracyMeters
        : minimum;
    final double scaled = safeAccuracy * 2.2;
    return math.max(minimum, math.min(maximum, scaled));
  }

  static double _distancePointToSegmentMeters(
    LatLng point,
    LatLng start,
    LatLng end,
  ) {
    final _ProjectedPoint projectedStart = _projectRelativeTo(point, start);
    final _ProjectedPoint projectedEnd = _projectRelativeTo(point, end);
    final double dx = projectedEnd.x - projectedStart.x;
    final double dy = projectedEnd.y - projectedStart.y;
    final double segmentLengthSquared = (dx * dx) + (dy * dy);

    if (segmentLengthSquared <= 0) {
      return math.sqrt(
        (projectedStart.x * projectedStart.x) +
            (projectedStart.y * projectedStart.y),
      );
    }

    final double projection =
        -((projectedStart.x * dx) + (projectedStart.y * dy)) /
        segmentLengthSquared;
    final double t = projection.clamp(0.0, 1.0).toDouble();
    final double closestX = projectedStart.x + (dx * t);
    final double closestY = projectedStart.y + (dy * t);
    return math.sqrt((closestX * closestX) + (closestY * closestY));
  }

  static _SegmentProjection _projectOntoSegment(
    LatLng point,
    LatLng start,
    LatLng end,
  ) {
    final _ProjectedPoint projectedPoint = _projectRelativeTo(start, point);
    final _ProjectedPoint projectedEnd = _projectRelativeTo(start, end);
    final double dx = projectedEnd.x;
    final double dy = projectedEnd.y;
    final double segmentLengthSquared = (dx * dx) + (dy * dy);

    if (segmentLengthSquared <= 0) {
      return _SegmentProjection(
        point: start,
        distanceMeters: math.sqrt(
          (projectedPoint.x * projectedPoint.x) +
              (projectedPoint.y * projectedPoint.y),
        ),
        distanceAlongSegmentMeters: 0,
        segmentLengthMeters: 0,
      );
    }

    final double segmentLength = math.sqrt(segmentLengthSquared);
    final double projection =
        ((projectedPoint.x * dx) + (projectedPoint.y * dy)) /
        segmentLengthSquared;
    final double t = projection.clamp(0.0, 1.0).toDouble();
    final double closestX = dx * t;
    final double closestY = dy * t;
    final double diffX = projectedPoint.x - closestX;
    final double diffY = projectedPoint.y - closestY;
    final double distance = math.sqrt((diffX * diffX) + (diffY * diffY));

    return _SegmentProjection(
      point: _unprojectRelativeTo(
        start,
        _ProjectedPoint(x: closestX, y: closestY),
      ),
      distanceMeters: distance,
      distanceAlongSegmentMeters: segmentLength * t,
      segmentLengthMeters: segmentLength,
    );
  }

  static _ProjectedPoint _projectRelativeTo(LatLng origin, LatLng point) {
    final double originLatitudeRadians = _degreesToRadians(origin.latitude);
    final double deltaLatitudeRadians = _degreesToRadians(
      point.latitude - origin.latitude,
    );
    final double deltaLongitudeRadians = _degreesToRadians(
      point.longitude - origin.longitude,
    );

    return _ProjectedPoint(
      x:
          deltaLongitudeRadians *
          math.cos(originLatitudeRadians) *
          _earthRadiusMeters,
      y: deltaLatitudeRadians * _earthRadiusMeters,
    );
  }

  static const double _degToRad = math.pi / 180;
  static const double _radToDeg = 180 / math.pi;

  static double _degreesToRadians(double degrees) => degrees * _degToRad;

  static double _radiansToDegrees(double radians) => radians * _radToDeg;

  static LatLng _unprojectRelativeTo(LatLng origin, _ProjectedPoint point) {
    final double originLatitudeRadians = _degreesToRadians(origin.latitude);
    final double latitude =
        origin.latitude + _radiansToDegrees(point.y / _earthRadiusMeters);
    final double longitude =
        origin.longitude +
        _radiansToDegrees(
          point.x / (_earthRadiusMeters * math.cos(originLatitudeRadians)),
        );
    return LatLng(latitude, longitude);
  }

  static void _appendDistinctPoint(List<LatLng> points, LatLng point) {
    if (points.isEmpty || distanceMeters(points.last, point) > 0.1) {
      points.add(point);
    }
  }
}

class RouteProgressSplit {
  const RouteProgressSplit({
    required this.projectedPoint,
    required this.segmentIndex,
    required this.distanceAlongRouteMeters,
    required this.completedPoints,
    required this.remainingPoints,
  });

  final LatLng projectedPoint;
  final int segmentIndex;
  final double distanceAlongRouteMeters;
  final List<LatLng> completedPoints;
  final List<LatLng> remainingPoints;
}

class _ProjectedPoint {
  const _ProjectedPoint({required this.x, required this.y});

  final double x;
  final double y;
}

class _SegmentProjection {
  const _SegmentProjection({
    required this.point,
    required this.distanceMeters,
    required this.distanceAlongSegmentMeters,
    required this.segmentLengthMeters,
  });

  final LatLng point;
  final double distanceMeters;
  final double distanceAlongSegmentMeters;
  final double segmentLengthMeters;
}
