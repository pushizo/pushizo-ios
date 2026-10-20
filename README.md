# Pushizo iOS SDK

APNs kaydı, kullanıcı/tag/alias yönetimi, olaylar, in-app mesajlar, Live Activities ve teslimat geri bildirimi için
Swift paketi. Swift 5.9, iOS 15+ ve Mac Catalyst 15+.

| Kütüphane | Hedef |
|-----------|-------|
| `Pushizo` | Uygulama hedefi |
| `PushizoExtension` | Notification Service Extension (zengin bildirim, teslimat geri bildirimi) |

İkisi de ortak `PushizoCore` hedefine bağlıdır; ayrıca eklenmez.

## Kurulum

**Swift Package Manager:** Xcode → File → Add Package Dependencies →
`https://github.com/exec0de/pushizo-ios` (Up to Next Major, `0.1.0`). Uygulama hedefine `Pushizo`, NSE hedefine
`PushizoExtension` ekleyin. `Package.swift` ile:

```swift
.package(url: "https://github.com/exec0de/pushizo-ios", from: "0.1.0")
```

**CocoaPods:**

```ruby
target 'App' do
  pod 'Pushizo'
end
target 'NotificationService' do
  pod 'Pushizo/Extension'
end
```

## Başlatma

```swift
Pushizo.initialize("app_…", launchOptions: launchOptions)

func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Pushizo.setDeviceToken(deviceToken)
}
```

APNs anahtarı, Xcode yetenekleri, NSE kurulumu ve tüm API: [docs.pushizo.com/docs/sdk/ios](https://docs.pushizo.com/docs/sdk/ios).

## Lisans

MIT — bkz. [LICENSE](LICENSE).
