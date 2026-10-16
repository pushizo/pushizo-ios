import Foundation
#if canImport(PushizoCore)
import PushizoCore
#endif
import CoreLocation
import UIKit

extension Pushizo {
    /**
     Konum paylaşımı (v2 Faz 17b; yalnızca ön plan, arka plan konumu yok). Paylaşım açıkken konum oturum başında ve
     uygulama ön plana döndüğünde en sık 5 dakikada bir push aboneliğine yazılır (`PATCH /subscriptions/{id}` `location`).
     İzin yoksa veya gizlilik onayı verilmemişse hiçbir şey gönderilmez. İlk konum sunucuda KVKK açık rıza kaydı sayılır;
     `setShared(false)` konumu ve rıza kaydını hemen sildirir. Tercih kalıcıdır.

     Info.plist'e `NSLocationWhenInUseUsageDescription` eklenmelidir; SDK yalnızca "kullanırken" iznini ister (Always
     istemez). iOS, iPadOS ve Mac Catalyst'te çalışır.

     ```swift
     Pushizo.Location.requestPermission(rationale: "Yakındaki mağazaları göstermek için konumunuzu kullanırız.") { granted in
         if granted { Pushizo.Location.setShared(true) }
     }
     ```
     */
    public enum Location {
        /// Paylaşım açık mı (kalıcı tercih; izin durumundan bağımsız).
        public static var isShared: Bool { storage?.locationShared ?? false }

        /// Paylaşımı açar/kapatır. Açılırken izin varsa konum hemen gönderilir; kapatılınca `location: null` gönderilir.
        public static func setShared(_ shared: Bool) {
            guard let store = storage else {
                HSLog.log(.error, "Location.setShared: önce Pushizo.initialize çağrılmalı")
                return
            }
            let wasShared = store.locationShared
            store.locationShared = shared
            if shared {
                refresh(force: !wasShared)
                return
            }
            store.locationLastSentAt = nil
            // Sunucudaki konum ve rıza kaydı silinir (onay bekleniyorsa kuyrukta bekler).
            if wasShared { enqueue(HSLocationRules.clearOperation()) }
        }

        /**
         "Kullanırken" konum iznini ister (`requestWhenInUseAuthorization`). İzin henüz sorulmadıysa önce açıklama uyarısı
         gösterilir (`rationale`, verilmezse SDK'nın yerelleştirilmiş metni); kullanıcı vazgeçerse sistem istemi açılmaz. Sonuç ana iş
         parçacığında döner: izin varsa veya verildiyse true; reddedilmiş/kısıtlıysa false (yeniden sorulamaz, kullanıcı
         Ayarlar'a yönlendirilmelidir). Info.plist'te `NSLocationWhenInUseUsageDescription` yoksa false.
         */
        public static func requestPermission(rationale: String? = nil, completion: @escaping (Bool) -> Void) {
            HSLocationController.shared.requestPermission(rationale: rationale, completion: completion)
        }

        /// `requestPermission(rationale:completion:)` için async sürüm.
        public static func requestPermission(rationale: String? = nil) async -> Bool {
            await withCheckedContinuation { continuation in
                requestPermission(rationale: rationale) { granted in continuation.resume(returning: granted) }
            }
        }

        /// Paylaşım açık, izin var ve aralık dolmuşsa konumu alıp kuyruğa yazar (oturum başı / ön plana dönüş).
        static func refresh(force: Bool = false) {
            guard isInitialized else { return }
            HSLocationController.shared.refresh(force: force)
        }

        /// Alınan konumu kuyruğa yazar; beklerken paylaşım kapatıldıysa veya onay geri çekildiyse gönderilmez.
        static func send(latitude: Double, longitude: Double, accuracy: Double?) {
            guard let store = storage, store.locationShared, networkAllowed,
                  let location = HSLocationRules.payload(latitude: latitude, longitude: longitude, accuracy: accuracy) else { return }
            store.locationLastSentAt = Date().timeIntervalSince1970
            enqueue(HSLocationRules.operation(location: location))
        }
    }
}

/**
 CoreLocation sarmalayıcısı: tek seferlik konum (`requestLocation`, ~100 m doğruluk) ve izin istemi. Tüm durum ana iş
 parçacığında tutulur (`CLLocationManager` oluşturulduğu iş parçacığının çalışma döngüsünde geri çağırır).
 */
final class HSLocationController: NSObject, CLLocationManagerDelegate {
    static let shared = HSLocationController()

    private var manager: CLLocationManager?
    private var fetching = false
    private var awaitingAuthorization = false
    private var permissionCompletions: [(Bool) -> Void] = []

    static func isGranted(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private func locationManager() -> CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager = created
        return created
    }

    func refresh(force: Bool) {
        DispatchQueue.main.async { self.refreshOnMain(force: force) }
    }

    private func refreshOnMain(force: Bool) {
        guard let store = Pushizo.storage, store.locationShared else { return }
        // Yalnızca ön plan: arka planda (sessiz push ile uyanma vb.) konum okunmaz.
        guard UIApplication.shared.applicationState != .background else { return }
        let granted = Self.isGranted(locationManager().authorizationStatus)
        guard HSLocationRules.isDue(
            shared: store.locationShared,
            networkAllowed: Pushizo.networkAllowed,
            permissionGranted: granted,
            lastSentAt: store.locationLastSentAt,
            now: Date().timeIntervalSince1970,
            force: force
        ) else { return }
        guard !fetching else { return }
        fetching = true
        locationManager().requestLocation()
    }

    func requestPermission(rationale: String?, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let status = self.locationManager().authorizationStatus
            if Self.isGranted(status) {
                completion(true)
                self.refreshOnMain(force: false)
                return
            }
            // Reddedilmiş/kısıtlı izin yeniden sorulamaz.
            guard status == .notDetermined else { completion(false); return }
            guard Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil else {
                HSLog.log(.error, "Info.plist'te NSLocationWhenInUseUsageDescription yok; konum izni istenemez")
                completion(false)
                return
            }
            // Önce açıklama (verilmezse varsayılan metin); gösterilecek pencere yoksa doğrudan sistem istemi.
            if let presenter = Self.topViewController() {
                let texts = HSLocationTexts.current
                let message = (rationale?.isEmpty == false) ? rationale : texts.message
                let alert = UIAlertController(title: texts.title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: texts.cancel, style: .cancel) { _ in completion(false) })
                alert.addAction(UIAlertAction(title: texts.accept, style: .default) { _ in self.askSystem(completion) })
                presenter.present(alert, animated: true)
            } else {
                self.askSystem(completion)
            }
        }
    }

    /// Sistem istemi; sonuç `locationManagerDidChangeAuthorization` ile gelir (bekleyen tüm çağıranlara).
    private func askSystem(_ completion: @escaping (Bool) -> Void) {
        let manager = locationManager()
        if manager.authorizationStatus != .notDetermined {
            completion(Self.isGranted(manager.authorizationStatus))
            return
        }
        permissionCompletions.append(completion)
        guard !awaitingAuthorization else { return }
        awaitingAuthorization = true
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        if awaitingAuthorization {
            awaitingAuthorization = false
            let completions = permissionCompletions
            permissionCompletions = []
            completions.forEach { $0(Self.isGranted(status)) }
        }
        // İzin yeni verildiyse ve paylaşım açıksa konum hemen gönderilir.
        if Self.isGranted(status) { refreshOnMain(force: false) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fetching = false
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        Pushizo.Location.send(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fetching = false
        // Konum geçici olarak alınamadı (ör. kapalı alan); sonraki ön plana dönüşte yeniden denenir.
        HSLog.log(.debug, "konum alınamadı: \(error.localizedDescription)")
    }

    /// Açıklama uyarısını gösterecek en üstteki görünüm denetleyicisi (etkin sahnenin anahtar penceresi).
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Açıklama uyarısı metinleri (cihaz dili Türkçe ise Türkçe, değilse İngilizce; Android SDK metinleriyle aynı).
struct HSLocationTexts {
    let title: String
    let message: String
    let accept: String
    let cancel: String

    static var current: HSLocationTexts {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return language.hasPrefix("tr")
            ? HSLocationTexts(
                title: "Konumunuzu paylaşın",
                message: "Yakınınızdaki ilgili bildirimleri gönderebilmek için yaklaşık konumunuzu yalnızca uygulama açıkken kullanırız. Bu ayarı istediğiniz zaman kapatabilirsiniz.",
                accept: "Devam",
                cancel: "Şimdi değil"
            )
            : HSLocationTexts(
                title: "Share your location",
                message: "We use your approximate location only while the app is open, to send you relevant nearby notifications. You can turn this off at any time.",
                accept: "Continue",
                cancel: "Not now"
            )
    }
}
