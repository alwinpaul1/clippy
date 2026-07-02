import '../models/encrypted_clip.dart';

/// The SyncEngine emits actions instead of performing side effects, so its
/// decision logic is pure and fully testable. Platform code (Plans 3–4)
/// interprets these: UploadClip -> ClipStore.append; ApplyToClipboard ->
/// ClipboardPort.setText; OfferRestore -> show a "restore last clip" affordance.
sealed class SyncAction {
  const SyncAction();
}

class UploadClip extends SyncAction {
  final EncryptedClip clip;
  const UploadClip(this.clip);
}

class ApplyToClipboard extends SyncAction {
  final String text;
  const ApplyToClipboard(this.text);
}

class OfferRestore extends SyncAction {
  final String text;
  const OfferRestore(this.text);
}
