import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:omi/backend/preferences.dart';

enum FrontendTemplateProfile {
  work('work', 'Work'),
  personal('personal', 'Personal');

  final String storageValue;
  final String label;

  const FrontendTemplateProfile(this.storageValue, this.label);

  static FrontendTemplateProfile fromStorageValue(String? value) {
    return FrontendTemplateProfile.values.firstWhere(
      (profile) => profile.storageValue == value,
      orElse: () => FrontendTemplateProfile.personal,
    );
  }
}

class FrontendTemplateRoutingConfig {
  static const int defaultWorkStartMinutes = 8 * 60;
  static const int defaultWorkEndMinutes = 17 * 60;
  static const List<int> defaultWorkWeekdays = [
    DateTime.monday,
    DateTime.tuesday,
    DateTime.wednesday,
    DateTime.thursday,
    DateTime.friday,
  ];

  final bool enabled;
  final bool autoRunOnOpen;
  final int workStartMinutes;
  final int workEndMinutes;
  final List<int> workWeekdays;
  final String workPrompt;
  final String personalPrompt;

  /// Backend app/template ids to summarize with per profile. Empty = no template
  /// (fall back to the free-text prompt for that profile).
  final String workAppId;
  final String personalAppId;

  const FrontendTemplateRoutingConfig({
    required this.enabled,
    required this.autoRunOnOpen,
    required this.workStartMinutes,
    required this.workEndMinutes,
    required this.workWeekdays,
    required this.workPrompt,
    required this.personalPrompt,
    this.workAppId = '',
    this.personalAppId = '',
  });

  factory FrontendTemplateRoutingConfig.defaults() {
    return const FrontendTemplateRoutingConfig(
      enabled: false,
      autoRunOnOpen: true,
      workStartMinutes: defaultWorkStartMinutes,
      workEndMinutes: defaultWorkEndMinutes,
      workWeekdays: defaultWorkWeekdays,
      workPrompt: '',
      personalPrompt: '',
    );
  }

  factory FrontendTemplateRoutingConfig.fromJson(Map<String, dynamic> json) {
    final defaults = FrontendTemplateRoutingConfig.defaults();
    final decodedWeekdays = json['work_weekdays'];
    final workWeekdays = decodedWeekdays is List
        ? decodedWeekdays
            .map((day) => day is int ? day : int.tryParse(day.toString()))
            .whereType<int>()
            .where((day) => day >= DateTime.monday && day <= DateTime.sunday)
            .toList()
        : defaults.workWeekdays;

    return FrontendTemplateRoutingConfig(
      enabled: json['enabled'] == true,
      autoRunOnOpen: json['auto_run_on_open'] is bool ? json['auto_run_on_open'] as bool : defaults.autoRunOnOpen,
      workStartMinutes: _minutesFromJson(json['work_start_minutes'], defaults.workStartMinutes),
      workEndMinutes: _minutesFromJson(json['work_end_minutes'], defaults.workEndMinutes),
      workWeekdays: workWeekdays.isEmpty ? defaults.workWeekdays : workWeekdays,
      workPrompt: (json['work_prompt'] ?? '').toString(),
      personalPrompt: (json['personal_prompt'] ?? '').toString(),
      workAppId: (json['work_app_id'] ?? '').toString(),
      personalAppId: (json['personal_app_id'] ?? '').toString(),
    );
  }

  static int _minutesFromJson(dynamic value, int fallback) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (parsed == null) return fallback;
    if (parsed < 0 || parsed >= Duration.hoursPerDay * Duration.minutesPerHour) return fallback;
    return parsed;
  }

  bool get hasRequiredPrompts => workPrompt.trim().isNotEmpty && personalPrompt.trim().isNotEmpty;

  String promptFor(FrontendTemplateProfile profile) {
    return profile == FrontendTemplateProfile.work ? workPrompt.trim() : personalPrompt.trim();
  }

  /// Backend app/template id for [profile], or null when none is selected
  /// (so the free-text prompt should be used instead).
  String? appIdFor(FrontendTemplateProfile profile) {
    final id = (profile == FrontendTemplateProfile.work ? workAppId : personalAppId).trim();
    return id.isEmpty ? null : id;
  }

  bool usesTemplateFor(FrontendTemplateProfile profile) => appIdFor(profile) != null;

  /// A profile is usable if it has either a backend template or a free-text prompt.
  bool isConfiguredFor(FrontendTemplateProfile profile) => usesTemplateFor(profile) || promptFor(profile).isNotEmpty;

  /// Both profiles have at least one of (template, prompt) — required to enable.
  bool get isFullyConfigured =>
      isConfiguredFor(FrontendTemplateProfile.work) && isConfiguredFor(FrontendTemplateProfile.personal);

  FrontendTemplateRoutingConfig copyWith({
    bool? enabled,
    bool? autoRunOnOpen,
    int? workStartMinutes,
    int? workEndMinutes,
    List<int>? workWeekdays,
    String? workPrompt,
    String? personalPrompt,
    String? workAppId,
    String? personalAppId,
  }) {
    return FrontendTemplateRoutingConfig(
      enabled: enabled ?? this.enabled,
      autoRunOnOpen: autoRunOnOpen ?? this.autoRunOnOpen,
      workStartMinutes: workStartMinutes ?? this.workStartMinutes,
      workEndMinutes: workEndMinutes ?? this.workEndMinutes,
      workWeekdays: workWeekdays ?? this.workWeekdays,
      workPrompt: workPrompt ?? this.workPrompt,
      personalPrompt: personalPrompt ?? this.personalPrompt,
      workAppId: workAppId ?? this.workAppId,
      personalAppId: personalAppId ?? this.personalAppId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'auto_run_on_open': autoRunOnOpen,
      'work_start_minutes': workStartMinutes,
      'work_end_minutes': workEndMinutes,
      'work_weekdays': workWeekdays,
      'work_prompt': workPrompt,
      'personal_prompt': personalPrompt,
      'work_app_id': workAppId,
      'personal_app_id': personalAppId,
    };
  }
}

class FrontendTemplateRoutingResult {
  final String conversationId;
  final FrontendTemplateProfile profile;
  final String promptHash;
  final String content;
  final DateTime generatedAt;
  final DateTime conversationStartedAt;

  const FrontendTemplateRoutingResult({
    required this.conversationId,
    required this.profile,
    required this.promptHash,
    required this.content,
    required this.generatedAt,
    required this.conversationStartedAt,
  });

  factory FrontendTemplateRoutingResult.fromJson(Map<String, dynamic> json) {
    return FrontendTemplateRoutingResult(
      conversationId: (json['conversation_id'] ?? '').toString(),
      profile: FrontendTemplateProfile.fromStorageValue(json['profile']?.toString()),
      promptHash: (json['prompt_hash'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      generatedAt: DateTime.tryParse((json['generated_at'] ?? '').toString())?.toLocal() ?? DateTime.now(),
      conversationStartedAt:
          DateTime.tryParse((json['conversation_started_at'] ?? '').toString())?.toLocal() ?? DateTime.now(),
    );
  }

  bool isFreshFor({
    required FrontendTemplateProfile profile,
    required String promptHash,
    required DateTime conversationStartedAt,
  }) {
    return this.profile == profile &&
        this.promptHash == promptHash &&
        this.conversationStartedAt.isAtSameMomentAs(conversationStartedAt) &&
        content.trim().isNotEmpty;
  }

  Map<String, dynamic> toJson() {
    return {
      'conversation_id': conversationId,
      'profile': profile.storageValue,
      'prompt_hash': promptHash,
      'content': content,
      'generated_at': generatedAt.toUtc().toIso8601String(),
      'conversation_started_at': conversationStartedAt.toUtc().toIso8601String(),
    };
  }
}

class FrontendTemplateRouter {
  static DateTime conversationLocalTime({required DateTime? startedAt, required DateTime createdAt}) {
    return (startedAt ?? createdAt).toLocal();
  }

  static FrontendTemplateProfile selectProfile(DateTime conversationLocalTime, FrontendTemplateRoutingConfig config) {
    final currentMinutes = conversationLocalTime.hour * Duration.minutesPerHour + conversationLocalTime.minute;
    final isWorkday = config.workWeekdays.contains(conversationLocalTime.weekday);
    final isDuringWorkHours = currentMinutes >= config.workStartMinutes && currentMinutes < config.workEndMinutes;

    return isWorkday && isDuringWorkHours ? FrontendTemplateProfile.work : FrontendTemplateProfile.personal;
  }

  static String buildPrompt({
    required FrontendTemplateProfile profile,
    required DateTime conversationLocalTime,
    required String? sourceName,
    required String profilePrompt,
  }) {
    final source = sourceName?.trim().isNotEmpty == true ? sourceName!.trim() : 'unknown';
    final localTime = _formatLocalConversationTime(conversationLocalTime);

    return '''
You are summarizing an Omi conversation for Adam.

Routing profile: ${profile.label}
Conversation local time: $localTime
Conversation source: $source

Follow these instructions:
${profilePrompt.trim()}
'''
        .trim();
  }

  static String expectedPromptHash({
    required FrontendTemplateRoutingConfig config,
    required FrontendTemplateProfile profile,
    required DateTime conversationLocalTime,
    required String? sourceName,
  }) {
    final workWeekdays = [...config.workWeekdays]..sort();
    return stableHash(jsonEncode({
      'prompt': buildPrompt(
        profile: profile,
        conversationLocalTime: conversationLocalTime,
        sourceName: sourceName,
        profilePrompt: config.promptFor(profile),
      ),
      'work_start_minutes': config.workStartMinutes,
      'work_end_minutes': config.workEndMinutes,
      'work_weekdays': workWeekdays,
    }));
  }

  static String stableHash(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }

  static String _formatLocalConversationTime(DateTime dateTime) {
    final weekday = _weekdayName(dateTime.weekday);
    final date =
        '${dateTime.year.toString().padLeft(4, '0')}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
    final time = '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
    return '$weekday, $date $time';
  }

  static String _weekdayName(int weekday) {
    switch (weekday) {
      case DateTime.monday:
        return 'Monday';
      case DateTime.tuesday:
        return 'Tuesday';
      case DateTime.wednesday:
        return 'Wednesday';
      case DateTime.thursday:
        return 'Thursday';
      case DateTime.friday:
        return 'Friday';
      case DateTime.saturday:
        return 'Saturday';
      case DateTime.sunday:
        return 'Sunday';
      default:
        return 'Unknown';
    }
  }
}

class FrontendTemplateRoutingStore {
  final SharedPreferencesUtil preferences;

  FrontendTemplateRoutingStore({SharedPreferencesUtil? preferences})
      : preferences = preferences ?? SharedPreferencesUtil();

  FrontendTemplateRoutingConfig loadConfig() {
    final raw = preferences.frontendTemplateRoutingConfigJson;
    if (raw.isEmpty) return FrontendTemplateRoutingConfig.defaults();

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return FrontendTemplateRoutingConfig.fromJson(decoded);
      }
    } catch (_) {
      return FrontendTemplateRoutingConfig.defaults();
    }

    return FrontendTemplateRoutingConfig.defaults();
  }

  Future<bool> saveConfig(FrontendTemplateRoutingConfig config) {
    return preferences.saveString(SharedPreferencesUtil.frontendTemplateRoutingConfigKey, jsonEncode(config.toJson()));
  }

  // Callers construct a store per screen, so the decoded map is shared across
  // instances to avoid re-decoding up to [maxCachedResults] entries per read.
  // All writes go through [saveResult], which mutates this map before persisting.
  static Map<String, FrontendTemplateRoutingResult>? _resultsCache;

  Map<String, FrontendTemplateRoutingResult> loadResults() {
    final cached = _resultsCache;
    if (cached != null) return cached;
    return _resultsCache = _decodeResults();
  }

  Map<String, FrontendTemplateRoutingResult> _decodeResults() {
    final raw = preferences.frontendTemplateRoutingResultsJson;
    if (raw.isEmpty) return {};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};

      final results = <String, FrontendTemplateRoutingResult>{};
      decoded.forEach((conversationId, value) {
        if (value is Map<String, dynamic>) {
          final result = FrontendTemplateRoutingResult.fromJson({
            ...value,
            'conversation_id': value['conversation_id'] ?? conversationId,
          });
          if (result.conversationId.isNotEmpty) {
            results[result.conversationId] = result;
          }
        }
      });
      return results;
    } catch (_) {
      return {};
    }
  }

  FrontendTemplateRoutingResult? resultForConversation(String conversationId) {
    return loadResults()[conversationId];
  }

  /// Cached overlays are regenerable views (already invalidated on any prompt or
  /// schedule change via promptHash), so the cache is bounded: evicted entries
  /// simply regenerate the next time their conversation is opened.
  static const int maxCachedResults = 500;

  Future<bool> saveResult(FrontendTemplateRoutingResult result) {
    final results = loadResults();
    results[result.conversationId] = result;
    if (results.length > maxCachedResults) {
      final byAge = results.values.toList()..sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
      results
        ..clear()
        ..addEntries(byAge.take(maxCachedResults).map((r) => MapEntry(r.conversationId, r)));
    }
    final encoded = results.map((conversationId, result) => MapEntry(conversationId, result.toJson()));
    return preferences.saveString(SharedPreferencesUtil.frontendTemplateRoutingResultsKey, jsonEncode(encoded));
  }
}
