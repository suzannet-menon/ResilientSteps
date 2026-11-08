import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/controllers/navigation_controller.dart';
import 'package:mobile/models/route_segment_safety.dart';
import 'package:mobile/models/scored_route.dart';
import 'package:mobile/widgets/map_layers_builder.dart';

void main() {
  group('Navigation regression', () {
    test('user marker follows GPS input instead of map center', () async {
      final StreamController<Position> positionUpdates =
          StreamController<Position>();
      final NavigationController controller = NavigationController(
        positionStreamFactory: () => positionUpdates.stream,
        compassStreamFactory: () => const Stream<CompassEvent>.empty(),
      );
      addTearDown(() async {
        controller.dispose();
        await positionUpdates.close();
      });

      controller.beginTracking();

      positionUpdates.add(
        _position(latitude: 18.5200, longitude: 73.8560, heading: 90),
      );
      await _flushEvents();

      positionUpdates.add(
        _position(latitude: 18.5212, longitude: 73.8574, heading: 95),
      );
      await _flushEvents();

      const LatLng mapCenter = LatLng(18.5300, 73.8700);
      final markers = MapLayersBuilder.buildNavigationMarkers(
        start: controller.liveUserPoint!,
        destination: null,
        destinationLabel: 'Destination',
        heading: controller.currentHeading,
        zoom: 15.0,
      );

      expect(markers, hasLength(1));
      expect(markers.first.point.latitude, closeTo(18.5212, 0.000001));
      expect(markers.first.point.longitude, closeTo(73.8574, 0.000001));
      expect(markers.first.point.latitude, isNot(closeTo(mapCenter.latitude, 0.000001)));
      expect(
        markers.first.point.longitude,
        isNot(closeTo(mapCenter.longitude, 0.000001)),
      );
    });

    test('origin pill marker appears at the route start when provided', () {
      const LatLng user = LatLng(18.5200, 73.8560);
      const LatLng start = LatLng(18.5245, 73.8555);
      const LatLng destination = LatLng(18.5300, 73.8600);

      final List<Marker> base = MapLayersBuilder.buildNavigationMarkers(
        start: user,
        destination: destination,
        destinationLabel: 'Destination',
        heading: 90,
        zoom: 15.0,
      );
      final List<Marker> withStart = MapLayersBuilder.buildNavigationMarkers(
        start: user,
        destination: destination,
        destinationLabel: 'Destination',
        heading: 90,
        zoom: 15.0,
        origin: start,
        originLabel: 'Spicer Adventist University',
      );
      expect(base, hasLength(2));
      expect(withStart, hasLength(3));
      final Marker startMarker = withStart
          .firstWhere((Marker marker) => marker.point == start);
      expect(startMarker.point.latitude, closeTo(18.5245, 0.0000001));
      expect(startMarker.point.longitude, closeTo(73.8555, 0.0000001));
    });

    test('origin pill is absent when no origin is passed', () {
      const LatLng destination = LatLng(18.5300, 73.8600);
      final List<Marker> base = MapLayersBuilder.buildNavigationMarkers(
        start: const LatLng(18.5200, 73.8560),
        destination: destination,
        destinationLabel: 'Destination',
        heading: 90,
        zoom: 15.0,
      );
      expect(base, hasLength(2));
    });

    test('recenter targets the current user position', () async {
      final StreamController<Position> positionUpdates =
          StreamController<Position>();
      final NavigationController controller = NavigationController(
        positionStreamFactory: () => positionUpdates.stream,
        compassStreamFactory: () => const Stream<CompassEvent>.empty(),
      );
      addTearDown(() async {
        controller.dispose();
        await positionUpdates.close();
      });

      controller.beginTracking();
      positionUpdates.add(
        _position(latitude: 18.5200, longitude: 73.8560, heading: 48),
      );
      await _flushEvents();

      controller.applyLoadedRoute(
        route: _buildRoute(),
        destination: const LatLng(18.5200, 73.8580),
        keepActive: false,
      );
      controller.startRoute();
      controller.markCameraInstructionHandled();
      controller.resetHeadingUpMode();

      controller.enableHeadingUpMode();

      final instruction = controller.pendingCameraInstruction;
      expect(instruction, isNotNull);
      expect(instruction!.userPoint.latitude, closeTo(18.5200, 0.000001));
      expect(instruction.userPoint.longitude, closeTo(73.8560, 0.000001));
      expect(instruction.rotateCamera, isTrue);
      expect(instruction.heading, isNotNull);
    });

    test('starting navigation enables follow mode', () async {
      final StreamController<Position> positionUpdates =
          StreamController<Position>();
      final NavigationController controller = NavigationController(
        positionStreamFactory: () => positionUpdates.stream,
        compassStreamFactory: () => const Stream<CompassEvent>.empty(),
      );
      addTearDown(() async {
        controller.dispose();
        await positionUpdates.close();
      });

      controller.beginTracking();
      positionUpdates.add(
        _position(latitude: 18.5200, longitude: 73.8560, heading: 32),
      );
      await _flushEvents();

      controller.applyLoadedRoute(
        route: _buildRoute(),
        destination: const LatLng(18.5200, 73.8580),
        keepActive: false,
      );

      controller.startRoute();

      expect(controller.navState, NavigationState.active);
      expect(controller.headingUpMode, isTrue);
      expect(controller.pendingCameraInstruction, isNotNull);
      expect(controller.pendingCameraInstruction!.rotateCamera, isTrue);
    });

    test('stopping navigation clears route and resets state', () async {
      final StreamController<Position> positionUpdates =
          StreamController<Position>();
      final NavigationController controller = NavigationController(
        positionStreamFactory: () => positionUpdates.stream,
        compassStreamFactory: () => const Stream<CompassEvent>.empty(),
      );
      addTearDown(() async {
        controller.dispose();
        await positionUpdates.close();
      });

      controller.beginTracking();
      positionUpdates.add(
        _position(latitude: 18.5200, longitude: 73.8560, heading: 32),
      );
      await _flushEvents();

      controller.applyLoadedRoute(
        route: _buildRoute(),
        destination: const LatLng(18.5200, 73.8580),
        keepActive: false,
      );
      controller.startRoute();

      controller.stopNavigation();

      expect(controller.navState, NavigationState.idle);
      expect(controller.destinationLatLng, isNull);
      expect(controller.selectedRoute, isNull);
      expect(controller.currentRoute, isNull);
      expect(controller.routeProgress, isNull);
      expect(controller.headingUpMode, isFalse);
      expect(controller.pendingCameraInstruction, isNull);
    });

    test('route progress updates as mocked positions move along the route', () async {
      final StreamController<Position> positionUpdates =
          StreamController<Position>();
      final NavigationController controller = NavigationController(
        positionStreamFactory: () => positionUpdates.stream,
        compassStreamFactory: () => const Stream<CompassEvent>.empty(),
      );
      addTearDown(() async {
        controller.dispose();
        await positionUpdates.close();
      });

      controller.beginTracking();
      positionUpdates.add(
        _position(latitude: 18.5200, longitude: 73.8560, heading: 90),
      );
      await _flushEvents();

      controller.applyLoadedRoute(
        route: _buildRoute(),
        destination: const LatLng(18.5200, 73.8580),
        keepActive: false,
      );
      controller.startRoute();

      final initialProgress = controller.routeProgress;
      expect(initialProgress, isNotNull);

      positionUpdates.add(
        _position(latitude: 18.5200, longitude: 73.8572, heading: 90),
      );
      await _flushEvents();

      final updatedProgress = controller.routeProgress;
      expect(updatedProgress, isNotNull);
      expect(
        updatedProgress!.distanceAlongRouteMeters,
        greaterThan(initialProgress!.distanceAlongRouteMeters),
      );
      expect(
        controller.lastProgressPosition!.longitude,
        closeTo(73.8572, 0.000001),
      );
      expect(updatedProgress.remainingPoints.length, lessThanOrEqualTo(2));
    });

    test('applyRescore swaps display payload while keeping geometry', () async {
      final StreamController<Position> positionUpdates =
          StreamController<Position>();
      final NavigationController controller = NavigationController(
        positionStreamFactory: () => positionUpdates.stream,
        compassStreamFactory: () => const Stream<CompassEvent>.empty(),
      );
      addTearDown(() async {
        controller.dispose();
        await positionUpdates.close();
      });

      controller.beginTracking();
      positionUpdates.add(
        _position(latitude: 18.5200, longitude: 73.8560, heading: 90),
      );
      await _flushEvents();

      controller.applyLoadedRoute(
        route: _buildRoute(),
        destination: const LatLng(18.5200, 73.8580),
        keepActive: false,
      );
      controller.startRoute();

      final ScoredRoute original = controller.selectedRoute!;
      final ScoredRoute rescored = _buildRescoredRoute();

      controller.applyRescore(rescored);

      expect(controller.selectedRoute, same(rescored));
      expect(controller.routeSafetyScore, 55);
      expect(controller.selectedRoute!.points, original.points);
      expect(controller.navState, NavigationState.active);
      expect(controller.routeProgress, isNotNull);
    });

    test('applyRescore is ignored outside active navigation', () {
      final NavigationController controller = NavigationController(
        positionStreamFactory: () => const Stream<Position>.empty(),
        compassStreamFactory: () => const Stream<CompassEvent>.empty(),
      );
      addTearDown(controller.dispose);

      controller.applyLoadedRoute(
        route: _buildRoute(),
        destination: const LatLng(18.5200, 73.8580),
        keepActive: false,
      );

      controller.applyRescore(_buildRescoredRoute());

      expect(controller.navState, NavigationState.planning);
      expect(controller.selectedRoute!.averageSafetyScore, 79);
      expect(controller.routeSafetyScore, 79);
    });

    test('rescore ticker fires only while navigation is active', () {
      fakeAsync((async) {
        final NavigationController controller = NavigationController(
          positionStreamFactory: () => const Stream<Position>.empty(),
          compassStreamFactory: () => const Stream<CompassEvent>.empty(),
        );
        addTearDown(controller.dispose);

        controller.applyLoadedRoute(
          route: _buildRoute(),
          destination: const LatLng(18.5200, 73.8580),
          keepActive: false,
        );
        controller.startRoute();

        var rescoreCalls = 0;
        controller.onRescoreRequired = () => rescoreCalls++;

        async.elapse(const Duration(minutes: 3));
        expect(rescoreCalls, 1);

        async.elapse(const Duration(minutes: 3));
        expect(rescoreCalls, 2);

        controller.stopNavigation();
        async.elapse(const Duration(minutes: 10));
        expect(rescoreCalls, 2);
      });
    });
  });
}

ScoredRoute _buildRescoredRoute() {
  return const ScoredRoute(
    points: [
      LatLng(18.5200, 73.8560),
      LatLng(18.5200, 73.8570),
      LatLng(18.5200, 73.8580),
    ],
    segments: [
      RouteSegmentSafety(
        start: LatLng(18.5200, 73.8560),
        end: LatLng(18.5200, 73.8570),
        distanceMeters: 110,
        safetyScore: 52,
        incidentRisk: 0.4,
        timeOfDayRisk: 0.1,
        lightingLevel: 0.8,
        crowdDensity: 0.4,
        distanceWeight: 1,
        safetyPenalty: 12,
        risk: 14,
        safetyLevel: 'CAUTION',
      ),
      RouteSegmentSafety(
        start: LatLng(18.5200, 73.8570),
        end: LatLng(18.5200, 73.8580),
        distanceMeters: 110,
        safetyScore: 60,
        incidentRisk: 0.3,
        timeOfDayRisk: 0.1,
        lightingLevel: 0.7,
        crowdDensity: 0.5,
        distanceWeight: 1,
        safetyPenalty: 8,
        risk: 9,
        safetyLevel: 'CAUTION',
      ),
    ],
    totalDistanceMeters: 220,
    averageSafetyScore: 55,
    totalRisk: 12,
    comfortScore: 40,
    comfortLevel: 'Moderate',
  );
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Position _position({
  required double latitude,
  required double longitude,
  required double heading,
}) {
  return Position(
    latitude: latitude,
    longitude: longitude,
    timestamp: DateTime.utc(2026, 4, 6, 12),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: heading,
    headingAccuracy: 5,
    speed: 1.4,
    speedAccuracy: 0.2,
  );
}

ScoredRoute _buildRoute() {
  return const ScoredRoute(
    points: [
      LatLng(18.5200, 73.8560),
      LatLng(18.5200, 73.8570),
      LatLng(18.5200, 73.8580),
    ],
    segments: [
      RouteSegmentSafety(
        start: LatLng(18.5200, 73.8560),
        end: LatLng(18.5200, 73.8570),
        distanceMeters: 110,
        safetyScore: 82,
        incidentRisk: 0.1,
        timeOfDayRisk: 0.1,
        lightingLevel: 0.8,
        crowdDensity: 0.4,
        distanceWeight: 1,
        safetyPenalty: 2,
        risk: 3,
        safetyLevel: 'SAFE',
      ),
      RouteSegmentSafety(
        start: LatLng(18.5200, 73.8570),
        end: LatLng(18.5200, 73.8580),
        distanceMeters: 110,
        safetyScore: 76,
        incidentRisk: 0.2,
        timeOfDayRisk: 0.1,
        lightingLevel: 0.7,
        crowdDensity: 0.5,
        distanceWeight: 1,
        safetyPenalty: 3,
        risk: 4,
        safetyLevel: 'SAFE',
      ),
    ],
    totalDistanceMeters: 220,
    averageSafetyScore: 79,
    totalRisk: 7,
  );
}
