# frozen_string_literal: true

require 'minitest/autorun'

# Static checker. Guards the App Group identity the main app and the battery
# widget share.
#
# The widget resolves the group from its Info.plist key, which the build sets
# from $(APP_GROUP_IDENTIFIER), while the app once hardcoded the upstream group.
# On any build whose APP_GROUP_IDENTIFIER differs from upstream's (every locally
# signed build), the app wrote to a suite it is not entitled to and iOS silently
# redirected it to a private container, so the widget read an empty suite
# forever. Nothing failed: the widget just never updated, which is why this needs
# a source-level pin rather than a runtime assertion.
class AppGroupIdentityTest < Minitest::Test
  IOS_ROOT = File.expand_path('..', __dir__)
  RUNNER_INFO_PLIST = File.join(IOS_ROOT, 'Runner', 'Info.plist')
  WIDGET_INFO_PLIST = File.join(IOS_ROOT, 'BatteryWidget-Info.plist')
  RUNNER_SOURCES = Dir[File.join(IOS_ROOT, 'Runner', '**', '*.swift')]

  def test_both_targets_declare_the_group_from_the_same_build_setting
    [RUNNER_INFO_PLIST, WIDGET_INFO_PLIST].each do |plist|
      name = File.basename(plist)
      assert File.exist?(plist), "#{name} must exist; a moved plist would make this guard vacuous"

      contents = File.read(plist)
      assert_includes contents, 'OmiAppGroupIdentifier',
                      "#{name} must declare OmiAppGroupIdentifier so the app and the widget resolve one group"
      assert_includes contents, '$(APP_GROUP_IDENTIFIER)',
                      "#{name} must resolve the group from the build setting, not a literal"
    end
  end

  def test_no_runner_source_hardcodes_an_app_group_literal
    offenders = RUNNER_SOURCES.reject { |path| path.end_with?('AppDelegate.swift') }.filter_map do |path|
      line = File.readlines(path).find { |l| l =~ /suiteName:\s*"group\./ }
      "#{path.sub("#{IOS_ROOT}/", '')}: #{line.strip}" if line
    end
    assert_empty offenders,
                 "App Group suites must come from AppDelegate.appGroupIdentifier, not a literal; a literal silently diverges from the widget on any non-upstream signing identity"
  end

  def test_app_delegate_resolves_the_group_from_the_info_plist
    source = File.read(File.join(IOS_ROOT, 'Runner', 'AppDelegate.swift'))
    assert_includes source, 'forInfoDictionaryKey: "OmiAppGroupIdentifier"',
                    'AppDelegate must read the group from Info.plist so it tracks APP_GROUP_IDENTIFIER like the widget does'
    refute_match(/UserDefaults\(suiteName:\s*"group\./, source,
                 'AppDelegate must not hardcode an App Group suite')
  end
end
