import Foundation
#if canImport(PushizoCore)
import PushizoCore
#endif

extension Pushizo {
    /**
     Mobil reklam kimliği (IDFA; v3 Faz 22, ADR-0037). SDK `AdSupport` ve ATT istemi içermez: uygulama App Tracking
     Transparency izni aldıysa kimliği verir; izin yoksa iOS sıfır kimlik döner ve SDK bunu silme olarak gönderir.
     Kimlik reklam kitlesine yalnızca `ads_personalization` rızası olan kullanıcıda ve SHA-256 özetiyle gider.

     ```swift
     import AdSupport
     import AppTrackingTransparency
     ATTrackingManager.requestTrackingAuthorization { status in
         Pushizo.Ads.setAdvertisingId(status == .authorized ? ASIdentifierManager.shared().advertisingIdentifier.uuidString : nil)
     }
     ```
     */
    public enum Ads {
        /// Reklam kimliğini yazar; `nil` veya sıfır kimlik sunucudaki kaydı siler.
        public static func setAdvertisingId(_ id: String?) {
            guard storage != nil else {
                HSLog.log(.error, "Ads.setAdvertisingId: önce Pushizo.initialize çağrılmalı")
                return
            }
            enqueue(HSAdsRules.operation(advertisingId: id))
        }
    }
}
