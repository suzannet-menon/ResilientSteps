import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'device_sms_service.dart';
import 'location_service.dart';
import 'trusted_contacts_service.dart';
import 'reporting_api_service.dart';

typedef SosContactsLoader = Future<List<TrustedContact>> Function();
typedef SosLocationLoader = Future<LatLng?> Function();
typedef SosSmsTransport =
    Future<String> Function({
      required String phoneNumber,
      required String message,
    });
typedef SosNowProvider = DateTime Function();

enum SosUiStatusKind { idle, sending, success, active, stopped, failed }

class SosRecipientStatus {
  const SosRecipientStatus({
    required this.name,
    required this.phone,
    this.reason,
  });

  final String name;
  final String phone;
  final String? reason;

  String get label => name.trim().isEmpty ? phone : '${name.trim()} ($phone)';
}

class SosSendResult {
  const SosSendResult({
    required this.isLiveUpdate,
    required this.timestamp,
    required this.sentRecipients,
    required this.failedRecipients,
    required this.skippedRecipients,
    this.messageBody,
    this.generalError,
    this.locationUnavailable = false,
    this.unsupportedPlatform = false,
  });

  final bool isLiveUpdate;
  final DateTime timestamp;
  final List<SosRecipientStatus> sentRecipients;
  final List<SosRecipientStatus> failedRecipients;
  final List<SosRecipientStatus> skippedRecipients;
  final String? messageBody;
  final String? generalError;
  final bool locationUnavailable;
  final bool unsupportedPlatform;

  bool get anySent => sentRecipients.isNotEmpty;

  String get summary {
    if (generalError != null && !anySent) {
      return generalError!;
    }

    final String action = isLiveUpdate ? 'Live update' : 'SOS alert';
    final List<String> parts = <String>[];

    if (sentRecipients.isNotEmpty) {
      parts.add(
        '$action sent to ${sentRecipients.length} trusted contact${sentRecipients.length == 1 ? '' : 's'}.',
      );
    } else {
      parts.add('$action was not sent to any trusted contacts.');
    }

    if (failedRecipients.isNotEmpty) {
      parts.add(
        '${failedRecipients.length} send failure${failedRecipients.length == 1 ? '' : 's'} recorded.',
      );
    }

    if (skippedRecipients.isNotEmpty) {
      parts.add(
        '${skippedRecipients.length} invalid number${skippedRecipients.length == 1 ? '' : 's'} skipped.',
      );
    }

    if (generalError != null && anySent) {
      parts.add(generalError!);
    }

    return parts.join(' ');
  }
}

class SosState {
  const SosState({
    this.kind = SosUiStatusKind.idle,
    this.isSending = false,
    this.isActive = false,
    this.headline = 'SOS ready',
    this.latestStatus = 'Alert trusted contacts to start live SMS updates.',
    this.lastUpdatedAt,
    this.lastResult,
  });

  final SosUiStatusKind kind;
  final bool isSending;
  final bool isActive;
  final String headline;
  final String latestStatus;
  final DateTime? lastUpdatedAt;
  final SosSendResult? lastResult;

  SosState copyWith({
    SosUiStatusKind? kind,
    bool? isSending,
    bool? isActive,
    String? headline,
    String? latestStatus,
    DateTime? lastUpdatedAt,
    SosSendResult? lastResult,
  }) {
    return SosState(
      kind: kind ?? this.kind,
      isSending: isSending ?? this.isSending,
      isActive: isActive ?? this.isActive,
      headline: headline ?? this.headline,
      latestStatus: latestStatus ?? this.latestStatus,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
      lastResult: lastResult ?? this.lastResult,
    );
  }
}

class SosService {
  SosService({
    LocationService? locationService,
    SosContactsLoader? contactsLoader,
    SosLocationLoader? locationLoader,
    SosSmsTransport? smsTransport,
    SosNowProvider? nowProvider,
    Duration broadcastInterval = const Duration(seconds: 120),
  }) : _locationLoader =
           locationLoader ??
           (locationService ?? LocationService()).getCurrentLocation,
       _contactsLoader = contactsLoader ?? TrustedContactsService.load,
       _smsTransport = smsTransport ?? DeviceSmsService.sendSms,
       _nowProvider = nowProvider ?? DateTime.now,
       _broadcastInterval = broadcastInterval;

  final SosLocationLoader _locationLoader;
  final SosContactsLoader _contactsLoader;
  final SosSmsTransport _smsTransport;
  final SosNowProvider _nowProvider;
  final Duration _broadcastInterval;
  final ReportingApiService _reportingApiService = ReportingApiService();
  final ValueNotifier<SosState> _stateNotifier = ValueNotifier<SosState>(
    const SosState(),
  );

  Timer? _broadcastTimer;
  bool _broadcastActive = false;
  bool _sendInProgress = false;
  bool _disposed = false;

  ValueListenable<SosState> get stateListenable => _stateNotifier;
  SosState get currentState => _stateNotifier.value;
  bool get isActive => _broadcastActive;

  Future<SosSendResult> sendInitialAlert({
    LatLng? location,
    List<TrustedContact>? trustedContacts,
  }) {
    return _sendAlert(
      isLiveUpdate: false,
      location: location,
      trustedContacts: trustedContacts,
    );
  }

  Future<SosSendResult> sendLiveUpdate({
    LatLng? location,
    List<TrustedContact>? trustedContacts,
  }) {
    return _sendAlert(
      isLiveUpdate: true,
      location: location,
      trustedContacts: trustedContacts,
    );
  }

  void startLiveBroadcast({List<TrustedContact>? trustedContacts}) {
    if (_disposed) {
      return;
    }

    _broadcastTimer?.cancel();
    _broadcastActive = true;
    _updateState(
      currentState.copyWith(
        kind: SosUiStatusKind.active,
        isActive: true,
        isSending: false,
        headline: 'SOS active',
        latestStatus:
            currentState.lastResult?.summary ??
            'Live SMS updates will repeat every 120 seconds.',
        lastUpdatedAt: _nowProvider().toLocal(),
      ),
    );

    _broadcastTimer = Timer.periodic(_broadcastInterval, (_) {
      if (_disposed || !_broadcastActive || _sendInProgress) {
        return;
      }
      unawaited(sendLiveUpdate(trustedContacts: trustedContacts));
    });
  }

  void stopLiveBroadcast() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _broadcastActive = false;

    if (_disposed) {
      return;
    }

    _updateState(
      currentState.copyWith(
        kind: SosUiStatusKind.stopped,
        isActive: false,
        isSending: false,
        headline: 'SOS stopped',
        latestStatus: 'Live SMS updates have been canceled.',
        lastUpdatedAt: _nowProvider().toLocal(),
      ),
    );
  }

  Future<bool> sendEmergencyAlert({
    required double latitude,
    required double longitude,
    String? message,
    List<TrustedContact>? trustedContacts,
  }) async {
    final SosSendResult result = await sendInitialAlert(
      location: LatLng(latitude, longitude),
      trustedContacts: trustedContacts,
    );
    return result.anySent;
  }

  void dispose() {
    if (_disposed) {
      return;
    }

    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _broadcastActive = false;
    _disposed = true;
    _stateNotifier.dispose();
  }

  static String normalizePhoneNumber(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final bool hasLeadingPlus = trimmed.startsWith('+');
    final String withoutFormatting = trimmed.replaceAll(
      RegExp(r'[\s\-\(\)]'),
      '',
    );
    final String digitsOnly = withoutFormatting.replaceFirst(
      RegExp(r'^\+'),
      '',
    );

    if (digitsOnly.isEmpty) {
      return '';
    }

    return hasLeadingPlus ? '+$digitsOnly' : digitsOnly;
  }

  static bool isValidNormalizedPhoneNumber(String value) {
    return RegExp(r'^\+?\d+$').hasMatch(value);
  }

  static String buildMessageBody(LatLng location, DateTime timestamp) {
    final String latitude = location.latitude.toStringAsFixed(6);
    final String longitude = location.longitude.toStringAsFixed(6);
    final String localTime = timestamp.toLocal().toIso8601String();

    return 'RESILIENTSTEPS SOS\n'
        'I need help and may be in danger.\n\n'
        'Location: https://www.google.com/maps?q=$latitude,$longitude\n'
        'Coordinates: $latitude, $longitude\n'
        'Time: $localTime\n\n'
        'ResilientSteps will keep sending live updates while SOS is active.';
  }

  Future<SosSendResult> _sendAlert({
    required bool isLiveUpdate,
    LatLng? location,
    List<TrustedContact>? trustedContacts,
  }) async {
    if (_disposed) {
      return SosSendResult(
        isLiveUpdate: isLiveUpdate,
        timestamp: _nowProvider().toLocal(),
        sentRecipients: const <SosRecipientStatus>[],
        failedRecipients: const <SosRecipientStatus>[],
        skippedRecipients: const <SosRecipientStatus>[],
        generalError: 'SOS is not available right now.',
      );
    }

    if (_sendInProgress) {
      return SosSendResult(
        isLiveUpdate: isLiveUpdate,
        timestamp: _nowProvider().toLocal(),
        sentRecipients: const <SosRecipientStatus>[],
        failedRecipients: const <SosRecipientStatus>[],
        skippedRecipients: const <SosRecipientStatus>[],
        generalError: 'An SOS send is already in progress.',
      );
    }

    _sendInProgress = true;
    _updateState(
      currentState.copyWith(
        kind: _broadcastActive
            ? SosUiStatusKind.active
            : SosUiStatusKind.sending,
        isSending: true,
        isActive: _broadcastActive,
        headline: isLiveUpdate
            ? 'Sending live update...'
            : 'Sending SOS alert...',
        latestStatus: isLiveUpdate
            ? 'Refreshing your live location for trusted contacts.'
            : 'Sending your location to trusted contacts now.',
        lastUpdatedAt: _nowProvider().toLocal(),
      ),
    );

    try {
      if (!_supportsSms) {
        final SosSendResult result = SosSendResult(
          isLiveUpdate: isLiveUpdate,
          timestamp: _nowProvider().toLocal(),
          sentRecipients: const <SosRecipientStatus>[],
          failedRecipients: const <SosRecipientStatus>[],
          skippedRecipients: const <SosRecipientStatus>[],
          generalError: 'SMS is only supported on Android and iOS.',
          unsupportedPlatform: true,
        );
        _applyCompletedResult(result);
        return result;
      }

      final _ResolvedContacts resolvedContacts = await _resolveContacts(
        trustedContacts,
      );
      if (resolvedContacts.validRecipients.isEmpty) {
        final String errorMessage = resolvedContacts.hadStoredContacts
            ? 'No valid trusted contact phone numbers are saved.'
            : 'No trusted contacts are saved yet.';
        final SosSendResult result = SosSendResult(
          isLiveUpdate: isLiveUpdate,
          timestamp: _nowProvider().toLocal(),
          sentRecipients: const <SosRecipientStatus>[],
          failedRecipients: const <SosRecipientStatus>[],
          skippedRecipients: resolvedContacts.skippedRecipients,
          generalError: errorMessage,
        );
        _applyCompletedResult(result);
        return result;
      }

      final LatLng? liveLocation = location ?? await _locationLoader();
      if (liveLocation == null) {
        final SosSendResult result = SosSendResult(
          isLiveUpdate: isLiveUpdate,
          timestamp: _nowProvider().toLocal(),
          sentRecipients: const <SosRecipientStatus>[],
          failedRecipients: const <SosRecipientStatus>[],
          skippedRecipients: resolvedContacts.skippedRecipients,
          generalError:
              'ResilientSteps could not read your current GPS location. Enable location access and try again.',
          locationUnavailable: true,
        );
        _applyCompletedResult(result);
        return result;
      }

      final DateTime timestamp = _nowProvider().toLocal();
      final String messageBody = buildMessageBody(liveLocation, timestamp);
      final List<SosRecipientStatus> sentRecipients = <SosRecipientStatus>[];
      final List<SosRecipientStatus> failedRecipients = <SosRecipientStatus>[];

      for (final _PreparedTrustedContact recipient
          in resolvedContacts.validRecipients) {
        if (_disposed || (isLiveUpdate && !_broadcastActive)) {
          break;
        }

        try {
          final String response = await _smsTransport(
            phoneNumber: recipient.phone,
            message: messageBody,
          );
          sentRecipients.add(
            SosRecipientStatus(
              name: recipient.name,
              phone: recipient.phone,
              reason: response,
            ),
          );
        } catch (error) {
          failedRecipients.add(
            SosRecipientStatus(
              name: recipient.name,
              phone: recipient.phone,
              reason: _errorMessage(error),
            ),
          );
        }
      }

      final SosSendResult result = SosSendResult(
        isLiveUpdate: isLiveUpdate,
        timestamp: timestamp,
        sentRecipients: sentRecipients,
        failedRecipients: failedRecipients,
        skippedRecipients: resolvedContacts.skippedRecipients,
        messageBody: messageBody,
      );

      try {
        final List<Map<String, String>> contactsList = resolvedContacts.validRecipients
            .map((recipient) => <String, String>{
                  'name': recipient.name,
                  'phone': recipient.phone,
                })
            .toList();

        unawaited(_reportingApiService.submitEmergencyAlert(
          userHash: '',
          latitude: liveLocation.latitude,
          longitude: liveLocation.longitude,
          message: messageBody,
          trustedContacts: contactsList,
          contactsNotified: sentRecipients.length,
        ));
      } catch (e) {
        debugPrint('SosService: failed to sync emergency alert with backend: $e');
      }

      _applyCompletedResult(result);
      return result;
    } finally {
      _sendInProgress = false;
    }
  }

  Future<_ResolvedContacts> _resolveContacts(
    List<TrustedContact>? trustedContacts,
  ) async {
    final List<TrustedContact> storedContacts =
        trustedContacts == null || trustedContacts.isEmpty
        ? await _contactsLoader()
        : trustedContacts;
    final List<_PreparedTrustedContact> validRecipients =
        <_PreparedTrustedContact>[];
    final List<SosRecipientStatus> skippedRecipients = <SosRecipientStatus>[];

    for (final TrustedContact contact in storedContacts) {
      if (validRecipients.length >= TrustedContactsService.maxContacts) {
        break;
      }

      final String normalizedPhone = normalizePhoneNumber(contact.phone);
      if (normalizedPhone.isEmpty ||
          !isValidNormalizedPhoneNumber(normalizedPhone)) {
        skippedRecipients.add(
          SosRecipientStatus(
            name: contact.name.trim(),
            phone: contact.phone.trim(),
            reason: 'Invalid phone number',
          ),
        );
        continue;
      }

      validRecipients.add(
        _PreparedTrustedContact(
          name: contact.name.trim(),
          phone: normalizedPhone,
        ),
      );
    }

    return _ResolvedContacts(
      validRecipients: validRecipients,
      skippedRecipients: skippedRecipients,
      hadStoredContacts: storedContacts.isNotEmpty,
    );
  }

  void _applyCompletedResult(SosSendResult result) {
    if (result.isLiveUpdate &&
        !_broadcastActive &&
        currentState.kind == SosUiStatusKind.stopped) {
      return;
    }

    final bool keepActive = _broadcastActive;
    final SosUiStatusKind kind;
    final String headline;

    if (keepActive) {
      kind = SosUiStatusKind.active;
      headline = result.anySent
          ? 'SOS active'
          : 'SOS active with delivery issues';
    } else if (result.anySent) {
      kind = SosUiStatusKind.success;
      headline = 'Trusted contacts alerted';
    } else {
      kind = SosUiStatusKind.failed;
      headline = 'SOS alert failed';
    }

    _updateState(
      currentState.copyWith(
        kind: kind,
        isSending: false,
        isActive: keepActive,
        headline: headline,
        latestStatus: result.summary,
        lastUpdatedAt: result.timestamp,
        lastResult: result,
      ),
    );
  }

  void _updateState(SosState nextState) {
    if (_disposed) {
      return;
    }
    _stateNotifier.value = nextState;
  }

  String _errorMessage(Object error) {
    final String message = error.toString();
    if (message.startsWith('Exception: ')) {
      return message.substring('Exception: '.length);
    }
    return message;
  }

  bool get _supportsSms => _isAndroid || _isIos;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}

class _PreparedTrustedContact {
  const _PreparedTrustedContact({required this.name, required this.phone});

  final String name;
  final String phone;
}

class _ResolvedContacts {
  const _ResolvedContacts({
    required this.validRecipients,
    required this.skippedRecipients,
    required this.hadStoredContacts,
  });

  final List<_PreparedTrustedContact> validRecipients;
  final List<SosRecipientStatus> skippedRecipients;
  final bool hadStoredContacts;
}
