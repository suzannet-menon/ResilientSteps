import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/reporting_api_service.dart';
import '../services/sos_service.dart';
import '../services/waste_reporting_api_service.dart';
import 'gradient_button.dart';

enum IncidentModalMode { report, sos }

Future<void> showSosIncidentDialog({
  required BuildContext context,
  required SosService sosService,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Close SOS',
    barrierColor: Colors.black.withValues(alpha: 0.30),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) => Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Center(
              child: IncidentModal.sos(
                sosService: sosService,
                onClose: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ),
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          final Animation<double> curvedAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curvedAnimation,
            child: ScaleTransition(
              scale: Tween<double>(
                begin: 0.96,
                end: 1,
              ).animate(curvedAnimation),
              child: child,
            ),
          );
        },
  );
}

class IncidentModal extends StatefulWidget {
  const IncidentModal({super.key, required this.initialLocation, this.onClose})
    : mode = IncidentModalMode.report,
      sosService = null;

  const IncidentModal.sos({super.key, required this.sosService, this.onClose})
    : mode = IncidentModalMode.sos,
      initialLocation = null;

  final IncidentModalMode mode;
  final LatLng? initialLocation;
  final SosService? sosService;
  final VoidCallback? onClose;

  @override
  State<IncidentModal> createState() => _IncidentModalState();
}

class _IncidentModalState extends State<IncidentModal> {
  static const List<_IncidentCategory> _incidentTypes = <_IncidentCategory>[
    _IncidentCategory(label: 'Poor lighting', value: 'Poor lighting'),
    _IncidentCategory(
      label: 'Suspicious Activity',
      value: 'Suspicious Activity',
    ),
    _IncidentCategory(
      label: 'Unsafe infrastructure',
      value: 'Unsafe infrastructure',
    ),
    _IncidentCategory(
      label: 'No shade / heavy sun',
      value: 'No shade / heavy sun',
    ),
    _IncidentCategory(
      label: 'Shade blocked',
      value: 'Shade blocked (overgrown / construction)',
    ),
    _IncidentCategory(
      label: 'Heat stress',
      value: 'Heat stress / too hot to walk',
    ),
    _IncidentCategory(
      label: 'Cool shaded spot',
      value: 'Cool shaded spot / water available',
    ),
    // Waste module pills (same round chip row). Selecting one submits to
    // /waste/reports so the dashboard Waste column receives it
    // (report_type='waste') — not to the safety endpoint.
    _IncidentCategory(label: 'Overflowing bin', value: 'overflowing_bin'),
    _IncidentCategory(label: 'Illegal dumping', value: 'illegal_dumping'),
    _IncidentCategory(label: 'Construction debris', value: 'construction_debris'),
    _IncidentCategory(label: 'Garbage burning', value: 'garbage_burning'),
    _IncidentCategory(label: 'Dead animal', value: 'dead_animal'),
  ];

  static const Set<String> _wasteCategoryValues = <String>{
    'overflowing_bin',
    'illegal_dumping',
    'construction_debris',
    'garbage_burning',
    'dead_animal',
  };

  final ReportingApiService _reportingApiService = ReportingApiService();
  final WasteReportingApiService _wasteReportingApiService =
      WasteReportingApiService();
  final TextEditingController _descriptionController = TextEditingController();

  String _selectedIncidentType = _incidentTypes.first.value;
  int _severity = 3;
  bool _submitting = false;
  String? _errorMessage;

  bool get _isSosMode => widget.mode == IncidentModalMode.sos;
  SosService get _sosService => widget.sosService!;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submitReport() async {
    if (_submitting) {
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final int severity = _severity;
    final String description = _descriptionController.text.trim();
    final bool isWasteReport = _wasteCategoryValues.contains(
      _selectedIncidentType,
    );
    final String userHash =
        'mobile-${DateTime.now().millisecondsSinceEpoch.toString()}';

    try {
      if (isWasteReport) {
        await _wasteReportingApiService.submitWasteReport(
          category: _selectedIncidentType,
          severity: severity,
          latitude: widget.initialLocation!.latitude,
          longitude: widget.initialLocation!.longitude,
          description: description,
        );
      } else {
        await _reportingApiService.submitIncidentReport(
          userHash: userHash,
          incidentType: _selectedIncidentType,
          severity: severity,
          latitude: widget.initialLocation!.latitude,
          longitude: widget.initialLocation!.longitude,
          description: description,
        );
      }
    } on ReportSubmissionException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitting = false;
        _errorMessage = e.message;
      });
      return;
    } on WasteReportSubmissionException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitting = false;
        _errorMessage = e.message;
      });
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _submitting = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isWasteReport
              ? 'Waste report submitted. It will be reviewed by the city team.'
              : 'Report submitted. It will influence safety scores once reviewed.',
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  Future<void> _sendTrustedContactAlert() async {
    final SosSendResult result = await _sosService.sendInitialAlert();
    if (!mounted) {
      return;
    }

    if (result.anySent) {
      _sosService.startLiveBroadcast();
      return;
    }

    if (result.locationUnavailable) {
      await _showLocationRequiredDialog();
    }
  }

  Future<void> _showLocationRequiredDialog() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Location required for SOS'),
        content: const Text(
          'ResilientSteps needs your GPS location to send an accurate SOS alert.\n\n'
          'Please enable location permissions in your phone settings, then try again.\n\n'
          'If you need immediate help, call 112.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Geolocator.openLocationSettings();
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAuthoritiesPlaceholder() {
    return showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Authorities Placeholder'),
        content: const Text(
          'Demo only. ResilientSteps will not place a call or send an SMS to authorities from this screen.\n\n'
          'If you need immediate help, call 112 yourself right away.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isSosMode) {
      return ValueListenableBuilder<SosState>(
        valueListenable: _sosService.stateListenable,
        builder: (BuildContext context, SosState state, Widget? child) {
          return _buildSosModal(context, state);
        },
      );
    }

    return _buildReportModal(context);
  }

  Widget _buildReportModal(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Material(
      type: MaterialType.transparency,
      child: _buildModalShell(
        context: context,
        title: 'New Incident Report',
        canClose: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Category',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF1C2738),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _incidentTypes
                  .map((_IncidentCategory type) {
                    final bool isSelected = type.value == _selectedIncidentType;
                    return _CategoryPill(
                      label: type.label,
                      isSelected: isSelected,
                      onTap: () {
                        setState(() {
                          _selectedIncidentType = type.value;
                        });
                      },
                    );
                  })
                  .toList(growable: false),
            ),
            const SizedBox(height: 28),
            Text(
              'Severity',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF1C2738),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: List<Widget>.generate(5, (int index) {
                final int value = index + 1;
                return _CategoryPill(
                  label: '$value · ${severityWord(value)}',
                  isSelected: _severity == value,
                  onTap: () {
                    setState(() => _severity = value);
                  },
                );
              }),
            ),
            const SizedBox(height: 28),
            Text(
              'Description of the incident...',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF1C2738),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _descriptionController,
              minLines: 4,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: 'Add context that could help others avoid this area.',
                hintStyle: const TextStyle(color: Color(0xFF9AA8BB)),
                filled: true,
                fillColor: const Color(0xFFF7F9FC),
                contentPadding: const EdgeInsets.all(18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: Color(0xFFD8E0EC)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(color: Color(0xFFD8E0EC)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: const BorderSide(
                    color: Color(0xFF4A82F7),
                    width: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F7FB),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.place_outlined,
                    size: 18,
                    color: Color(0xFF4A82F7),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pinned to current map view '
                      '(${widget.initialLocation!.latitude.toStringAsFixed(4)}, '
                      '${widget.initialLocation!.longitude.toStringAsFixed(4)})',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF617286),
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            GradientButton(
              label: 'Submit Report',
              onPressed: _submitting ? null : _submitReport,
              isLoading: _submitting,
              height: 62,
              borderRadius: 24,
              textStyle: theme.textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSosModal(BuildContext context, SosState state) {
    final ThemeData theme = Theme.of(context);
    final bool broadcastInProgress = state.isActive || state.isSending;
    final Color accentColor = broadcastInProgress
        ? const Color(0xFFD63B45)
        : const Color(0xFF2F6EF6);

    return Material(
      type: MaterialType.transparency,
      child: _buildModalShell(
        context: context,
        title: 'Emergency SOS',
        canClose: !state.isActive && !state.isSending,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Send a device-local SMS alert to your trusted contacts with your live location. No remote relay or authority call will be triggered here.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: const Color(0xFF5D6D80),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: accentColor.withValues(alpha: 0.22)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      broadcastInProgress
                          ? Icons.emergency_rounded
                          : Icons.sms_rounded,
                      color: accentColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          broadcastInProgress
                              ? 'SOS broadcast in progress'
                              : 'SOS ready',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: const Color(0xFF0D1726),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          broadcastInProgress
                              ? 'ResilientSteps is sending live SMS updates directly from this phone to your trusted contacts.'
                              : 'Trigger SOS to begin device-local SMS alerts and live updates for your trusted contacts.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF4F6076),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            if (!state.isActive)
              GradientButton(
                label: 'Alert Trusted Contacts',
                onPressed: state.isSending ? null : _sendTrustedContactAlert,
                isLoading: state.isSending,
                height: 62,
                borderRadius: 24,
                gradient: const LinearGradient(
                  colors: <Color>[Color(0xFFE24A3B), Color(0xFFD7644F)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                textStyle: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              )
            else
              GradientButton(
                label: 'Stop SOS',
                onPressed: state.isSending
                    ? null
                    : _sosService.stopLiveBroadcast,
                height: 62,
                borderRadius: 24,
                gradient: const LinearGradient(
                  colors: <Color>[Color(0xFFB11E2A), Color(0xFF8D1323)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                textStyle: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: state.isSending ? null : _showAuthoritiesPlaceholder,
                icon: const Icon(Icons.local_police_outlined),
                label: const Text('Authorities Placeholder'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  foregroundColor: const Color(0xFF1C2738),
                  side: const BorderSide(color: Color(0xFFD3DCE8)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModalShell({
    required BuildContext context,
    required String title,
    required bool canClose,
    required Widget child,
  }) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(34),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 42,
                  offset: const Offset(0, 18),
                ),
                BoxShadow(
                  color: const Color(0xFF2F6EF6).withValues(alpha: 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const SizedBox(width: 40),
                        Expanded(
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: const Color(0xFF0D1726),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: canClose
                              ? widget.onClose ??
                                    () => Navigator.of(context).pop()
                              : null,
                          icon: const Icon(Icons.close_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0xFFF4F7FB),
                            foregroundColor: const Color(0xFF4A5C73),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: isSelected
            ? const LinearGradient(
                colors: <Color>[Color(0xFF4C82F7), Color(0xFF6AA5FF)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              )
            : null,
        color: isSelected ? null : const Color(0xFFF2F4F8),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isSelected ? Colors.transparent : const Color(0xFFD5DCE7),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Text(
              label,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: isSelected ? Colors.white : const Color(0xFF5D6978),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IncidentCategory {
  const _IncidentCategory({required this.label, required this.value});

  final String label;
  final String value;
}

// R-079 severity anchors shared by the chip labels.
String severityWord(int severity) {
  return switch (severity) {
    1 => 'Minor',
    2 => 'Low',
    3 => 'Moderate',
    4 => 'Serious',
    _ => 'Critical',
  };
}
