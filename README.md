<!-- pushizo:header -->
<p align="center">
  <a href="https://pushizo.com"><img src="https://raw.githubusercontent.com/pushizo/.github/main/profile/assets/mark.svg" alt="Pushizo" width="56" height="56"></a>
</p>
<p align="center">
  <a href="https://docs.pushizo.com/docs/sdk/ios"><img src="https://img.shields.io/badge/docs-docs.pushizo.com-5b4bdb" alt="Docs"></a>
  <a href="https://docs.pushizo.com/docs/api"><img src="https://img.shields.io/badge/API-reference-b44fc4" alt="API reference"></a>
  <a href="https://github.com/pushizo/pushizo-ios/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-16130f" alt="License: MIT"></a>
</p>
<p align="center"><a href="#english">English</a> · <a href="#türkçe">Türkçe</a></p>

## English

**Pushizo iOS SDK** — Swift package for APNs registration, users, tags and aliases, events, in-app messages, Live Activities and delivery receipts. Swift 5.9, iOS 15+ and Mac Catalyst 15+. Add `Pushizo` to the app target and `PushizoExtension` to the Notification Service Extension.

```swift
.package(url: "https://github.com/pushizo/pushizo-ios", from: "0.1.0")
```

```ruby
pod 'Pushizo'               # app target
pod 'Pushizo/Extension'     # Notification Service Extension
```

The detailed guide below is in Turkish; code samples are language-neutral. Full documentation:
[docs.pushizo.com/docs/sdk/ios](https://docs.pushizo.com/docs/sdk/ios) · API reference: [docs.pushizo.com/docs/api](https://docs.pushizo.com/docs/api).

## Türkçe
<!-- /pushizo:header -->

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
`https://github.com/pushizo/pushizo-ios` (Up to Next Major, `0.1.1`). Uygulama hedefine `Pushizo`, NSE hedefine
`PushizoExtension` ekleyin. `Package.swift` ile:

```swift
.package(url: "https://github.com/pushizo/pushizo-ios", from: "0.1.1")
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

<!-- pushizo:footer -->
---

## Support · Destek

- **Guide · Rehber:** [docs.pushizo.com/docs/sdk/ios](https://docs.pushizo.com/docs/sdk/ios)
- **API reference & OpenAPI · API referansı ve OpenAPI:** [docs.pushizo.com/docs/api](https://docs.pushizo.com/docs/api) ·
  [pushizo-openapi](https://github.com/pushizo/pushizo-openapi)
- **Bugs & ideas · Hata ve öneri:** [Issues](https://github.com/pushizo/pushizo-ios/issues)
- **Security · Güvenlik:** please do not open public issues; email [security@pushizo.com](mailto:security@pushizo.com) ·
  herkese açık issue açmayın, bu adrese yazın.
- **Help · Destek:** [support@pushizo.com](mailto:support@pushizo.com)

This repository is mirrored automatically from the Pushizo main repository on every release. Please open an issue
instead of a pull request; fixes land in the main repository and ship with the next release.
Bu depo her sürümde Pushizo ana deposundan otomatik yansıtılır. Pull request yerine issue açın; düzeltmeler ana depoda
yapılır ve bir sonraki sürümle buraya gelir.

Released under the MIT License · MIT lisanslıdır — [LICENSE](https://github.com/pushizo/pushizo-ios/blob/main/LICENSE).
<!-- /pushizo:footer -->
