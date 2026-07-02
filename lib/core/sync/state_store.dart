/// Persists the small amount of sync state that must survive process restarts.
/// v1: only lastAppliedHash, the dedup key that prevents a reconnect or cold
/// start from re-applying (clobbering) a clip this device already applied.
abstract class StateStore {
  Future<String?> readLastAppliedHash();
  Future<void> writeLastAppliedHash(String hash);
}
