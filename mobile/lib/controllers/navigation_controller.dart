import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/scored_route.dart';
import '../models/safety_zone.dart';
import '../services/location_service.dart';
import '../services/navigation_math.dart';
import '../services/routing_service.dart';
import '../services/safety_heatmap_service.dart';

typedef PositionStreamFactory = Stream<Position> Function();
typedef CompassStreamFactory = Stream<CompassEvent>? Function();

enum NavigationState { idle, planning, active, arrived }

class NavigationCameraInstruction {
  const NavigationCameraInstruction({
    required this.userPoint,
    required this.rotateCamera,
    this.heading,
  });

  final LatLng userPoint;
  final bool rotateCamera;
  final double? heading;
}

enum RouteLoadStatus { success, noRoute, error }

class HomeMapLoadResult {
  const HomeMapLoadResult({required this.center, required this.safetyZones});

  final LatLng center;
  final List<SafetyZone> safetyZones;
}

class RouteLoadResult {
  const RouteLoadResult({required this.status, required this.safetyZones});

  final RouteLoadStatus status;
  final List<SafetyZone> safetyZones;
}

class NavigationController extends ChangeNotifier {
  NavigationController({
    PositionStreamFactory? positionStreamFactory,
    CompassStreamFactory? compassStreamFactory,
  }) : _isCustomPositionStream = positionStreamFactory != null,
       _positionStreamFactory =
           positionStreamFactory ?? _defaultPositionStreamFactory,
       _compassStreamFactory =
           compassStreamFactory ?? _defaultCompassStreamFactory;

  static const double _minimumHeadingSpeedMps = 0.4;
  static const double _minimumLikelyMovementSpeedMps = 0.8;
  static const double _maximumReliableAccuracyMeters = 35;
  static const int _offRouteConfirmationSamples = 3;
  static const Duration _rerouteCooldown = Duration(seconds: 15);
  static const Duration _rescoreInterval = Duration(minutes: 3);
  static const double _cameraHeadingDeadbandDegrees = 1.5;
  static const double _maxCameraFollowDistanceMeters = 150.0;

  static Stream<Position> _defaultPositionStreamFactory() =>
      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      );

  static Stream<CompassEvent>? _defaultCompassStreamFactory() =>
      FlutterCompass.events;

  NavigationState _navState = NavigationState.idle;
  Position? _currentPosition;
  Position? _previousPosition;
  LatLng? _destinationLatLng;
  ScoredRoute? _selectedRoute;
  List<LatLng>? _currentRoute;
  bool _isRerouting = false;
  bool _headingUpMode = false;
  double _currentHeading = 0.0;
  double _smoothedHeading = 0.0;
  double _lastCameraHeading = 0.0;
  double? _deviceHeading;
  int _offRouteSampleCount = 0;
  DateTime? _lastRerouteTime;
  LatLng? _lastProgressPosition;
  RouteProgressSplit? _routeProgress;
  double? _routeSafetyScore;
  double? _routeDurationMinutes;
  bool _hasSmoothedHeading = false;
  bool _disposed = false;

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  Timer? _rescoreTimer;
  bool _isRescoring = false;
  NavigationCameraInstruction? _pendingCameraInstruction;
  final bool _isCustomPositionStream;
  final PositionStreamFactory _positionStreamFactory;
  final CompassStreamFactory _compassStreamFactory;

  NavigationState get navState => _navState;
  Position? get currentPosition => _currentPosition;
  Position? get previousPosition => _previousPosition;
  LatLng? get destinationLatLng => _destinationLatLng;
  ScoredRoute? get selectedRoute => _selectedRoute;
  List<LatLng>? get currentRoute => _currentRoute;
  bool get isRerouting => _isRerouting;
  bool get headingUpMode => _headingUpMode;
  double get currentHeading => _currentHeading;
  double get smoothedHeading => _smoothedHeading;
  double get lastCameraHeading => _lastCameraHeading;
  double? get deviceHeading => _deviceHeading;
  int get offRouteSampleCount => _offRouteSampleCount;
  DateTime? get lastRerouteTime => _lastRerouteTime;
  LatLng? get lastProgressPosition => _lastProgressPosition;
  RouteProgressSplit? get routeProgress => _routeProgress;
  double? get routeSafetyScore => _routeSafetyScore;
  double? get routeDurationMinutes => _routeDurationMinutes;
  NavigationCameraInstruction? get pendingCameraInstruction =>
      _pendingCameraInstruction;

  LatLng? get liveUserPoint => _currentPosition == null
      ? null
      : LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

  bool get hasHeading =>
      _deviceHeading != null ||
      (_currentPosition != null &&
          _travelHeadingFromPosition(_currentPosition!) != null);

  VoidCallback? onArrived;
  VoidCallback? onRerouteRequired;
  VoidCallback? onRescoreRequired;
  void Function(double heading)? onHeadingChanged;

  /// Re-scores the active route's geometry against current incident data and
  /// swaps the display payload without changing the planned geometry.
  void applyRescore(ScoredRoute route) {
    if (_navState != NavigationState.active ||
        _isRerouting ||
        _isRescoring) {
      return;
    }
    if (_selectedRoute == null || route.points.isEmpty) {
      return;
    }
    _isRescoring = true;
    try {
      _selectedRoute = route;
      _routeSafetyScore = route.averageSafetyScore;
      if (route.durationMinutes != null) {
        _routeDurationMinutes = route.durationMinutes;
      }
      final LatLng? currentPoint = liveUserPoint;
      if (currentPoint != null) {
        _routeProgress = NavigationMath.splitRouteByNearestPoint(
          currentPoint,
          route.points,
        );
      }
      _notifyIfNotDisposed();
    } finally {
      _isRescoring = false;
    }
  }

  void _startRescoreTimer() {
    _rescoreTimer ??= Timer.periodic(_rescoreInterval, (_) {
      if (_navState != NavigationState.active ||
          _isRerouting ||
          _isRescoring) {
        return;
      }
      onRescoreRequired?.call();
    });
  }

  void _stopRescoreTimer() {
    _rescoreTimer?.cancel();
    _rescoreTimer = null;
  }

  void beginTracking() {
    _startPositionTracking();
  }

  Future<HomeMapLoadResult> loadHomeMap({
    required LocationService locationService,
    required SafetyHeatmapService heatmapService,
    required LatLng fallbackCenter,
  }) async {
    final LatLng center =
        await locationService.getCurrentLocation() ?? fallbackCenter;
    final List<SafetyZone> zones = await heatmapService
        .loadSafetyZonesForPoints(<LatLng>[center], refresh: true);

    stopNavigation();
    return HomeMapLoadResult(center: center, safetyZones: zones);
  }

  Future<RouteLoadResult> loadRoute({
    required LatLng start,
    required LatLng destination,
    required RoutingService routingService,
    required SafetyHeatmapService heatmapService,
    required bool preserveVisibleRoute,
  }) async {
    final bool keepActive = _navState == NavigationState.active;
    final bool preserveExistingRoute =
        keepActive && preserveVisibleRoute && _selectedRoute != null;

    prepareRouteLoad(
      destination: destination,
      preserveVisibleRoute: preserveExistingRoute,
    );

    try {
      final ScoredRoute? safestRoute = await routingService.getSafestRoute(
        start,
        destination,
      );
      final List<LatLng> routePoints = safestRoute?.points ?? <LatLng>[];
      if (routePoints.isEmpty) {
        if (!preserveExistingRoute) {
          handleRouteLoadFailure(preserveVisibleRoute: false);
        }
        return const RouteLoadResult(
          status: RouteLoadStatus.noRoute,
          safetyZones: <SafetyZone>[],
        );
      }

      final List<SafetyZone> nearbyZones = await heatmapService
          .loadSafetyZonesForPoints(<LatLng>[
            start,
            destination,
            ...routePoints,
          ], refresh: true);

      applyLoadedRoute(
        route: safestRoute!,
        destination: destination,
        keepActive: keepActive,
      );
      return RouteLoadResult(
        status: RouteLoadStatus.success,
        safetyZones: nearbyZones,
      );
    } catch (e) {
      debugPrint('NavigationController: route load failed: $e');
      if (!preserveExistingRoute) {
        handleRouteLoadFailure(preserveVisibleRoute: false);
      }
      return const RouteLoadResult(
        status: RouteLoadStatus.error,
        safetyZones: <SafetyZone>[],
      );
    }
  }

  Future<List<SafetyZone>> refreshNearbySafetyZones({
    required SafetyHeatmapService heatmapService,
    required LatLng fallbackPoint,
  }) async {
    final LatLng point = liveUserPoint ?? fallbackPoint;
    return heatmapService.loadSafetyZonesForPoints(<LatLng>[
      point,
    ], refresh: true);
  }

  void prepareRouteLoad({
    required LatLng destination,
    required bool preserveVisibleRoute,
  }) {
    final bool keepActive = _navState == NavigationState.active;
    _destinationLatLng = destination;

    if (!preserveVisibleRoute) {
      _selectedRoute = null;
      _currentRoute = null;
      _routeProgress = null;
      _routeSafetyScore = null;
      _routeDurationMinutes = null;
    }

    if (!keepActive) {
      _navState = NavigationState.idle;
    }

    _notifyIfNotDisposed();
  }

  void applyLoadedRoute({
    required ScoredRoute route,
    required LatLng destination,
    required bool keepActive,
  }) {
    _selectedRoute = route;
    _currentRoute = List<LatLng>.unmodifiable(route.points);
    _destinationLatLng = destination;
    _routeSafetyScore = route.averageSafetyScore;
    _routeDurationMinutes = _estimateRouteDurationMinutes(route);
    _offRouteSampleCount = 0;

    if (keepActive && _currentPosition != null) {
      final LatLng currentPoint = LatLng(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
      _routeProgress = NavigationMath.splitRouteByNearestPoint(
        currentPoint,
        route.points,
      );
      _lastProgressPosition = _routeProgress == null ? null : currentPoint;
    } else {
      _routeProgress = null;
      _lastProgressPosition = null;
    }

    final NavigationState oldState = _navState;
    _navState = keepActive ? NavigationState.active : NavigationState.planning;
    if (oldState != _navState) {
      _updatePositionTrackingSettings();
    }
    _notifyIfNotDisposed();
  }

  void handleRouteLoadFailure({required bool preserveVisibleRoute}) {
    if (preserveVisibleRoute) {
      return;
    }
    _stopRescoreTimer();
    _selectedRoute = null;
    _currentRoute = null;
    _routeProgress = null;
    _routeSafetyScore = null;
    _routeDurationMinutes = null;
    final NavigationState oldState = _navState;
    _navState = NavigationState.idle;
    if (oldState != _navState) {
      _updatePositionTrackingSettings();
    }
    _notifyIfNotDisposed();
  }

  LatLng _cameraFollowPoint(LatLng userPoint) {
    final ScoredRoute? route = _selectedRoute;
    if (_navState != NavigationState.active ||
        route == null ||
        route.points.isEmpty) {
      return userPoint;
    }

    final double distanceToRoute = NavigationMath.distanceToPolylineMeters(
      userPoint,
      route.points,
    );
    if (distanceToRoute <= _maxCameraFollowDistanceMeters) {
      return userPoint;
    }

    // The active mode must stay anchored to the planned route. If the live
    // fix (e.g. an approximate desktop browser location) is far outside the
    // route, follow the nearest projected point instead of jumping away.
    return NavigationMath.nearestPointOnPolyline(userPoint, route.points);
  }

  void startRoute() {
    final ScoredRoute? route = _selectedRoute;
    if (route == null) {
      return;
    }

    final LatLng? currentPoint = liveUserPoint;
    RouteProgressSplit? initialProgress;
    if (currentPoint != null) {
      final double deviceDistanceToRoute =
          NavigationMath.distanceToPolylineMeters(
            currentPoint,
            route.points,
          );
      if (deviceDistanceToRoute > _maxCameraFollowDistanceMeters) {
        // The fix is not realistically near the planned walk (approximate
        // desktop location, VPN, etc). Treat the walk as not yet started
        // instead of projecting onto a random point of the route.
        initialProgress = RouteProgressSplit(
          projectedPoint: route.points.first,
          segmentIndex: 0,
          distanceAlongRouteMeters: 0,
          completedPoints: List<LatLng>.unmodifiable(<LatLng>[
            route.points.first,
          ]),
          remainingPoints: List<LatLng>.unmodifiable(route.points),
        );
      } else {
        initialProgress = NavigationMath.splitRouteByNearestPoint(
          currentPoint,
          route.points,
        );
      }
    }

    final NavigationState oldState = _navState;
    _navState = NavigationState.active;
    if (oldState != _navState) {
      _updatePositionTrackingSettings();
      _startCompassTracking();
    }
    _headingUpMode = hasHeading;
    _offRouteSampleCount = 0;
    _lastProgressPosition = initialProgress == null ? null : currentPoint;
    _routeProgress = initialProgress;
    _startRescoreTimer();

    if (currentPoint != null) {
      final double? heading = NavigationMath.normalizeHeading(
        _deviceHeading ?? _currentHeading,
      );
      _pendingCameraInstruction = NavigationCameraInstruction(
        userPoint: _cameraFollowPoint(currentPoint),
        heading: heading,
        rotateCamera: _headingUpMode && heading != null,
      );
    }

    _notifyIfNotDisposed();
  }

  void stopNavigation() {
    final NavigationState oldState = _navState;
    _navState = NavigationState.idle;
    if (oldState != _navState) {
      _updatePositionTrackingSettings();
    }
    _stopRescoreTimer();
    _compassSubscription?.cancel();
    _compassSubscription = null;
    _destinationLatLng = null;
    _selectedRoute = null;
    _currentRoute = null;
    _isRerouting = false;
    _headingUpMode = false;
    _offRouteSampleCount = 0;
    _lastRerouteTime = null;
    _lastProgressPosition = null;
    _routeProgress = null;
    _routeSafetyScore = null;
    _routeDurationMinutes = null;
    _pendingCameraInstruction = null;
    _notifyIfNotDisposed();
  }

  void resetHeadingUpMode() {
    if (!_headingUpMode) {
      return;
    }

    _headingUpMode = false;
    _notifyIfNotDisposed();
  }

  void enableHeadingUpMode() {
    _headingUpMode = hasHeading;

    final LatLng? userPoint = liveUserPoint;
    if (userPoint != null) {
      final double? heading = NavigationMath.normalizeHeading(
        _deviceHeading ?? _currentHeading,
      );
      _pendingCameraInstruction = NavigationCameraInstruction(
        userPoint: _cameraFollowPoint(userPoint),
        heading: heading,
        rotateCamera: _headingUpMode && heading != null,
      );
    }

    _notifyIfNotDisposed();
  }

  void completeReroute() {
    if (!_isRerouting) {
      return;
    }

    _isRerouting = false;
    _notifyIfNotDisposed();
  }

  void markCameraInstructionHandled() {
    final NavigationCameraInstruction? instruction = _pendingCameraInstruction;
    if (instruction != null &&
        instruction.rotateCamera &&
        instruction.heading != null) {
      _lastCameraHeading = instruction.heading!;
    }
    _pendingCameraInstruction = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRescoreTimer();
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    super.dispose();
  }

  void _startPositionTracking() {
    _positionSubscription?.cancel();

    final Stream<Position> stream;
    if (_isCustomPositionStream) {
      stream = _positionStreamFactory();
    } else {
      final LocationSettings settings;
      if (_navState == NavigationState.active) {
        settings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        );
      } else {
        settings = const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 25,
        );
      }
      stream = Geolocator.getPositionStream(locationSettings: settings);
    }

    _positionSubscription = stream.listen(
      _onPositionUpdate,
      onError: (Object error) {
        debugPrint('Position stream error: $error');
      },
    );
  }

  void _updatePositionTrackingSettings() {
    if (!_isCustomPositionStream && _positionSubscription != null) {
      _startPositionTracking();
    }
  }

  void _startCompassTracking() {
    _compassSubscription?.cancel();

    final Stream<CompassEvent>? headingStream = _compassStreamFactory();
    if (headingStream == null) {
      debugPrint('Compass stream unavailable on this device.');
      return;
    }

    _compassSubscription = headingStream.listen(
      (CompassEvent event) {
        final double? rawHeading = NavigationMath.normalizeHeading(
          event.heading,
        );
        if (_disposed || rawHeading == null) {
          return;
        }

        final double smoothedHeading = _applyHeadingEma(rawHeading);
        final bool headingChanged =
            _deviceHeading == null ||
            NavigationMath.headingDeltaDegrees(
                  _currentHeading,
                  smoothedHeading,
                ).abs() >=
                0.8;

        final bool shouldRotateActiveCamera =
            _navState == NavigationState.active &&
            _headingUpMode &&
            _shouldRotateCamera(_currentPosition) &&
            _shouldUpdateCameraHeading(smoothedHeading);

        if (!headingChanged && !shouldRotateActiveCamera) {
          return;
        }

        _deviceHeading = smoothedHeading;
        _currentHeading = smoothedHeading;
        onHeadingChanged?.call(smoothedHeading);

        final LatLng? userPoint = liveUserPoint;
        if (shouldRotateActiveCamera && userPoint != null) {
          _pendingCameraInstruction = NavigationCameraInstruction(
            userPoint: _cameraFollowPoint(userPoint),
            heading: smoothedHeading,
            rotateCamera: true,
          );
        }

        _notifyIfNotDisposed();
      },
      onError: (Object error) {
        debugPrint('Compass stream error: $error');
      },
    );
  }

  void _onPositionUpdate(Position position) {
    final LatLng userPoint = LatLng(position.latitude, position.longitude);

    try {
      _currentPosition = position;
      _refreshDisplayedHeading(position);

      if (_navState != NavigationState.active) {
        _notifyIfNotDisposed();
        return;
      }

      if (_destinationLatLng != null) {
        final double distanceToDestination = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          _destinationLatLng!.latitude,
          _destinationLatLng!.longitude,
        );

        if (distanceToDestination < 30) {
          _onArrived();
          return;
        }
      }

      _updateRouteProgress(position);

      final bool rotateCamera = _shouldRotateCamera(position) && hasHeading;
      _pendingCameraInstruction = NavigationCameraInstruction(
        userPoint: _cameraFollowPoint(userPoint),
        heading: rotateCamera ? _currentHeading : null,
        rotateCamera: rotateCamera,
      );
      _evaluateOffRoute(position, userPoint);
      _notifyIfNotDisposed();
    } finally {
      _previousPosition = position;
    }
  }

  double _applyHeadingEma(double rawHeading) {
    if (!_hasSmoothedHeading) {
      _hasSmoothedHeading = true;
      _smoothedHeading = rawHeading;
      return _smoothedHeading;
    }

    const double alpha = 0.2;
    double delta = rawHeading - _smoothedHeading;
    if (delta > 180) {
      delta -= 360;
    }
    if (delta < -180) {
      delta += 360;
    }
    _smoothedHeading = (_smoothedHeading + alpha * delta + 360) % 360;
    return _smoothedHeading;
  }

  void _refreshDisplayedHeading(Position position) {
    if (_deviceHeading != null) {
      return;
    }

    final double? rawHeading = _travelHeadingFromPosition(position);
    if (rawHeading == null) {
      return;
    }

    final double effectiveHeading = _applyHeadingEma(rawHeading);
    if (NavigationMath.headingDeltaDegrees(
          _currentHeading,
          effectiveHeading,
        ).abs() >=
        0.8) {
      _currentHeading = effectiveHeading;
      onHeadingChanged?.call(effectiveHeading);
    }
  }

  void _evaluateOffRoute(Position position, LatLng userPoint) {
    final ScoredRoute? route = _selectedRoute;
    if (route == null || route.points.isEmpty) {
      _offRouteSampleCount = 0;
      return;
    }

    final double distanceToRoute = NavigationMath.distanceToPolylineMeters(
      userPoint,
      route.points,
    );
    final bool reliableFix =
        position.accuracy > 0 &&
        position.accuracy <= _maximumReliableAccuracyMeters;
    final bool likelyMoving = _isLikelyMoving(position);
    final double rerouteThreshold = NavigationMath.rerouteThresholdMeters(
      position.accuracy,
    );

    if (reliableFix && likelyMoving && distanceToRoute > rerouteThreshold) {
      _offRouteSampleCount += 1;
    } else {
      _offRouteSampleCount = 0;
      return;
    }

    final DateTime now = DateTime.now();
    final bool cooldownExpired =
        _lastRerouteTime == null ||
        now.difference(_lastRerouteTime!) > _rerouteCooldown;

    if (_offRouteSampleCount >= _offRouteConfirmationSamples &&
        cooldownExpired &&
        !_isRerouting) {
      _lastRerouteTime = now;
      _offRouteSampleCount = 0;
      _reroute();
    }
  }

  void _updateRouteProgress(Position currentPosition, {bool force = false}) {
    final ScoredRoute? route = _selectedRoute;
    if (_navState != NavigationState.active ||
        route == null ||
        route.points.isEmpty) {
      return;
    }

    if (!force && _lastProgressPosition != null) {
      final double moved = Geolocator.distanceBetween(
        _lastProgressPosition!.latitude,
        _lastProgressPosition!.longitude,
        currentPosition.latitude,
        currentPosition.longitude,
      );
      if (moved < 3.0) {
        return;
      }
    }

    final LatLng currentPoint = LatLng(
      currentPosition.latitude,
      currentPosition.longitude,
    );
    if (NavigationMath.distanceToPolylineMeters(
          currentPoint,
          route.points,
        ) >
        _maxCameraFollowDistanceMeters) {
      // Keep the last progress instead of snapping to a far-away fix.
      return;
    }
    final RouteProgressSplit? projected =
        NavigationMath.splitRouteByNearestPoint(currentPoint, route.points);
    if (projected == null) {
      return;
    }

    _lastProgressPosition = currentPoint;
    _routeProgress = projected;
  }

  void _onArrived() {
    final NavigationState oldState = _navState;
    _navState = NavigationState.arrived;
    if (oldState != _navState) {
      _updatePositionTrackingSettings();
    }
    _headingUpMode = false;
    _isRerouting = false;
    _lastRerouteTime = null;
    _offRouteSampleCount = 0;
    _lastProgressPosition = null;
    _pendingCameraInstruction = null;
    _notifyIfNotDisposed();
    onArrived?.call();
  }

  void _reroute() {
    if (_destinationLatLng == null || _isRerouting) {
      return;
    }

    _isRerouting = true;
    _notifyIfNotDisposed();
    onRerouteRequired?.call();
  }

  bool _isLikelyMoving(Position position) {
    if (position.speed >= _minimumLikelyMovementSpeedMps) {
      return true;
    }

    final Position? previousPosition = _previousPosition;
    if (previousPosition == null) {
      return false;
    }

    final double movedMeters = Geolocator.distanceBetween(
      previousPosition.latitude,
      previousPosition.longitude,
      position.latitude,
      position.longitude,
    );
    final double previousAccuracy = previousPosition.accuracy > 0
        ? previousPosition.accuracy
        : _maximumReliableAccuracyMeters;
    final double currentAccuracy = position.accuracy > 0
        ? position.accuracy
        : _maximumReliableAccuracyMeters;
    final double noiseBudget = math.max(
      10,
      math.min(25, (previousAccuracy + currentAccuracy) * 0.6),
    );
    return movedMeters > noiseBudget;
  }

  bool _shouldRotateCamera(Position? position) {
    if (position == null || !_headingUpMode) {
      return false;
    }

    final double speed = position.speed.isFinite && position.speed > 0
        ? position.speed
        : 0;
    return speed >= _minimumHeadingSpeedMps;
  }

  bool _shouldUpdateCameraHeading(double heading) {
    return NavigationMath.headingDeltaDegrees(
          _lastCameraHeading,
          heading,
        ).abs() >
        _cameraHeadingDeadbandDegrees;
  }

  double? _travelHeadingFromPosition(Position position) {
    if (position.speed < _minimumHeadingSpeedMps || position.heading < 0) {
      return null;
    }
    if (position.headingAccuracy > 0 && position.headingAccuracy > 45) {
      return null;
    }
    return NavigationMath.normalizeHeading(position.heading);
  }

  double _estimateRouteDurationMinutes(ScoredRoute route) =>
      route.durationMinutes ??
      (route.totalDistanceMeters / 80).clamp(1, 180).toDouble();

  void _notifyIfNotDisposed() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
