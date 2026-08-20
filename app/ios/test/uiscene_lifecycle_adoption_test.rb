# frozen_string_literal: true

require 'minitest/autorun'

# Static checker. Guards the UIScene lifecycle adoption the iOS 26+ SDK requires.
#
# Building against the iOS 27 SDK without a UIApplicationSceneManifest terminates
# the app at launch inside
# _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption, before any Dart
# runs, so there is no in-app seam to assert against. The second failure mode is
# quieter and worse: once a scene delegate exists UIKit stops calling
# applicationWillEnterForeground(_:) and application(_:open:options:), and the
# window is nil in didFinishLaunchingWithOptions, so an app that launches fine can
# still have dead BLE, dead deep links, and no native bridges. These assertions
# pin both classes to the source.
class UISceneLifecycleAdoptionTest < Minitest::Test
  IOS_ROOT = File.expand_path('..', __dir__)
  INFO_PLIST = File.join(IOS_ROOT, 'Runner', 'Info.plist')
  APP_DELEGATE = File.join(IOS_ROOT, 'Runner', 'AppDelegate.swift')
  SCENE_DELEGATE = File.join(IOS_ROOT, 'Runner', 'SceneDelegate.swift')
  PROJECT_FILE = File.join(IOS_ROOT, 'Runner.xcodeproj', 'project.pbxproj')

  def test_info_plist_declares_a_scene_manifest_naming_the_scene_delegate
    plist = File.read(INFO_PLIST)
    assert_includes plist, 'UIApplicationSceneManifest',
                    'Info.plist must declare UIApplicationSceneManifest; without it the iOS 26+ SDK terminates the app at launch'
    assert_includes plist, 'UISceneDelegateClassName'
    assert_includes plist, '$(PRODUCT_MODULE_NAME).SceneDelegate'
    assert_includes plist, 'UISceneStoryboardFile'
  end

  def test_scene_delegate_is_compiled_into_the_runner_target
    assert File.exist?(SCENE_DELEGATE), 'SceneDelegate.swift must exist'
    project = File.read(PROJECT_FILE)
    assert_includes project, 'SceneDelegate.swift in Sources',
                    'SceneDelegate.swift must be in the Runner target Sources build phase, or the class named in Info.plist will not exist at runtime'
  end

  def test_scene_delegate_forwards_the_lifecycle_the_app_delegate_stops_receiving
    source = File.read(SCENE_DELEGATE)
    assert_includes source, 'registerFlutterBridges',
                    'the scene delegate must register the native bridges once the FlutterViewController exists'
    assert_includes source, 'sceneWillEnterForeground',
                    'BLE stale-link reconnect runs on foreground; UIKit stops calling the app-delegate version under scenes'
    assert_includes source, 'openURLContexts',
                    'Ray-Ban Meta registration and the omi:// deep link arrive through the scene under UIScene'
    assert_includes source, 'handleIncomingURL'
  end

  def test_launch_does_not_force_unwrap_the_window_root_view_controller
    launch = File.read(APP_DELEGATE)[/didFinishLaunchingWithOptions.*?\n  \}/m]
    refute_nil launch, 'could not locate didFinishLaunchingWithOptions'
    refute_includes launch, 'window?.rootViewController',
                     'the window does not exist yet under the UIScene lifecycle; move messenger wiring into registerFlutterBridges(with:)'
    refute_includes launch, 'controller!',
                     'force-unwrapping the FlutterViewController at launch crashes under the UIScene lifecycle'
  end

  def test_app_delegate_keeps_scene_reachable_hooks
    source = File.read(APP_DELEGATE)
    assert_includes source, 'func registerFlutterBridges(with controller: FlutterViewController)'
    assert_includes source, 'func handleWillEnterForeground()'
    assert_includes source, 'func handleIncomingURL(_ url: URL) -> Bool'
    assert_includes source, 'if didRegisterFlutterBridges { return }',
                    'bridge registration must be idempotent; a second scene must not re-register channels'
  end
end
