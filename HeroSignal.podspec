Pod::Spec.new do |s|
  s.name             = 'HeroSignal'
  s.version          = '0.1.0'
  s.summary          = 'HeroSignal iOS SDK: APNs kaydı, kullanıcı/tag yönetimi, olaylar, teslimat geri bildirimi'
  s.homepage         = 'https://github.com/exec0de/herosignal/tree/main/sdk/ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'HeroSignal' => 'sdk@herosignal.dev' }
  s.documentation_url = 'https://github.com/exec0de/herosignal/blob/main/docs/sdk/ios.md'
  s.source           = { :git => 'https://github.com/exec0de/herosignal.git', :tag => "sdk-v#{s.version}" }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/HeroSignalCore/**/*.swift'
    core.frameworks = 'UserNotifications'
    # Live Activities (iOS 16.1+): iOS 15 hedefinde yüklenebilmesi için zayıf bağlanır.
    core.weak_frameworks = 'ActivityKit'
  end

  s.subspec 'App' do |app|
    app.dependency 'HeroSignal/Core'
    app.source_files = 'Sources/HeroSignal/**/*.swift'
    app.frameworks = 'UIKit', 'UserNotifications'
  end

  s.subspec 'Extension' do |ext|
    ext.dependency 'HeroSignal/Core'
    ext.source_files = 'Sources/HeroSignalExtension/**/*.swift'
    ext.frameworks = 'UserNotifications'
  end

  s.default_subspecs = 'App'
end
