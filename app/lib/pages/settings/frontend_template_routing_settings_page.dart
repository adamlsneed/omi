import 'package:flutter/material.dart';
import 'package:omi/services/frontend_template_router.dart';

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

  @override
  void initState() {
    super.initState();
    _config = _store.loadConfig();
    _workStartController.text = _formatMinutes(_config.workStartMinutes);
    _workEndController.text = _formatMinutes(_config.workEndMinutes);
    _workPromptController.text = _config.workPrompt;
    _personalPromptController.text = _config.personalPrompt;
  }

  @override
  void dispose() {
    _workStartController.dispose();
    _workEndController.dispose();
    _workPromptController.dispose();
    _personalPromptController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final start = _parseTime(_workStartController.text);
    final end = _parseTime(_workEndController.text);
    final workPrompt = _workPromptController.text.trim();
    final personalPrompt = _personalPromptController.text.trim();

    setState(() => _error = null);

    if (start == null || end == null) {
      setState(() => _error = 'Use 24-hour times like 08:00 and 17:00.');
      return;
    }
    if (start >= end) {
      setState(() => _error = 'Work start must be before work end.');
      return;
    }
    if (_config.enabled && (workPrompt.isEmpty || personalPrompt.isEmpty)) {
      setState(() => _error = 'Add both prompts before enabling routing.');
      return;
    }

    final nextConfig = _config.copyWith(
      workStartMinutes: start,
      workEndMinutes: end,
      workPrompt: workPrompt,
      personalPrompt: personalPrompt,
    );

    setState(() => _saving = true);
    await _store.saveConfig(nextConfig);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _config = nextConfig;
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Template routing saved')));
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

  Widget _promptField({required String label, required TextEditingController controller}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500)),
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Template Routing',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
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
                  activeThumbColor: Colors.white,
                  activeTrackColor: const Color(0xFF7C4DFF),
                  inactiveThumbColor: const Color(0xFF8E8E93),
                  title: const Text('Enabled', style: TextStyle(color: Colors.white, fontSize: 17)),
                  onChanged: (value) => setState(() => _config = _config.copyWith(enabled: value)),
                ),
                _divider(),
                SwitchListTile(
                  value: _config.autoRunOnOpen,
                  activeThumbColor: Colors.white,
                  activeTrackColor: const Color(0xFF7C4DFF),
                  inactiveThumbColor: const Color(0xFF8E8E93),
                  title: const Text('Auto-run on open', style: TextStyle(color: Colors.white, fontSize: 17)),
                  onChanged: (value) => setState(() => _config = _config.copyWith(autoRunOnOpen: value)),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _section(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Work days',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
                        ),
                      ),
                      Text('Mon-Fri', style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16)),
                    ],
                  ),
                ),
                _divider(),
                _timeField(label: 'Work start', controller: _workStartController),
                _divider(),
                _timeField(label: 'Work end', controller: _workEndController),
              ],
            ),
            const SizedBox(height: 24),
            _section(
              children: [
                _promptField(label: 'Work prompt', controller: _workPromptController),
                _divider(),
                _promptField(label: 'Personal prompt', controller: _personalPromptController),
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
                _saving ? 'Saving...' : 'Save',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
