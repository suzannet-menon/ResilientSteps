import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../services/infra_reporting_api_service.dart';
import '../widgets/infra_category_picker.dart';

class InfraReportScreen extends StatefulWidget {
  const InfraReportScreen({super.key, this.initialLocation});

  final LatLng? initialLocation;

  @override
  State<InfraReportScreen> createState() => _InfraReportScreenState();
}

class _InfraReportScreenState extends State<InfraReportScreen> {
  final InfraReportingApiService _apiService = InfraReportingApiService();
  final TextEditingController _descriptionController = TextEditingController();

  List<InfraCategory> _categories = <InfraCategory>[];
  String? _selectedCategory;
  int _severity = 3;
  LatLng? _currentLocation;
  bool _isLoading = false;
  bool _isFetchingCategories = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _currentLocation = widget.initialLocation;
    _loadCategories();
    if (_currentLocation == null) {
      _acquireCurrentLocation();
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final List<InfraCategory> fetched = await _apiService.fetchCategories();
    if (mounted) {
      setState(() {
        _categories = fetched;
        _isFetchingCategories = false;
        if (_categories.isNotEmpty) {
          _selectedCategory = _categories.first.code;
        }
      });
    }
  }

  Future<void> _acquireCurrentLocation() async {
    try {
      final Position pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (mounted) {
        setState(() {
          _currentLocation = LatLng(pos.latitude, pos.longitude);
        });
      }
    } catch (_) {
      // Fall back to the initial location (or none).
    }
  }

  Future<void> _submitReport() async {
    if (_selectedCategory == null) {
      setState(() => _errorMessage = 'Please select an infrastructure category');
      return;
    }
    if (_currentLocation == null) {
      setState(() => _errorMessage = 'Location is required to submit a report');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _apiService.submitInfraReport(
        category: _selectedCategory!,
        severity: _severity,
        latitude: _currentLocation!.latitude,
        longitude: _currentLocation!.longitude,
        description: _descriptionController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Infrastructure report submitted successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report Infrastructure Issue'),
      ),
      body: _isFetchingCategories
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Category',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  InfraCategoryPicker(
                    categories: _categories,
                    selectedCategoryCode: _selectedCategory,
                    onCategorySelected: (String code) {
                      setState(() => _selectedCategory = code);
                    },
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Severity (1 = Low, 5 = Critical)',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Text('$_severity', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Slider(
                          value: _severity.toDouble(),
                          min: 1,
                          max: 5,
                          divisions: 4,
                          label: '$_severity',
                          onChanged: (double val) {
                            setState(() => _severity = val.round());
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Description (Optional)',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _descriptionController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Provide details about the issue...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_currentLocation != null)
                    Text(
                      'Location: ${_currentLocation!.latitude.toStringAsFixed(4)}, ${_currentLocation!.longitude.toStringAsFixed(4)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (_errorMessage != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitReport,
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Submit Report'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
