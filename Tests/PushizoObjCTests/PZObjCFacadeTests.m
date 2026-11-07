@import XCTest;
@import Pushizo;

/// Objective-C cephesi (plan 13 Faz 29): yüzey yalnızca `@import Pushizo;` ile kullanılır. Testler SDK başlatılmadan
/// çalışır; ağ çağrısı yapılmaz. Completion block'larının ana iş parçacığında döndüğü de sınanır.
@interface PZObjCFacadeTests : XCTestCase
@end

@implementation PZObjCFacadeTests

- (void)testSurumVeBaslatmaDurumu {
    XCTAssertEqualObjects(PZPushizo.sdkVersion, @"0.2.0");
    XCTAssertFalse(PZPushizo.isInitialized);
    XCTAssertEqualObjects(PZErrors.domain, @"PZErrorDomain");
}

- (void)testSecenekVarsayilanlari {
    PZOptions *options = [[PZOptions alloc] init];
    XCTAssertNil(options.apiUrl);
    XCTAssertFalse(options.requiresPrivacyConsent);
    XCTAssertFalse(options.provisionalAuthorization);
    XCTAssertTrue(options.installsNotificationDelegate);
    XCTAssertEqual(options.logLevel, PZLogLevelWarn);
    options.logLevel = PZLogLevelDebug;
    options.appGroup = @"group.com.ornek.app";
    XCTAssertEqual(options.logLevel, PZLogLevelDebug);
    XCTAssertEqualObjects(options.appGroup, @"group.com.ornek.app");
}

- (void)testBaslatilmadanJwtGuncellemesiHataDondurur {
    NSError *error = nil;
    BOOL ok = [PZPushizo updateUserJwt:@"jwt" error:&error];
    XCTAssertFalse(ok);
    XCTAssertEqualObjects(error.domain, PZErrors.domain);
    XCTAssertEqual(error.code, PZErrorCodeNotInitialized);
}

- (void)testGelenKutusuBaslatilmadanNotInitializedDondururAnaIsParcaciginda {
    XCTestExpectation *done = [self expectationWithDescription:@"inbox"];
    [PZInbox listWithLimit:20 cursor:nil completion:^(PZInboxPage *page, NSError *error) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertNil(page);
        XCTAssertEqualObjects(error.domain, PZErrors.domain);
        XCTAssertEqual(error.code, PZErrorCodeNotInitialized);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:5];
}

- (void)testTercihlerBaslatilmadanHataDondurur {
    XCTestExpectation *done = [self expectationWithDescription:@"preferences"];
    [PZUser getPreferencesWithCompletion:^(PZPreferencesResult *result, NSError *error) {
        XCTAssertNil(result);
        XCTAssertEqualObjects(error.domain, PZErrors.domain);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:5];
}

- (void)testTercihGirdisi {
    PZPreferenceInput *all = [[PZPreferenceInput alloc] initWithCategory:@"promo" channel:nil optedIn:NO];
    XCTAssertEqualObjects(all.category, @"promo");
    XCTAssertNil(all.channel);
    XCTAssertFalse(all.optedIn);
    PZPreferenceInput *email = [[PZPreferenceInput alloc] initWithCategory:@"promo" channel:@"email" optedIn:YES];
    XCTAssertEqualObjects(email.channel, @"email");
    XCTAssertTrue(email.optedIn);
}

- (void)testYerlesimAnahtarVeLimitDogrulamasi {
    XCTestExpectation *badKey = [self expectationWithDescription:@"anahtar"];
    [PZPlacements listWithKey:@"Ana Sayfa" limit:1 completion:^(NSArray<PZInAppMessage *> *messages, NSError *error) {
        XCTAssertNil(messages);
        XCTAssertEqual(error.code, PZErrorCodeInvalidArgument);
        [badKey fulfill];
    }];
    XCTestExpectation *badLimit = [self expectationWithDescription:@"limit"];
    [PZPlacements listWithKey:@"home.hero" limit:11 completion:^(NSArray<PZInAppMessage *> *messages, NSError *error) {
        XCTAssertEqual(error.code, PZErrorCodeInvalidArgument);
        [badLimit fulfill];
    }];
    // Geçerli girdi: SDK başlatılmadığı için içerik yok, boş dizi döner.
    XCTestExpectation *empty = [self expectationWithDescription:@"boş"];
    [PZPlacements listWithKey:@"home.hero" limit:3 completion:^(NSArray<PZInAppMessage *> *messages, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(messages.count, 0u);
        [empty fulfill];
    }];
    [self waitForExpectations:@[badKey, badLimit, empty] timeout:5];
}

- (void)testOzellikBayraklariVarsayilanlari {
    XCTAssertFalse([PZFeatureFlags isEnabled:@"yeni_sepet" defaultValue:NO]);
    XCTAssertTrue([PZFeatureFlags isEnabled:@"yeni_sepet" defaultValue:YES]);
    XCTAssertEqualObjects([PZFeatureFlags valueForKey:@"limit" defaultValue:@3], @3);
    XCTAssertNil([PZFeatureFlags valueForKey:@"limit" defaultValue:nil]);
    XCTestExpectation *done = [self expectationWithDescription:@"refresh"];
    [PZFeatureFlags refreshWithCompletion:^(BOOL ok) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertFalse(ok);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:5];
}

- (void)testBolgeIzlemeVarsayilanKapaliVeBaslatilmadanDegismez {
    XCTAssertFalse(PZLocation.isGeofencingEnabled);
    [PZLocation setGeofencingEnabled:YES];
    XCTAssertFalse(PZLocation.isGeofencingEnabled);
    XCTAssertFalse(PZLocation.isShared);
}

- (void)testKullaniciBaslatilmadanBosDegerler {
    XCTAssertNil(PZUser.externalId);
    XCTAssertNil(PZUser.userId);
    XCTAssertEqual(PZUser.getTags.count, 0u);
    XCTAssertEqual(PZUser.emails.count, 0u);
    XCTAssertNil(PZPushSubscription.subscriptionId);
    XCTAssertFalse(PZPushSubscription.optedIn);
}

- (void)testDinleyiciBelireciBirdenCokKaldirilabilir {
    __block NSInteger calls = 0;
    PZListenerToken *token = [PZNotifications addPermissionObserver:^(BOOL granted) { calls++; }];
    [token remove];
    [token remove];
    PZListenerToken *click = [PZNotifications addClickListener:^(PZClickEvent *event) { calls++; }];
    PZListenerToken *inApp = [PZInAppMessages addClickListener:^(PZInAppClickEvent *event) { calls++; }];
    PZListenerToken *subscription = [PZPushSubscription addObserver:^(PZPushSubscriptionState *state) { calls++; }];
    [click remove];
    [inApp remove];
    [subscription remove];
    XCTAssertEqual(calls, 0);
}

- (void)testOlayGonderimiBaslatilmadanCokmez {
    [PZSession sendEvent:@"purchase" properties:@{ @"sku": @"a1" } value:@49.9];
    [PZSession sendEvent:@"view" properties:nil value:nil];
    [PZPushizo setLogLevel:PZLogLevelWarn];
}

@end
