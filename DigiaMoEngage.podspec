Pod::Spec.new do |s|
  s.name             = 'DigiaMoEngage'
  s.version          = '1.0.0'
  s.summary          = 'Digia Engage MoEngage plugin for iOS.'
  s.description      = <<-DESC
    Routes MoEngage self-handled in-app campaigns into Digia Engage.
  DESC
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_moengage_iOS'
  s.license          = { :type => 'BUSL-1.1', :file => 'LICENSE' }
  s.author           = { 'Digia Engg' => 'engg@digia.tech' }
  s.source           = {
    :git => 'https://github.com/Digia-Technology-Private-Limited/digia_moengage_iOS.git',
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
  s.dependency 'DigiaEngage', '~> 3.14'

  # MoEngage's CocoaPods and SPM release lines use different version numbers for
  # the same underlying release, so the ranges below are NOT copy-pasted from
  # Package.swift's `from: "9.18.0"` — they are the CocoaPods coordinates for
  # the same code, worked out against MoEngage's published podspecs:
  #
  # - MoEngageCore's pod version tracks the SDK's umbrella tag 1:1 (pod 9.18.0
  #   ships from github.com/moengage/MoEngage-iOS-SDK tag 9.18.0, pod 9.24.0
  #   from apple-sdk tag 9.24.0 — verified via the podspecs' own `s.source`).
  #   So the SPM `from: "9.18.0"` floor (>= 9.18.0, < 10.0.0) carries over as-is.
  # - MoEngageInApps (the SPM product this plugin imports) is versioned on its
  #   OWN module line, offset from the umbrella by -3 majors: pod 6.01.0 ships
  #   from umbrella tag 9.18.0, pod 6.06.0 from 9.24.0, pod 7.00.0 from the next
  #   umbrella major 10.00.0 (confirmed the same way, via each podspec's
  #   `s.source`). 6.01.0 is therefore the pod version matching the SPM floor,
  #   and 7.00.0 — which also bumps MoEngage's own iOS floor to 13 and moves the
  #   source repo to moengage/apple-sdk — is the next-major cutoff.
  #
  # Sources/DigiaMoEngage imports both MoEngageCore and MoEngageInApps directly,
  # so both are declared here rather than left to resolve transitively through
  # MoEngageInApps's own (unconstrained) dependency on MoEngageCore.
  s.dependency 'MoEngageCore', '>= 9.18.0', '< 11.0.0'
  s.dependency 'MoEngageInApps', '>= 6.01.0', '< 8.00.0'
end
