Pod::Spec.new do |s|
  s.name             = 'Pushizo'
  s.version          = '0.1.0'
  s.summary          = 'Pushizo iOS SDK: APNs kaydı, kullanıcı/tag yönetimi, olaylar, teslimat geri bildirimi'
  s.homepage         = 'https://github.com/exec0de/pushizo-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Pushizo' => 'bildirim@pushizo.com' }
  s.documentation_url = 'https://docs.pushizo.com/docs/sdk/ios'
  # Kaynak: `sdk/ios` alt ağacının açık deposu (ana depo gizli); sürüm etiketi düz X.Y.Z (sdk/scripts/publish.mjs ios).
  s.source           = { :git => 'https://github.com/exec0de/pushizo-ios.git', :tag => s.version.to_s }
  # Mac Catalyst: CocoaPods iOS platformundaki pod'u Catalyst hedefinde de derler (ayrı `osx` platformu gerekmez);
  # Live Activities Catalyst'te `PLATFORM_NOT_SUPPORTED` döner (docs/sdk/ios.md "Mac Catalyst").
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/PushizoCore/**/*.swift'
    core.frameworks = 'UserNotifications'
    # Live Activities (iOS 16.1+): iOS 15 hedefinde yüklenebilmesi için zayıf bağlanır.
    core.weak_frameworks = 'ActivityKit'
  end

  s.subspec 'App' do |app|
    app.dependency 'Pushizo/Core'
    app.source_files = 'Sources/Pushizo/**/*.swift'
    # CoreLocation: yalnızca ön planda konum paylaşımı (`Pushizo.Location`, v2 Faz 17b).
    # WebKit: HTML in-app mesajlarının yalıtılmış WKWebView çizimi (v2 Faz 18, ADR-0027).
    app.frameworks = 'UIKit', 'UserNotifications', 'CoreLocation', 'WebKit'
  end

  s.subspec 'Extension' do |ext|
    ext.dependency 'Pushizo/Core'
    ext.source_files = 'Sources/PushizoExtension/**/*.swift'
    ext.frameworks = 'UserNotifications'
  end

  s.default_subspecs = 'App'
end
