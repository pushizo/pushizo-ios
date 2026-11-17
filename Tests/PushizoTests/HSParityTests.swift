import XCTest
@testable import PushizoCore

/// Web/Android ile eşitlik için eklenen API'lerin saf kuralları: kullanıcı özelliği, profille giriş, kutu gözlemcisi.
final class HSParityTests: XCTestCase {
    // MARK: User.setProperty

    func testPropertyOperationCarriesSupportedValues() throws {
        let op = try XCTUnwrap(HSUserProperties.operation(key: " first_name ", value: "Ali", at: 5))
        XCTAssertEqual(op["type"] as? String, "properties")
        XCTAssertEqual(op["at"] as? TimeInterval, 5)
        XCTAssertEqual(HSUserProperties.body(op) as? [String: String], ["first_name": "Ali"])
        XCTAssertNotNil(HSUserProperties.operation(key: "age", value: 42))
        XCTAssertNotNil(HSUserProperties.operation(key: "vip", value: true))
        XCTAssertNotNil(HSUserProperties.operation(key: "meta", value: ["a": [1, "b"]]))
    }

    func testPropertyRemovalIsStoredWithoutNullAndSentAsNull() throws {
        let op = try XCTUnwrap(HSUserProperties.operation(key: "city", value: nil))
        // UserDefaults NSNull saklayamaz: kuyruk işlemi property list olarak yazılabilmeli.
        XCTAssertTrue(PropertyListSerialization.propertyList(op, isValidFor: .binary))
        XCTAssertTrue(HSUserProperties.body(op)["city"] is NSNull)
        let viaNull = try XCTUnwrap(HSUserProperties.operation(key: "city", value: NSNull()))
        XCTAssertEqual(viaNull["remove"] as? [String], ["city"])
    }

    func testPropertyOperationRejectsInvalidInput() {
        XCTAssertNil(HSUserProperties.operation(key: "  ", value: "x"))
        XCTAssertNil(HSUserProperties.operation(key: String(repeating: "k", count: 65), value: "x"))
        XCTAssertNil(HSUserProperties.operation(key: "when", value: Date()))
        XCTAssertNil(HSUserProperties.operation(key: "list", value: ["ok", NSNull()] as [Any]))
    }

    func testQueuedPropertyOperationSurvivesUserDefaults() throws {
        let suite = "hs.parity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = HSQueue(defaults: defaults, appId: "app")
        queue.enqueue(try XCTUnwrap(HSUserProperties.operation(key: "city", value: nil)))
        queue.enqueue(try XCTUnwrap(HSUserProperties.operation(key: "plan", value: "pro")))
        XCTAssertEqual(queue.count, 2)
        XCTAssertTrue(HSUserProperties.body(queue.items[0])["city"] is NSNull)
        XCTAssertEqual(HSUserProperties.body(queue.items[1])["plan"] as? String, "pro")
    }

    // MARK: Profille giriş

    func testProfileValidationRejectsBadContactsAndAliases() {
        XCTAssertNil(HSUserProfile().validationError)
        XCTAssertNil(HSUserProfile(email: "Ali@Ornek.com", sms: "+90 (532) 123-45-67", tags: ["plan": "pro"], aliases: ["crm_id": "42"]).validationError)
        XCTAssertNotNil(HSUserProfile(email: "ali@").validationError)
        XCTAssertNotNil(HSUserProfile(sms: "12345").validationError)
        XCTAssertNotNil(HSUserProfile(aliases: ["external_id": "x"]).validationError)
    }

    func testProfileOperationsAreNormalizedAndOrdered() {
        let ops = HSUserProfile(email: " Ali@Ornek.com ", sms: "00905321234567", tags: ["plan": "pro"], aliases: ["crm_id": " 42 "]).operations(at: 9)
        XCTAssertEqual(ops.map { $0["type"] as? String }, ["contact_add", "contact_add", "tags", "alias_add"])
        XCTAssertEqual(ops[0]["address"] as? String, "ali@ornek.com")
        XCTAssertEqual(ops[0]["channel"] as? String, "email")
        XCTAssertEqual(ops[1]["address"] as? String, "+905321234567")
        XCTAssertEqual(ops[2]["tags"] as? [String: String], ["plan": "pro"])
        XCTAssertEqual(ops[3]["aliases"] as? [String: String], ["crm_id": "42"])
        XCTAssertTrue(ops.allSatisfy { $0["at"] as? TimeInterval == 9 })
    }

    func testInvalidProfileProducesNoOperations() {
        XCTAssertTrue(HSUserProfile(email: "x", tags: ["a": "b"]).operations().isEmpty)
        XCTAssertTrue(HSUserProfile().operations().isEmpty)
    }

    // MARK: Inbox gözlemcisi

    private func item(_ id: String, read: Bool) -> HSInboxItem {
        HSInboxItem(id: id, messageId: nil, title: nil, body: nil, url: nil, imageUrl: nil, data: [:], read: read, readAt: nil, archivedAt: nil, expiresAt: nil, createdAt: nil)
    }

    private func page(_ items: [HSInboxItem], unread: Int) -> HSInboxPage {
        HSInboxPage(items: items, unreadCount: unread, nextCursor: nil, hasMore: false)
    }

    func testListedAndCountNotifyOnlyWhenUnreadChanges() {
        let tracker = HSInboxTracker()
        let first = page([item("a", read: false), item("b", read: true)], unread: 1)
        XCTAssertEqual(tracker.listed(first, firstPage: true), HSInboxChangeEvent(type: .listed, unreadCount: 1))
        XCTAssertNil(tracker.listed(first, firstPage: true), "sayı değişmediyse olay yok")
        XCTAssertNil(tracker.counted(1))
        XCTAssertEqual(tracker.counted(3), HSInboxChangeEvent(type: .count, unreadCount: 3))
        XCTAssertEqual(tracker.lastUnreadCount, 3)
    }

    func testReadUsesLocalCountForKnownUnreadItem() {
        let tracker = HSInboxTracker()
        XCTAssertNil(tracker.countAfterRead("a"), "sayı bilinmeden yerel hesap yapılmaz")
        _ = tracker.listed(page([item("a", read: false), item("b", read: true)], unread: 1), firstPage: true)
        XCTAssertEqual(tracker.countAfterRead("a"), 0)
        XCTAssertNil(tracker.countAfterRead("b"), "zaten okunmuş öğede sunucu sayısı kullanılır")
        XCTAssertNil(tracker.countAfterRead("zz"))
        XCTAssertEqual(tracker.read("a", unreadCount: 0), HSInboxChangeEvent(type: .read, itemId: "a", unreadCount: 0))
        // Öğe değişimi sayı aynı kalsa da bildirilir.
        XCTAssertEqual(tracker.read("b", unreadCount: 0), HSInboxChangeEvent(type: .read, itemId: "b", unreadCount: 0))
    }

    func testReadAllAndArchive() {
        let tracker = HSInboxTracker()
        _ = tracker.listed(page([item("a", read: false), item("b", read: false), item("c", read: true)], unread: 2), firstPage: true)
        XCTAssertEqual(tracker.countAfterArchive("a"), 1)
        XCTAssertEqual(tracker.countAfterArchive("c"), 2)
        XCTAssertNil(tracker.countAfterArchive("zz"))
        XCTAssertEqual(tracker.archived("a", unreadCount: 1), HSInboxChangeEvent(type: .archived, itemId: "a", unreadCount: 1))
        XCTAssertNil(tracker.countAfterArchive("a"), "arşivlenen öğe artık bilinmez")
        XCTAssertEqual(tracker.readAll(unreadCount: 0), HSInboxChangeEvent(type: .readAll, unreadCount: 0))
        XCTAssertEqual(tracker.countAfterArchive("b"), 0, "tümü okundu sonrası öğe okunmuş sayılır")
    }

    func testSecondPageKeepsKnownItemsAndResetClears() {
        let tracker = HSInboxTracker()
        _ = tracker.listed(page([item("a", read: false)], unread: 2), firstPage: true)
        _ = tracker.listed(page([item("b", read: false)], unread: 2), firstPage: false)
        XCTAssertEqual(tracker.countAfterRead("a"), 1)
        XCTAssertEqual(tracker.countAfterRead("b"), 1)
        _ = tracker.listed(page([item("b", read: false)], unread: 2), firstPage: true)
        XCTAssertNil(tracker.countAfterRead("a"), "ilk sayfa önbelleği yeniler")
        tracker.reset()
        XCTAssertNil(tracker.lastUnreadCount)
        XCTAssertNil(tracker.countAfterRead("b"))
    }

    func testChangeEventDictionaryUsesWireNames() {
        let event = HSInboxChangeEvent(type: .readAll, unreadCount: 0)
        XCTAssertEqual(event.dictionary["type"] as? String, "read_all")
        XCTAssertNil(event.dictionary["itemId"])
        XCTAssertEqual(HSInboxChangeEvent(type: .read, itemId: "a", unreadCount: 2).dictionary["itemId"] as? String, "a")
    }

    // MARK: Özellik bayrağı gözlemcisi (belirteçli kayıt)

    func testVoidRegistryBacksFeatureFlagObservers() {
        let registry = HSListenerRegistry<Void>()
        var calls = 0
        let token = registry.add { _ in calls += 1 }
        registry.notify(())
        XCTAssertTrue(registry.remove(token))
        registry.notify(())
        XCTAssertEqual(calls, 1)
    }

    // MARK: Session.sendEvent eventId

    func testEventIdAcceptsAppProvidedIdsInTheSharedFormat() {
        for ok in ["order-1234", "a1b2c3d4", "ord:2026.11_17-x", String(repeating: "a", count: 64)] {
            XCTAssertEqual(HSEventId.valid(ok), ok)
            XCTAssertEqual(HSEventId.resolve(ok), ok)
        }
    }

    func testInvalidEventIdFallsBackToGeneratedId() {
        for bad in [nil, "", "short", "has space1", "türkçe-kimlik", "a/b/c/d/e/f", String(repeating: "a", count: 65), "abcdefgh\n"] {
            XCTAssertNil(HSEventId.valid(bad))
            let generated = HSEventId.resolve(bad)
            XCTAssertNotNil(HSEventId.valid(generated), "üretilen kimlik de aynı kurala uyar")
            XCTAssertEqual(generated, generated.lowercased())
        }
        XCTAssertNotEqual(HSEventId.resolve(nil), HSEventId.resolve(nil))
    }

    func testEventItemCarriesQueuedEventId() {
        let op: [String: Any] = ["type": "event", "name": "purchase", "properties": [String: Any](), "occurred_at": "2026-11-17T10:00:00Z", "event_id": HSEventId.resolve("order-1234")]
        let items = HSOwnership.eventItems([op], subscriptionId: "sub_1", registeredToken: nil, identityHash: nil)
        XCTAssertEqual(items.first?["event_id"] as? String, "order-1234")
    }

    // MARK: Bildirim tanımlayıcısı

    func testNotificationCarriesRequestIdentifier() throws {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": ["title": "Merhaba"]], "hs": ["dlv": "d1"]]
        XCTAssertNil(try XCTUnwrap(HSNotification(userInfo: userInfo)).identifier)
        XCTAssertNil(try XCTUnwrap(HSNotification(userInfo: userInfo, identifier: "")).identifier)
        XCTAssertEqual(try XCTUnwrap(HSNotification(userInfo: userInfo, identifier: "req-1")).identifier, "req-1")
    }
}
