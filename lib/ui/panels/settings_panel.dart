import '../settings/settings_screen.dart';

/// The desktop shell's Settings destination. Kept as a thin wrapper: the
/// screen lives in `ui/settings/` ("Settings & Connections"). The three
/// provider API-key inputs that used to be here wrote straight to the app's
/// own secure storage, a third credential path next to the engine vault; they
/// are gone. Provider credentials are entered only in the engine vault.
class SettingsPanel extends SettingsScreen {
  const SettingsPanel({super.key}) : super(showLocalAgent: true, showTitle: false);
}
