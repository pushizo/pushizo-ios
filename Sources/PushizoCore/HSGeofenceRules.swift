import Foundation

/// Sunucunun döndürdüğü bölge (ADR-0065 §3).
public struct HSGeofenceRegion: Equatable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let radius: Double

    public init(id: String, latitude: Double, longitude: Double, radius: Double) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

/**
 Arka plan bölge izlemenin CoreLocation'dan bağımsız kuralları (birim testli). İşletim sistemi bölgeyi izler, sunucuya yalnızca giriş ve çıkış
 bildirilir, konum gönderilmez.
 */
public enum HSGeofenceRules {
    public static let operationType = "geofence_event"
    /// iOS uygulama başına en fazla 20 bölge izler; uygulamanın kendi bölgelerine yer bırakmak için ayarlanamaz.
    public static let maxRegions = 20
    public static let syncInterval: TimeInterval = 6 * 60 * 60
    public static let syncDistance: Double = 5_000
    /// Yalnızca bu önekteki bölgelere dokunulur; uygulamanın kendi bölgeleri korunur.
    public static let identifierPrefix = "pushizo:"
    private static let earthRadius = 6_371_008.8

    public static func distance(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = pow(sin(dLat / 2), 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * pow(sin(dLng / 2), 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Bölge listesi yenilenmeli mi: hiç alınmadı, süre doldu, saat geri alındı veya kullanıcı uzaklaştı.
    public static func isSyncDue(enabled: Bool, lastSyncAt: TimeInterval?, lastLatitude: Double?, lastLongitude: Double?, latitude: Double, longitude: Double, now: TimeInterval) -> Bool {
        guard enabled else { return false }
        guard let last = lastSyncAt, let lastLatitude, let lastLongitude else { return true }
        if now < last || now - last >= syncInterval { return true }
        return distance(lastLatitude, lastLongitude, latitude, longitude) >= syncDistance
    }

    public static func parseRegions(_ response: [String: Any]) -> [HSGeofenceRegion] {
        guard let data = response["data"] as? [[String: Any]] else { return [] }
        let regions: [HSGeofenceRegion] = data.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let lat = (item["lat"] as? NSNumber)?.doubleValue,
                  let lng = (item["lng"] as? NSNumber)?.doubleValue,
                  let radius = (item["radius_m"] as? NSNumber)?.doubleValue, radius > 0 else { return nil }
            return HSGeofenceRegion(id: id, latitude: lat, longitude: lng, radius: radius)
        }
        return Array(regions.prefix(maxRegions))
    }

    public static func regionIdentifier(_ id: String) -> String { identifierPrefix + id }

    /// SDK'nın bölgesi değilse nil.
    public static func geofenceId(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let id = String(identifier.dropFirst(identifierPrefix.count))
        return id.isEmpty ? nil : id
    }

    public static func operation(geofenceId: String, transition: String, at: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        ["type": operationType, "geofence_id": geofenceId, "transition": transition, "at": at]
    }

    /// `POST /subscriptions/{id}/geofence-events` gövdesi; koordinat içermez. Bozuk işlemde nil (atılır).
    public static func body(for op: [String: Any], registeredToken: String?) -> [String: Any]? {
        guard let id = op["geofence_id"] as? String, let transition = op["transition"] as? String, let at = op["at"] as? TimeInterval else { return nil }
        let formatter = ISO8601DateFormatter()
        let event: [String: Any] = ["geofence_id": id, "transition": transition, "occurred_at": formatter.string(from: Date(timeIntervalSince1970: at))]
        return HSOwnership.withProof(["events": [event]], registeredToken: registeredToken)
    }
}
