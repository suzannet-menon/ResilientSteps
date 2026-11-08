import '../../domain/entities/risk.dart';
import '../../domain/repositories/risk_repository.dart';

class RiskRepositoryImpl implements RiskRepository {
  // todo: Inject remote data source

  @override
  Future<Risk> getRiskForLocation(double lat, double lon) async {
    return Risk(
      score: 0.2,
      lighting: 0.8,
      crowdDensity: 0.5,
      lastUpdated: DateTime.now(),
    );
  }

  @override
  Stream<Risk> watchRiskForCurrentLocation() async* {
    yield await getRiskForLocation(0, 0);
  }
}
