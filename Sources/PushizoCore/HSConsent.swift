import Foundation

/**
 Gizlilik onayı (KVKK/GDPR) kapısı: `requiresPrivacyConsent` açıkken onay verilmeden hiçbir ağ çağrısı yapılmaz; işlemler
 kalıcı kuyrukta (NSE'de `pendingReceived` listesinde) bekler ve onay verilince gönderilir.

 Onay geri çekildiğinde (`setConsentGiven(false)`) ağ çağrıları hemen durur; o ana kadar gönderilmemiş işlemler ve
 bekleyen `received` kayıtları silinir, cihazdaki kullanıcı kimliği temizlenir (onaysız döneme ait veri sonradan
 gönderilmez). Push aboneliği kimliği ve token cihazda korunur; sunucudaki abonelik silinmez.
 */
public enum HSConsent {
    /// Ağ çağrısı yapılabilir mi: onay gerekmiyorsa ya da verildiyse.
    public static func allowsNetwork(required: Bool, given: Bool) -> Bool { !required || given }

    /**
     NSE için: uygulamanın App Group'a yazdığı `requiresPrivacyConsent` ve onay durumu okunur. `required` NSE'nin kendi
     seçeneğidir; App Group paylaşılmıyorsa bile onay zorunluluğunun kaybolmaması için ikisinden biri yeterlidir.
     */
    public static func allowsNetwork(storage: HSStorage, required: Bool = false) -> Bool {
        allowsNetwork(required: required || storage.privacyConsentRequired, given: storage.consentGiven)
    }
}
