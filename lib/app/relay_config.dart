/// The deployed Clippy relay (VPS). Override at build time with
/// --dart-define=CLIPPY_RELAY_URL=wss://... for local/self-hosted relays.
const String relayUrl = String.fromEnvironment(
  'CLIPPY_RELAY_URL',
  defaultValue: 'wss://clippy.alwinpaul.me',
);
