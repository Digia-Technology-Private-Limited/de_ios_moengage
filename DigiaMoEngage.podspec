Pod::Spec.new do |s|
  s.name             = 'DigiaMoEngage'
  s.version          = '1.0.0'
  s.summary          = 'Digia Engage MoEngage plugin for iOS.'
  s.description      = <<-DESC
    Routes MoEngage self-handled in-app campaigns into Digia Engage.
  DESC
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/de_ios_moengage'
  s.license          = { :type => 'BUSL-1.1', :file => 'LICENSE' }
  s.author           = { 'Digia Engg' => 'engg@digia.tech' }
  s.source           = {
    :git => 'https://github.com/Digia-Technology-Private-Limited/de_ios_moengage.git',
    :tag => s.version.to_s
  }
  # Follows core, which requires iOS 15 — see the matching comment in Package.swift.
  # MoEngageCore itself only needs iOS 11, so core is the binding floor, not MoEngage.
  s.platform         = :ios, '15.0'
  s.swift_version    = '6.0'
  s.source_files     = 'Sources/DigiaMoEngage/**/*.swift'

  # A range, never an exact pin: CocoaPods has to satisfy every podspec in the
  # host app's graph at once, and two exact pins on the same pod deadlock
  # resolution outright — the clevertap_plugin 3.8.1 failure mode.
  s.dependency 'DigiaEngage', '~> 4.0'

  # Depend on MoEngage's umbrella pod, not on MoEngageCore and MoEngageInApps
  # separately. MoEngage's module pods declare no version limits on one another,
  # so on a clean install CocoaPods floats each to its newest release and mixes
  # builds from different MoEngage lines (MoEngageMessaging 6.x, from MoEngage 11,
  # beside MoEngageCore 10.x does not compile). Every umbrella version pins one
  # matching set of modules, and its InApps subspec brings in MoEngageCore and
  # MoEngageInApps, which Sources/DigiaMoEngage imports directly.
  #
  # The umbrella pod's version is the MoEngage release number, the same one SPM
  # uses, so the floor carries over: 9.18.0 is the oldest release supported on
  # CocoaPods (MoEngageInApps 6.01.0). Package.swift starts at 9.23.0 only because
  # earlier tags carry no Package.swift. The ceiling stops before 11.00.0: that
  # line ships MoEngageInApps as a statically linked binary, which CocoaPods
  # refuses under a dynamic framework unless this pod sets `static_framework`.
  # Raise it together with that decision, and lint.
  s.dependency 'MoEngage-iOS-SDK/InApps', '>= 9.18.0', '< 11.0.0'
end
