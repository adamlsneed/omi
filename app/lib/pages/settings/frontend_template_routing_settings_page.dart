import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/app.dart';
import 'package:omi/pages/apps/widgets/capability_apps_page.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/services/frontend_template_router.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';

class FrontendTemplateRoutingSettingsPage extends StatefulWidget {
  const FrontendTemplateRoutingSettingsPage({super.key});

  @override
  State<FrontendTemplateRoutingSettingsPage> createState() => _FrontendTemplateRoutingSettingsPageState();
}

class _FrontendTemplateRoutingSettingsPageState extends State<FrontendTemplateRoutingSettingsPage> {
  final FrontendTemplateRoutingStore _store = FrontendTemplateRoutingStore();
  final TextEditingController _workStartController = TextEditingController();
  final TextEditingController _workEndController = TextEditingController();
  final TextEditingController _workPromptController = TextEditingController();
  final TextEditingController _personalPromptController = TextEditingController();

  late FrontendTemplateRoutingConfig _config;
  String? _error;
  bool _saving = false;
  bool _loadingApps = false;

  @override
  void initState() {
    super.initState();
    _config = _store.loadConfig();
    _workStartController.text = _formatMinutes(_config.workStartMinutes);
    _workEndController.text = _formatMinutes(_config.workEndMinutes);
    _workPromptController.text = _config.workPrompt;
    _personalPromptController.text = _config.personalPrompt;
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureAppsLoaded());
  }

  Future<void> _ensureAppsLoaded() async {
    final appProvider = context.read<AppProvider>();
    if (appProvider.apps.isNotEmpty) return;
    setState(() => _loadingApps = true);
    await appProvider.getApps();
    if (!mounted) return;
    setState(() => _loadingApps = false);
  }

  @override
  void dispose() {
    _workStartController.dispose();
    _workEndController.dispose();
    _workPromptController.dispose();
    _personalPromptController.dispose();
    super.dispose();
  }

  /// Enabled apps that can summarize a conversation (capability `memories`).
  List<App> _summaryApps(AppProvider provider) =>
      provider.apps.where((app) => app.enabled && app.worksWithMemories()).toList();

  String _appLabel(String appId, List<App> apps) {
    if (appId.trim().isEmpty) return context.l10n.templateRoutingTemplateNone;
    final match = apps.firstWhereOrNull((a) => a.id == appId) ??
        context.read<AppProvider>().apps.firstWhereOrNull((a) => a.id == appId);
    return match?.name ?? context.l10n.templateRoutingTemplateNone;
  }

  Future<void> _pickTemplate({
    required String currentAppId,
    required List<App> apps,
    required ValueChanged<String> onPicked,
  }) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(context.l10n.templateRoutingTemplateNone, style: const TextStyle(color: Colors.white)),
                trailing: currentAppId.trim().isEmpty ? const Icon(Icons.check, color: Colors.white) : null,
                onTap: () => Navigator.pop(sheetContext, ''),
              ),
              const Divider(height: 1, color: Color(0xFF3C3C43)),
              ...apps.map(
                (app) => ListTile(
                  title: Text(app.name, style: const TextStyle(color: Colors.white)),
                  trailing: app.id == currentAppId ? const Icon(Icons.check, color: Colors.white) : null,
                  onTap: () => Navigator.pop(sheetContext, app.id),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (mounted && selected != null) onPicked(selected);
  }

  void _openSummaryApps() {
    final memoriesApps = context.read<AppProvider>().apps.where((app) => app.worksWithMemories()).toList();
    routeToPage(
      context,
      CapabilityAppsPage(
        capability: AppCapability(title: context.l10n.summary, id: 'memories'),
        apps: memoriesApps,
      ),
    );
  }

  Future<void> _save() async {
    final start = _parseTime(_workStartController.text);
    final end = _parseTime(_workEndController.text);
    final workPrompt = _workPromptController.text.trim();
    final personalPrompt = _personalPromptController.text.trim();

    setState(() => _error = null);

    if (start == null || end == null) {
      setState(() => _error = context.l10n.templateRoutingTimeFormatError);
      return;
    }
    if (start >= end) {
      setState(() => _error = context.l10n.templateRoutingStartBeforeEndError);
      return;
    }

    final nextConfig = _config.copyWith(
      workStartMinutes: start,
      workEndMinutes: end,
      workPrompt: workPrompt,
      personalPrompt: personalPrompt,
    );

    // A profile is usable with either a backend template or a free-text prompt.
    if (nextConfig.enabled && !nextConfig.isFullyConfigured) {
      setState(() => _error = context.l10n.templateRoutingProfileRequiredError);
      return;
    }

    setState(() => _saving = true);
    await _store.saveConfig(nextConfig);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _config = nextConfig;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.templateRoutingSaved)));
  }

  int? _parseTime(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour >= 24 || minute < 0 || minute >= 60) return null;
    return hour * Duration.minutesPerHour + minute;
  }

  String _formatMinutes(int minutes) {
    final hour = minutes ~/ Duration.minutesPerHour;
    final minute = minutes % Duration.minutesPerHour;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  Widget _section({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
      child: Column(children: children),
    );
  }

  Widget _divider() => const Divider(height: 1, color: Color(0xFF3C3C43));

  Widget _timeField({required String label, required TextEditingController controller}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
            ),
          ),
          SizedBox(
            width: 96,
            child: TextField(
              controller: controller,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.datetime,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF2A2A2E),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _templatePickerRow({
    required String label,
    required String selectedAppId,
    required List<App> apps,
    required ValueChanged<String> onPicked,
  }) {
    return InkWell(
      onTap: _loadingApps ? null : () => _pickTemplate(currentAppId: selectedAppId, apps: apps, onPicked: onPicked),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
              ),
            ),
            Flexible(
              child: Text(
                _appLabel(selectedAppId, apps),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Color(0xFF8E8E93), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _promptField({required String label, required TextEditingController controller}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            minLines: 5,
            maxLines: 9,
            maxLength: 4000,
            style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF2A2A2E),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.all(14),
              counterStyle: const TextStyle(color: Color(0xFF8E8E93)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summaryApps = _summaryApps(context.watch<AppProvider>());
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          context.l10n.templateRouting,
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            _section(
              children: [
                SwitchListTile(
                  value: _config.enabled,
                  activeThumbColor: Colors.black,
                  activeTrackColor: Colors.white,
                  inactiveThumbColor: const Color(0xFF8E8E93),
                  title: Text(
                    context.l10n.permissionEnabled,
                    style: const TextStyle(color: Colors.white, fontSize: 17),
                  ),
                  onChanged: (value) => setState(() => _config = _config.copyWith(enabled: value)),
                ),
                _divider(),
                SwitchListTile(
                  value: _config.autoRunOnOpen,
                  activeThumbColor: Colors.black,
                  activeTrackColor: Colors.white,
                  inactiveThumbColor: const Color(0xFF8E8E93),
                  title: Text(
                    context.l10n.templateRoutingAutoRunOnOpen,
                    style: const TextStyle(color: Colors.white, fontSize: 17),
                  ),
                  onChanged: (value) => setState(() => _config = _config.copyWith(autoRunOnOpen: value)),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _section(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.templateRoutingWorkDays,
                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
                        ),
                      ),
                      Text(
                        context.l10n.templateRoutingWorkDaysMonFri,
                        style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
                      ),
                    ],
                  ),
                ),
                _divider(),
                _timeField(label: context.l10n.templateRoutingWorkStart, controller: _workStartController),
                _divider(),
                _timeField(label: context.l10n.templateRoutingWorkEnd, controller: _workEndController),
              ],
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                context.l10n.templateRoutingBackendTemplateSection,
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            _section(
              children: [
                _templatePickerRow(
                  label: context.l10n.templateRoutingWorkTemplate,
                  selectedAppId: _config.workAppId,
                  apps: summaryApps,
                  onPicked: (id) => setState(() => _config = _config.copyWith(workAppId: id)),
                ),
                _divider(),
                _templatePickerRow(
                  label: context.l10n.templateRoutingPersonalTemplate,
                  selectedAppId: _config.personalAppId,
                  apps: summaryApps,
                  onPicked: (id) => setState(() => _config = _config.copyWith(personalAppId: id)),
                ),
                _divider(),
                ListTile(
                  title: Text(
                    context.l10n.templateRoutingManageApps,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  trailing: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
                  onTap: _openSummaryApps,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                context.l10n.templateRoutingTemplateHint,
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13, height: 1.3),
              ),
            ),
            const SizedBox(height: 24),
            _section(
              children: [
                _promptField(label: context.l10n.templateRoutingWorkPrompt, controller: _workPromptController),
                _divider(),
                _promptField(label: context.l10n.templateRoutingPersonalPrompt, controller: _personalPromptController),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 14)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                disabledBackgroundColor: const Color(0xFF3C3C43),
                disabledForegroundColor: const Color(0xFF8E8E93),
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(
                _saving ? context.l10n.saving : context.l10n.save,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
