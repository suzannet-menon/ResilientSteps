import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../controllers/navigation_controller.dart';
import '../models/place_suggestion.dart';
import '../models/nearby_place.dart';
import '../models/scored_route.dart';
import '../models/safety_zone.dart';
import '../services/location_service.dart';
import '../services/navigation_math.dart';
import '../services/place_search_service.dart';
import '../services/nearby_places_service.dart';
import '../services/routing_service.dart';
import '../services/safety_heatmap_service.dart';
import '../services/auth_service.dart';
import '../services/saved_places_service.dart';
import '../services/sos_service.dart';
import '../widgets/incident_modal.dart';
import '../widgets/map_layers_builder.dart';
import '../widgets/navigation_card.dart';
import '../widgets/saved_place_chips.dart';
import '../widgets/nearby_places_sheet.dart';
import 'destination_search_screen.dart';
import 'login_screen.dart';
import 'saved_places_screen.dart';
import 'settings_profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static final LatLng _defaultCenter = LatLng(18.5204, 73.8567);
  static const double _markerZoomUpdateThreshold = 0.05;

  final MapController _mapController = MapController();
  final LocationService _locationService = LocationService();
  final RoutingService _routingService = RoutingService();
  final SafetyHeatmapService _heatmapService = SafetyHeatmapService();
  final SosService _sosService = SosService();
  final PlaceSearchService _placeSearchService = PlaceSearchService();
  final NearbyPlacesService _nearbyPlacesService = NearbyPlacesService();
  late final NavigationController _navController;
  StreamSubscription<AuthState>? _authSubscription;

  LatLng _cameraTarget = _defaultCenter;
  // Keep the last real device fix separate from the viewport center.
  LatLng _lastKnownUserPoint = _defaultCenter;
  List<SafetyZone> _safetyZones = <SafetyZone>[];
  bool _isLoadingLocation = true;
  bool _isLoadingRoute = false;
  bool _showSafetyZones = true;
  bool _mapReady = false;
  bool _isNavigationCardExpanded = false;
  double _currentZoom = 14.8;
  String? _destinationLabel;
  List<NearbyPlace> _nearbyPlaces = <NearbyPlace>[];
  bool _isLoadingNearbyPlaces = false;

  // Origin confirmation (Google-Maps style): the live fix is reverse-geocoded
  // into a place name and the user confirms it, or types the real start.
  PlaceSuggestion? _explicitOrigin;
  String? _suggestedOriginLabel;
  bool _originLabelLoading = false;
  bool _originConfirmed = false;

  LatLng get _liveUserPoint =>
      _navController.liveUserPoint ?? _lastKnownUserPoint;

  bool get _showCompassReset =>
      _navController.headingUpMode && _navController.hasHeading;

  IconData get _profileIcon => AuthService.instance.isLoggedIn
      ? Icons.account_circle
      : Icons.account_circle_outlined;

  Color get _profileIconColor =>
      AuthService.instance.isLoggedIn ? Colors.blue : Colors.grey;

  String get _profileTooltip {
    if (!AuthService.instance.isLoggedIn) {
      return 'Sign in';
    }
    final String name = AuthService.instance.displayName.trim();
    return name.isNotEmpty ? name : 'Your Account';
  }

  List<Marker> get _markers {
    // Origin pill: visible whenever a destination exists â€” the route's start
    // (its first point) once loaded, otherwise the planning origin so the pin
    // is already on the map while the route loads.
    final ScoredRoute? route = _navController.selectedRoute;
    final LatLng? destination = _navController.destinationLatLng;
    final LatLng? origin = destination == null
        ? null
        : (route != null && route.points.isNotEmpty
              ? route.points.first
              : _planningStart);
    return MapLayersBuilder.buildNavigationMarkers(
      start: _liveUserPoint,
      destination: destination,
      destinationLabel: _destinationLabel ?? 'Destination',
      heading: _navController.currentHeading,
      zoom: _currentZoom,
      origin: origin,
      originLabel: _explicitOrigin?.title,
    )
      ..addAll(MapLayersBuilder.buildNearbyMarkers(_nearbyPlaces))
      ..addAll(
        MapLayersBuilder.buildIncidentMarkers(
          route?.incidentPoints ?? const <RouteIncidentPoint>[],
        ),
      );
  }

  List<Polyline> get _routePolylines {
    final ScoredRoute? route = _navController.selectedRoute;
    if (route == null) {
      return const <Polyline>[];
    }

    return MapLayersBuilder.buildRoutePolylines(
      route: route,
      progress: _navController.routeProgress,
      navState: _navController.navState,
    );
  }

  @override
  void initState() {
    super.initState();
    _navController = NavigationController()
      ..addListener(_handleNavigationChanged)
      ..onArrived = _handleArrived
      ..onRerouteRequired = () {
        unawaited(_handleRerouteRequired());
      }
      ..onRescoreRequired = () {
        unawaited(_handleRescoreRequired());
      }
      ..beginTracking();
    _authSubscription = AuthService.instance.authStateChanges.listen((
      AuthState event,
    ) {
      if (event.event == AuthChangeEvent.signedIn) {
        if (mounted) {
          setState(() {});
        }
        SavedPlacesService.instance
            .syncFromSupabase()
            .then((_) {
              if (mounted) {
                setState(() {});
              }
            })
            .catchError((_) {});
      }
      if (event.event == AuthChangeEvent.signedOut && mounted) {
        setState(() {});
      }
    });
    _loadHomeMap();
  }

  @override
  void dispose() {
    _sosService.dispose();
    _authSubscription?.cancel();
    _navController.removeListener(_handleNavigationChanged);
    _navController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _handleNavigationChanged() {
    if (!mounted) {
      return;
    }

    _applyPendingCameraInstruction();
    setState(() {
      final LatLng? liveUserPoint = _navController.liveUserPoint;
      if (liveUserPoint != null) {
        _lastKnownUserPoint = liveUserPoint;
        _cameraTarget = liveUserPoint;
      }
    });
  }

  void _handleArrived() {
    _resetMapBearing();
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('You have arrived at your destination.'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  Future<void> _handleRerouteRequired() async {
    final LatLng? destination = _navController.destinationLatLng;
    if (destination == null) {
      _navController.completeReroute();
      return;
    }

    await _loadRoute(
      start: _liveUserPoint,
      destination: destination,
      label: _destinationLabel,
      moveCamera: false,
      preserveVisibleRoute: true,
    );
    _navController.completeReroute();
  }

  Future<void> _handleRescoreRequired() async {
    if (_navController.isRerouting) {
      return;
    }
    final ScoredRoute? route = _navController.selectedRoute;
    if (route == null || route.points.length < 2) {
      return;
    }
    try {
      final ScoredRoute? fresh = await _routingService.rescoreRoute(
        route.points,
      );
      if (!mounted || fresh == null) {
        return;
      }
      if (_navController.navState == NavigationState.active &&
          !_navController.isRerouting) {
        _navController.applyRescore(fresh);
      }
    } catch (e) {
      debugPrint('HomeScreen: live rescore failed: $e');
    }
  }

  void _resetMapBearing() {
    if (_mapReady) {
      _mapController.rotate(0);
    }
  }

  Future<void> _loadHomeMap() async {
    final HomeMapLoadResult result = await _navController.loadHomeMap(
      locationService: _locationService,
      heatmapService: _heatmapService,
      fallbackCenter: _defaultCenter,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _safetyZones = result.safetyZones;
      _isLoadingLocation = false;
      _lastKnownUserPoint = result.center;
      _cameraTarget = result.center;
      _destinationLabel = null;
      _isNavigationCardExpanded = false;
    });

    _mapController.move(result.center, 15.2);
    unawaited(_resolveOriginLabel(result.center));
  }

  Future<void> _resolveOriginLabel(LatLng point) async {
    setState(() {
      _originLabelLoading = true;
      _suggestedOriginLabel = null;
    });

    PlaceSuggestion? suggestion;
    try {
      suggestion = await _placeSearchService.reverseGeocode(
        point.latitude,
        point.longitude,
      );
    } catch (_) {
      suggestion = null;
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _originLabelLoading = false;
      _suggestedOriginLabel = suggestion?.title;
    });
  }

  /// Start point used for route planning: a user-typed origin beats the live
  /// GPS fix. Active navigation/rerouting always stays on the live point.
  LatLng get _planningStart => _explicitOrigin?.point ?? _liveUserPoint;

  /// Short badge text (Nearby: place) for the confirmed start point.
  /// Appears only after the Yes/No origin banner has been answered so the
  /// badge anchor is a place the user actually endorsed.
  String? get _startNearbyBadgeLabel {
    if (_originLabelLoading) {
      return null;
    }
    if (_explicitOrigin == null && !_originConfirmed) {
      return null;
    }
    final String? title = _explicitOrigin?.title ?? _suggestedOriginLabel;
    if (title == null || title.isEmpty) {
      return null;
    }
    return _badgeLabel(title);
  }

  /// Short badge text for the chosen destination, visible once a destination
  /// point (not just a loading label) exists.
  String? get _endNearbyBadgeLabel {
    if (_destinationAnchorPoint == null) {
      return null;
    }
    final String label = _destinationLabel ?? '';
    if (label.isEmpty) {
      return null;
    }
    return _badgeLabel(label);
  }

  LatLng? get _destinationAnchorPoint {
    final LatLng? destination = _navController.destinationLatLng;
    if (destination != null) {
      return destination;
    }
    final ScoredRoute? route = _navController.selectedRoute;
    if (route != null && route.points.isNotEmpty) {
      return route.points.last;
    }
    return null;
  }

  /// Keeps badge chips readable: first comma segment, capped at 18 chars.
  String _badgeLabel(String title) {
    final String primary = title.split(',').first.trim();
    const int max = 18;
    return primary.length <= max ? primary : '${primary.substring(0, max)}â€¦';
  }

  Future<void> _confirmOrigin() async {
    setState(() {
      _originConfirmed = true;
      _explicitOrigin = null;
    });
  }

  Future<void> _changeOrigin() async {
    final PlaceSuggestion? origin = await Navigator.of(context)
        .push<PlaceSuggestion>(
          MaterialPageRoute<PlaceSuggestion>(
            builder: (_) => DestinationSearchScreen(
              placeSearchService: _placeSearchService,
              pickSource: true,
            ),
          ),
        );

    if (!mounted || origin == null) {
      return;
    }

    setState(() {
      _explicitOrigin = origin;
      _originConfirmed = true;
    });

    final LatLng? destination = _navController.destinationLatLng;
    if (destination != null) {
      // Destination already chosen (e.g. route still pending retry) â€” reload
      // the route from the newly typed origin.
      await _setDestination(destination.latitude, destination.longitude, _destinationLabel ?? 'Pinned destination');
    } else {
      await _openDestinationSearch(initialQuery: null);
    }
  }

  Future<void> _loadRoute({
    required LatLng start,
    required LatLng destination,
    String? label,
    bool moveCamera = true,
    bool preserveVisibleRoute = false,
  }) async {
    if (_isLoadingLocation || _isLoadingRoute) {
      return;
    }

    final bool preserveExistingRoute =
        _navController.navState == NavigationState.active &&
        preserveVisibleRoute &&
        _navController.selectedRoute != null;

    setState(() {
      _destinationLabel = label ?? _destinationLabel ?? 'Pinned destination';
      _isLoadingRoute = true;
      if (_navController.navState != NavigationState.active) {
        _isNavigationCardExpanded = false;
      }
    });

    if (moveCamera) {
      _mapController.move(destination, 15.8);
    }

    final RouteLoadResult result = await _navController.loadRoute(
      start: start,
      destination: destination,
      routingService: _routingService,
      heatmapService: _heatmapService,
      preserveVisibleRoute: preserveVisibleRoute,
    );
    if (!mounted) {
      return;
    }

    if (result.safetyZones.isNotEmpty) {
      setState(() {
        _safetyZones = result.safetyZones;
      });
    }

    if (!preserveExistingRoute && result.status == RouteLoadStatus.noRoute) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No walking route found. Try another nearby point.'),
        ),
      );
    }

    if (!preserveExistingRoute && result.status == RouteLoadStatus.error) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not find a route right now. Try another destination.',
          ),
        ),
      );
    }

    if (mounted) {
      setState(() {
        _isLoadingRoute = false;
      });
    }
  }

  Future<void> _refreshNearbySafetyZones() async {
    final List<SafetyZone> zones = await _navController
        .refreshNearbySafetyZones(
          heatmapService: _heatmapService,
          fallbackPoint: _cameraTarget,
        );
    if (!mounted || zones.isEmpty) {
      return;
    }
    setState(() {
      _safetyZones = zones;
    });
  }

  Future<void> _openDestinationSearch({String? initialQuery}) async {
    final PlaceSuggestion? suggestion = await Navigator.of(context)
        .push<PlaceSuggestion>(
          MaterialPageRoute<PlaceSuggestion>(
            builder: (_) => DestinationSearchScreen(
              placeSearchService: _placeSearchService,
              initialQuery: initialQuery,
            ),
          ),
        );

    if (!mounted || suggestion == null) {
      return;
    }

    await _setDestination(
      suggestion.point.latitude,
      suggestion.point.longitude,
      suggestion.title,
    );
  }

  /// Fetches nearby places for a single badge anchor point and updates the
  /// map markers. Returns null when skipped (a load already in flight) or
  /// failed (a snackbar was shown). Does not open the results sheet.
  Future<List<NearbyPlace>?> _fetchNearbyForAnchor({
    required NearbyCategory category,
    required LatLng anchor,
    required NearbyAnchor anchorType,
  }) async {
    if (_isLoadingNearbyPlaces) {
      return null;
    }
    setState(() {
      _isLoadingNearbyPlaces = true;
      _nearbyPlaces = <NearbyPlace>[];
    });
    try {
      final List<NearbyPlace> places = await _nearbyPlacesService
          .findNearbyForAnchors(
            category: category,
            start: anchorType == NearbyAnchor.routeStart ? anchor : null,
            end: anchorType == NearbyAnchor.routeEnd ? anchor : null,
          );
      if (!mounted) {
        return null;
      }
      setState(() {
        _nearbyPlaces = places;
        _isLoadingNearbyPlaces = false;
      });
      return places;
    } catch (error) {
      if (!mounted) {
        return null;
      }
      setState(() => _isLoadingNearbyPlaces = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
      return null;
    }
  }

  Future<void> _showNearbyResultsSheet(
    NearbyCategory category,
    List<NearbyPlace> places,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => NearbyPlacesSheet(
        category: category,
        places: places,
        onPlaceSelected: (NearbyPlace place) {
          Navigator.of(context).pop();
          _setDestination(place.latitude, place.longitude, place.name);
        },
      ),
    );
  }

  /// Opens the "Nearby places to <title>" chooser sheet; picking a category
  /// searches around [anchor], closes the chooser and shows the results
  /// (bifurcated by type when "All" is chosen).
  Future<void> _openNearbyPicker({
    required String title,
    required LatLng anchor,
    required NearbyAnchor anchorType,
  }) async {
    NearbyCategory? chosen;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (
          BuildContext _,
          void Function(void Function()) setSheetState,
        ) {
          return NearbyCategoryPickerSheet(
            title: 'Nearby places to $title',
            isLoading: chosen != null,
            onCategorySelected: (NearbyCategory category) async {
              if (chosen != null) {
                return;
              }
              chosen = category;
              setSheetState(() {});
              final List<NearbyPlace>? places = await _fetchNearbyForAnchor(
                category: category,
                anchor: anchor,
                anchorType: anchorType,
              );
              if (!sheetContext.mounted) {
                return;
              }
              // The picker is still the top route here; close it before
              // the results sheet appears.
              Navigator.of(sheetContext).pop();
              if (places == null || !mounted) {
                return;
              }
              _mapController.move(anchor, 15.2);
              await _showNearbyResultsSheet(category, places);
            },
          );
        },
      ),
    );
  }

  void _clearRoute() {
    setState(() {
      _destinationLabel = null;
      _isNavigationCardExpanded = false;
    });
    _navController.stopNavigation();
    unawaited(_refreshNearbySafetyZones());
    _resetMapBearing();
    _moveCameraToUser(zoom: 15.2);
  }

  void _recenterOnUser() {
    final LatLng userPoint = _liveUserPoint;
    _cameraTarget = userPoint;

    if (_navController.navState == NavigationState.active) {
      _navController.enableHeadingUpMode();
      final double zoom = _mapController.camera.zoom;
      final double? heading = _navController.hasHeading
          ? NavigationMath.normalizeHeading(_navController.currentHeading)
          : null;

      if (_navController.headingUpMode && heading != null) {
        _mapController.moveAndRotate(
          _cameraFollowTarget(userPoint, heading),
          zoom,
          -heading,
        );
      } else {
        _mapController.move(userPoint, zoom);
      }
      return;
    }

    _moveCameraToUser(zoom: 15.2);
  }

  void _toggleSafetyZones() {
    setState(() {
      _showSafetyZones = !_showSafetyZones;
    });
  }

  void _onCompassResetPressed() {
    _resetMapBearing();
    _navController.resetHeadingUpMode();
  }

  void _handleStartNavigation() {
    _navController.startRoute();
    _applyPendingCameraInstruction();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Route started. Follow the highlighted path and keep an eye on nearby danger zones.',
        ),
      ),
    );
  }

  void _handleStopNavigation() {
    setState(() {
      _destinationLabel = null;
      _isNavigationCardExpanded = false;
    });
    _navController.stopNavigation();
    _resetMapBearing();
    unawaited(_refreshNearbySafetyZones());
  }

  double _forwardLookDistanceMeters(double zoom) {
    final double scaledDistance = 24 + ((18 - zoom) * 8);
    return scaledDistance.clamp(18.0, 56.0).toDouble();
  }

  LatLng _cameraFollowTarget(LatLng userPoint, double? heading) {
    if (!_navController.headingUpMode || heading == null) {
      return userPoint;
    }

    return NavigationMath.offsetPoint(
      userPoint,
      distanceMeters: _forwardLookDistanceMeters(_currentZoom),
      headingDegrees: heading,
    );
  }

  void _applyPendingCameraInstruction() {
    if (!_mapReady) {
      return;
    }

    final NavigationCameraInstruction? instruction =
        _navController.pendingCameraInstruction;
    if (instruction == null) {
      return;
    }

    final double zoom = _mapController.camera.zoom;
    if (instruction.rotateCamera && instruction.heading != null) {
      _mapController.moveAndRotate(
        _cameraFollowTarget(instruction.userPoint, instruction.heading),
        zoom,
        -instruction.heading!,
      );
    } else {
      _mapController.move(instruction.userPoint, zoom);
    }

    _navController.markCameraInstructionHandled();
  }

  void _moveCameraToUser({required double zoom}) {
    final LatLng userPoint = _liveUserPoint;
    _cameraTarget = userPoint;
    _mapController.move(userPoint, zoom);
  }

  Future<void> _setDestination(double lat, double lon, String name) async {
    await _loadRoute(
      start: _planningStart,
      destination: LatLng(lat, lon),
      label: name,
    );
  }

  void _showAuthRequiredDialog(
    BuildContext context, {
    required String feature,
    required String reason,
  }) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Sign in required'),
        content: Text('$feature requires a ResilientSteps account.\n\n$reason'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Not now'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
              );
            },
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
  }

  Future<void> _openIncidentReport() async {
    if (!AuthService.instance.isLoggedIn) {
      _showAuthRequiredDialog(
        context,
        feature: 'Incident reporting',
        reason:
            'Reports are linked to your account so the community can trust them.',
      );
      return;
    }

    await showIncidentReportDialog(
      context: context,
      initialLocation: _navController.destinationLatLng ?? _cameraTarget,
    );
  }

  Future<void> _triggerSos() async {
    if (!AuthService.instance.isLoggedIn) {
      _showAuthRequiredDialog(
        context,
        feature: 'SOS alerts',
        reason:
            'SOS requires an account to link your trusted contacts and location.',
      );
      return;
    }

    await showSosIncidentDialog(context: context, sosService: _sosService);
  }

  void _openProfileScreen() {
    if (!AuthService.instance.isLoggedIn) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      );
      return;
    }
    unawaited(_showProfileDropdown());
  }

  Future<void> _showProfileDropdown() async {
    final AuthService auth = AuthService.instance;
    final RenderBox? overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final Size overlaySize = overlayBox?.size ?? MediaQuery.of(context).size;
    final double top = MediaQuery.of(context).padding.top + 60;
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        overlaySize.width > 280 ? overlaySize.width - 260 : 0,
        top,
        0,
        0,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 8,
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              const CircleAvatar(
                radius: 20,
                child: Icon(Icons.person, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      auth.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      auth.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'settings',
          height: 44,
          child: Text('Safety customization'),
        ),
        const PopupMenuItem<String>(
          value: 'report',
          height: 44,
          child: Text('Incident reporting'),
        ),
        const PopupMenuItem<String>(
          value: 'saved',
          height: 44,
          child: Text('Saved places'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'sign_out',
          height: 44,
          child: Text('Sign Out', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
    if (choice == null || !mounted) {
      return;
    }
    switch (choice) {
      case 'settings':
      case 'saved':
        final VoidCallback onTap;
        if (choice == 'saved') {
          onTap = () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SavedPlacesScreen(),
                ),
              );
        } else {
          onTap = () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsProfileScreen(),
                ),
              );
        }
        onTap();
      case 'report':
        await _openIncidentReport();
      case 'sign_out':
        final bool? confirm = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text('Sign out?'),
            content: const Text(
              'You will need to sign in again to report incidents or use SOS.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text(
                  'Sign out',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        );
        if (confirm == true && mounted) {
          await AuthService.instance.signOut();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final NavigationState navState = _navController.navState;
    // Idle bottom sheet: search field only (~76px, ~136px when a failed
    // destination stays in the sheet). Planning/loading comparison sheet is
    // ~400px; the active collapsed strip with metric cards ~300px; unanswered
    // origin banner adds ~70px.
    final bool originNeedsConfirm =
        _originLabelLoading ||
        (_explicitOrigin == null && !_originConfirmed);
    final double idleBottomOffset = originNeedsConfirm ? 210 : 140;
    final double actionBottomOffset =
        navState == NavigationState.active && !_isNavigationCardExpanded
        ? 300
        : navState == NavigationState.planning || _isLoadingRoute
        ? 400
        : navState == NavigationState.arrived
        ? 220
        : _destinationLabel != null
        ? 220
        : idleBottomOffset;

    return Scaffold(
      body: HomeScreenBody(
        mapController: _mapController,
        initialCenter: _cameraTarget,
        safetyZones: _safetyZones,
        showSafetyZones: _showSafetyZones,
        routePolylines: _routePolylines,
        markers: _markers,
        destinationLabel: _destinationLabel,
        isLoadingRoute: _isLoadingRoute,
        isLoadingLocation: _isLoadingLocation,
        showHintChip: _navController.selectedRoute == null && !_isLoadingRoute,
        showCompassReset: _showCompassReset,
        actionBottomOffset: actionBottomOffset,
        navState: navState,
        route: _navController.selectedRoute,
        isRerouting: _navController.isRerouting,
        savedPlacesBar: AuthService.instance.isLoggedIn
            ? SavedPlaceChips(
                onPlaceSelected: (double lat, double lon, String name) =>
                    _setDestination(lat, lon, name),
              )
            : null,
        onMapReady: () {
          _mapReady = true;
          _applyPendingCameraInstruction();
          if (mounted) {
            setState(() {});
          }
        },
        onMapTap: (LatLng point) {
          _setDestination(
            point.latitude,
            point.longitude,
            'Pinned destination',
          );
        },
        onPositionChanged: (MapCamera camera) {
          _cameraTarget = camera.center;
          final double zoomDelta = (camera.zoom - _currentZoom).abs();
          if (zoomDelta < _markerZoomUpdateThreshold) {
            _currentZoom = camera.zoom;
            return;
          }

          if (!mounted) {
            _currentZoom = camera.zoom;
            return;
          }

          setState(() {
            _currentZoom = camera.zoom;
          });
        },
        onRecenter: _recenterOnUser,
        onSearchTap: () {
          unawaited(_openDestinationSearch(initialQuery: _destinationLabel));
        },
        onClearRoute: _destinationLabel == null || _isLoadingRoute
            ? null
            : _clearRoute,
        profileIcon: _profileIcon,
        profileIconColor: _profileIconColor,
        profileTooltip: _profileTooltip,
        onOpenProfile: _openProfileScreen,
        onToggleSafetyZones: _toggleSafetyZones,
        onResetCompass: _onCompassResetPressed,
        onReportIncident: _openIncidentReport,
        onTriggerSos: _triggerSos,
        onStartNavigation: _handleStartNavigation,
        onStopNavigation: _handleStopNavigation,
        onDismissArrival: _handleStopNavigation,
        originLabel: _explicitOrigin?.title ?? _suggestedOriginLabel,
        originLoading: _originLabelLoading,
        originNeedsConfirm: _explicitOrigin == null && !_originConfirmed,
        onOriginConfirm: () {
          unawaited(_confirmOrigin());
        },
        onChangeOrigin: () {
          unawaited(_changeOrigin());
        },
        onCardExpansionChanged: (bool isExpanded) {
          if (_isNavigationCardExpanded == isExpanded) {
            return;
          }
          setState(() {
            _isNavigationCardExpanded = isExpanded;
          });
        },
        startNearbyLabel: _startNearbyBadgeLabel == null
            ? null
            : 'Nearby: $_startNearbyBadgeLabel',
        endNearbyLabel: _endNearbyBadgeLabel == null
            ? null
            : 'Nearby: $_endNearbyBadgeLabel',
        onStartNearby: () {
          unawaited(
            _openNearbyPicker(
              title: _startNearbyBadgeLabel ?? 'your start point',
              anchor: _planningStart,
              anchorType: NearbyAnchor.routeStart,
            ),
          );
        },
        onEndNearby: () {
          final LatLng? anchor = _destinationAnchorPoint;
          if (anchor == null) {
            return;
          }
          unawaited(
            _openNearbyPicker(
              title: _endNearbyBadgeLabel ?? 'your destination',
              anchor: anchor,
              anchorType: NearbyAnchor.routeEnd,
            ),
          );
        },
      ),
    );
  }
}


