# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Swift sources are UTF-8; do not let an unset shell locale (US-ASCII) decide.
Encoding.default_external = Encoding::UTF_8

class WatchRecordingRecoveryTest < Minitest::Test
  IOS = File.expand_path('..', __dir__)
  SCENARIOS = %w[roundtrip custody restart_tail stale_session storage_full unbound wrong_owner receipt_after_delete conflicting_retry corrupt_audio invalid_metadata out_of_order_rotation damaged_partial conflicting_partial oversized_partial transfer_queue bounded_writer].freeze

  def self.binary
    return @binary if @binary
    @directory = Dir.mktmpdir('omi-watch-recovery')
    @binary = File.join(@directory, 'recovery')
    source = File.join(IOS, 'Runner/WatchRecordingStore.swift')
    harness = File.join(IOS, 'test/fixtures/watch_recording_store_harness.swift')
    stdout, stderr, status = Open3.capture3('swiftc', '-parse-as-library', source, harness, '-o', @binary)
    raise "compile failed:\n#{stdout}\n#{stderr}" unless status.success?
    Minitest.after_run { FileUtils.remove_entry(@directory) }
    @binary
  end

  SCENARIOS.each do |scenario|
    define_method("test_#{scenario}") do
      stdout, stderr, status = Open3.capture3(self.class.binary, scenario)
      assert status.success?, "#{scenario} failed:\n#{stdout}\n#{stderr}"
      assert_equal "ok: #{scenario}\n", stdout
    end
  end

  def test_real_watch_and_phone_keep_file_custody_independent_of_live_recording_state
    watch = File.read(File.join(IOS, 'omiWatchApp/WatchAudioRecorderViewModel.swift'))
    phone = File.read(File.join(IOS, 'Runner/AppDelegate.swift'))
    receiver = phone.split('func session(_ session: WCSession, didReceive file: WCSessionFile)', 2).last.split('// Receive a message from watch', 2).first
    assert_includes watch, 'try archive?.append(bytes, sessionID: archiveSession)'
    assert_includes watch, 'session.transferFile(url'
    assert_includes watch, 'try archive?.acknowledge(fileName: name, digest: digest)'
    assert_includes receiver, 'WatchRecordingInbox.receive('
    assert_includes receiver, 'watchRecordingReceipt'
    refute_includes receiver, 'isRecordingActive'
    refute_includes receiver, 'Task {'
    project = File.read(File.join(IOS, 'Runner.xcodeproj/project.pbxproj'))
    assert_equal 3, project.scan(/WatchRecordingStore.swift in Sources \*\/,/).size, 'both phone flavors and the watch must compile the store'
  end

  # Static integration tripwire: WatchConnectivity and the microphone controller
  # require watchOS; host custody/receipt behavior is exercised by the Swift harnesses.
  def test_fork_quick_capture_and_standard_recovery_remain_wired_together
    phone = File.read(File.join(IOS, 'Runner/AppDelegate.swift'))
    watch = File.read(File.join(IOS, 'omiWatchApp/WatchAudioRecorderViewModel.swift'))
    host = File.read(File.join(IOS, 'Runner/RecorderHostApiImpl.swift'))
    quick = File.read(File.join(IOS, 'omiWatchApp/WatchQuickCapture.swift'))
    app = File.read(File.join(IOS, 'omiWatchApp/omiwatchApp.swift'))
    assert_equal 1, phone.scan('func session(_ session: WCSession, didReceive file: WCSessionFile)').size
    assert_includes phone, 'receiveQuickCapture(file)'
    assert_includes phone, 'WatchRecordingInbox.receive('
    assert_includes host, 'var context = session.applicationContext'
    assert_includes watch, 'self.quickCapture.receiveAccountContext(applicationContext)'
    assert_includes watch, 'case "quickCaptureReceipt":'
    assert_includes watch, 'case "watchRecordingReceipt":'
    assert_includes watch, 'guard !isRecording, !isStarting, quickCapture.active == nil, !quickCapture.starting'
    assert_includes watch, 'guard quickCapture.active == nil, !quickCapture.starting else { return }'
    assert_includes quick, '@ObservedObject var recorder: WatchAudioRecorderViewModel'
    assert_includes quick, 'if let error = recorder.recoveryError'
    assert_includes quick, 'if recorder.pendingRecoverySegments > 0'
    assert_includes quick, 'recorder.retryRecoveryTransfers()'
    assert_includes app, 'WatchQuickCaptureView(capture: viewModel.quickCapture, recorder: viewModel)'
  end

end
