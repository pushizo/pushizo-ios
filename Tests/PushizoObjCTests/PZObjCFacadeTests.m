@import XCTest;
@import Pushizo;

/// In-app yaşam döngüsü dinleyicisi: yalnızca iki isteğe bağlı metodu uygular.
@interface PZTestLifecycleListener : NSObject <PZInAppLifecycleListener>
@property (nonatomic) NSInteger calls;
@end

@implementation PZTestLifecycleListener
- (void)onDidDisplay:(PZInAppMessage *)message { self.calls++; }
- (void)onDidDismiss:(PZInAppMessage *)message { self.calls++; }
@end

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

- (void)testEsitlikEklemeleriBaslatilmadanGuvenli {
    // Kullanıcı özelliği ve gözlemciler SDK başlatılmadan çökmez; belirteçler birden çok kez kaldırılabilir.
    [PZUser setProperty:@"first_name" value:@"Ali"];
    [PZUser setProperty:@"first_name" value:nil];
    __block NSInteger calls = 0;
    PZListenerToken *flags = [PZFeatureFlags addObserver:^{ calls++; }];
    PZListenerToken *inbox = [PZInbox addObserver:^(PZInboxChangeEvent *event) { calls++; }];
    [flags remove];
    [flags remove];
    [inbox remove];
    XCTAssertEqual(calls, 0);
    XCTAssertFalse(PZChat.isPresented);
    XCTAssertEqual(PZChat.unreadCount, 0);
    [PZChat hideAnimated:NO];
    // İzin durumu istem göstermeden okunur; arka plan izni ön plan izni olmadan verilemez.
    XCTAssertTrue(PZLocation.permissionGranted || !PZLocation.backgroundPermissionGranted);
}

- (void)testProfilleGirisGecersizProfildeVeBaslatilmadanHataDondurur {
    PZUserProfile *profile = [[PZUserProfile alloc] init];
    profile.email = @"ali@ornek.com";
    profile.tags = @{ @"plan": @"pro" };
    NSError *error = nil;
    BOOL ok = [PZPushizo loginWithExternalId:@"user_42" profile:profile identityHash:nil jwt:nil error:&error];
    XCTAssertFalse(ok);
    XCTAssertEqualObjects(error.domain, PZErrors.domain);
    XCTAssertEqual(error.code, PZErrorCodeNotInitialized);
}

/// Görünüm ağacında koşulu sağlayan ilk öğe (derinlik öncelikli).
static UIView *PZFindView(UIView *root, BOOL (^match)(UIView *view)) {
    if (match(root)) return root;
    for (UIView *child in root.subviews) {
        UIView *found = PZFindView(child, match);
        if (found) return found;
    }
    return nil;
}

- (void)testSohbetEkraniBaslatilmadanHataDurumunuGosterir {
    PZChatViewController *chat = [[PZChatViewController alloc] init];
    XCTAssertTrue(chat.showsCloseButton);
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    window.rootViewController = chat;
    window.hidden = NO;
    [chat.view layoutIfNeeded];

    // Kapat düğmesi erişilebilirlik etiketlidir ve en az 44 pt dokunma alanına sahiptir.
    UIView *close = PZFindView(chat.view, ^BOOL(UIView *view) {
        return [view isKindOfClass:UIButton.class] && !view.hidden && view.accessibilityLabel.length > 0 && CGRectGetMinY([view convertRect:view.bounds toView:nil]) < 120;
    });
    XCTAssertNotNil(close);
    XCTAssertGreaterThanOrEqual(CGRectGetWidth(close.bounds), 44);
    XCTAssertGreaterThanOrEqual(CGRectGetHeight(close.bounds), 44);
    chat.showsCloseButton = NO;
    XCTAssertTrue(close.hidden);

    // SDK başlatılmadığı için yükleme başarısız olur: gösterge durur, hata metni ve yeniden dene düğmesi görünür.
    XCTestExpectation *failed = [self expectationWithDescription:@"hata durumu"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [failed fulfill]; });
    [self waitForExpectations:@[failed] timeout:5];
    UIActivityIndicatorView *spinner = (UIActivityIndicatorView *)PZFindView(chat.view, ^BOOL(UIView *view) { return [view isKindOfClass:UIActivityIndicatorView.class]; });
    XCTAssertNotNil(spinner);
    XCTAssertFalse(spinner.isAnimating);
    UIView *retry = PZFindView(chat.view, ^BOOL(UIView *view) {
        return [view isKindOfClass:UIButton.class] && !view.hidden && [(UIButton *)view titleForState:UIControlStateNormal].length > 0 && view.superview == spinner.superview;
    });
    XCTAssertNotNil(retry);
    // Mesaj alanı hata durumunda gizlidir.
    UIView *input = PZFindView(chat.view, ^BOOL(UIView *view) { return [view isKindOfClass:UITextView.class]; });
    XCTAssertNotNil(input);
    BOOL hidden = NO;
    for (UIView *v = input; v != nil && v != chat.view; v = v.superview) hidden = hidden || v.hidden;
    XCTAssertTrue(hidden);
    window.hidden = YES;
}

- (void)testSohbetCephesiBaslatilmadanDurumVeDinleyiciler {
    XCTAssertNil(PZChat.visitorId);
    XCTAssertEqual(PZChat.unreadCount, 0);
    XCTAssertFalse(PZChat.isListening);
    XCTAssertFalse(PZChat.isPresented);
    __block NSInteger calls = 0;
    PZListenerToken *events = [PZChat addListener:^(PZChatEvent *event) { calls++; }];
    PZListenerToken *opens = [PZChat addOpenListener:^(PZChatPushInfo *info) { calls++; }];
    [PZChat removeListener:events];
    [PZChat removeOpenListener:opens];
    [events remove];
    [PZChat setTyping:YES];
    [PZChat startListening];
    [PZChat stopListening];
    [PZChat hide];
    XCTAssertFalse(PZChat.isListening);
    XCTAssertEqual(calls, 0);

    NSError *error = nil;
    NSURL *url = [PZChat attachmentUrl:@"att_1" download:NO error:&error];
    XCTAssertNil(url);
    XCTAssertEqualObjects(error.domain, PZErrors.domain);
    XCTAssertEqual(error.code, PZErrorCodeNotInitialized);
}

- (void)testSohbetCagrilariBaslatilmadanHatayiAnaIsParcacigindaDondurur {
    NSMutableArray<XCTestExpectation *> *pending = [NSMutableArray array];
    XCTestExpectation *(^expect)(NSString *) = ^XCTestExpectation *(NSString *name) {
        XCTestExpectation *e = [self expectationWithDescription:name];
        [pending addObject:e];
        return e;
    };
    void (^check)(id, NSError *, XCTestExpectation *) = ^(id value, NSError *error, XCTestExpectation *done) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertNil(value);
        XCTAssertEqualObjects(error.domain, PZErrors.domain);
        XCTAssertEqual(error.code, PZErrorCodeNotInitialized);
        [done fulfill];
    };
    XCTestExpectation *start = expect(@"start");
    [PZChat startWithName:@"Ali" email:nil language:nil completion:^(PZChatIdentifyResult *r, NSError *e) { check(r, e, start); }];
    XCTestExpectation *identify = expect(@"identify");
    [PZChat identifyWithName:nil email:@"ali@ornek.com" language:@"tr" completion:^(PZChatIdentifyResult *r, NSError *e) { check(r, e, identify); }];
    XCTestExpectation *config = expect(@"config");
    [PZChat getConfigWithLanguage:nil completion:^(PZChatConfig *r, NSError *e) { check(r, e, config); }];
    XCTestExpectation *conversation = expect(@"conversation");
    [PZChat getConversationWithCompletion:^(PZChatConversationState *r, NSError *e) { check(r, e, conversation); }];
    XCTestExpectation *messages = expect(@"messages");
    [PZChat getMessagesAfterSeq:nil beforeSeq:@10 limit:20 completion:^(PZChatMessagePage *r, NSError *e) { check(r, e, messages); }];
    XCTestExpectation *unread = expect(@"unread");
    [PZChat refreshUnreadCountWithCompletion:^(NSNumber *r, NSError *e) { check(r, e, unread); }];
    XCTestExpectation *send = expect(@"send");
    [PZChat sendMessage:@"Merhaba" optionId:nil completion:^(PZChatMessage *r, NSError *e) { check(r, e, send); }];
    XCTestExpectation *offline = expect(@"offline");
    [PZChat leaveOfflineMessageWithEmail:@"ali@ornek.com" text:@"Beni arayın" name:nil completion:^(PZChatMessage *r, NSError *e) { check(r, e, offline); }];
    XCTestExpectation *read = expect(@"read");
    [PZChat markRead:3 completion:^(NSNumber *r, NSError *e) { check(r, e, read); }];
    XCTestExpectation *data = expect(@"attachment");
    [PZChat sendAttachmentData:[@"merhaba" dataUsingEncoding:NSUTF8StringEncoding] fileName:@"not.txt" mimeType:@"text/plain" text:nil
                    completion:^(PZChatMessage *r, NSError *e) { check(r, e, data); }];
    [self waitForExpectations:pending timeout:5];
}

- (void)testSohbetGecersizGirdiInvalidArgumentDondurur {
    XCTestExpectation *empty = [self expectationWithDescription:@"boş metin"];
    [PZChat sendMessage:@"   " optionId:nil completion:^(PZChatMessage *message, NSError *error) {
        XCTAssertNil(message);
        XCTAssertEqualObjects(error.domain, PZErrors.domain);
        XCTAssertEqual(error.code, PZErrorCodeInvalidArgument);
        [empty fulfill];
    }];
    XCTestExpectation *type = [self expectationWithDescription:@"ek türü"];
    [PZChat sendAttachmentData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] fileName:@"a.zip" mimeType:@"application/zip" text:nil
                    completion:^(PZChatMessage *message, NSError *error) {
        XCTAssertEqual(error.code, PZErrorCodeInvalidArgument);
        [type fulfill];
    }];
    XCTestExpectation *file = [self expectationWithDescription:@"eksik dosya"];
    NSURL *missing = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"pushizo-yok.png"]];
    [PZChat sendAttachmentFileURL:missing mimeType:@"image/png" text:nil completion:^(PZChatMessage *message, NSError *error) {
        XCTAssertNil(message);
        XCTAssertNotNil(error);
        [file fulfill];
    }];
    [self waitForExpectations:@[empty, type, file] timeout:5];
}

- (void)testLiveActivitiesBaslatilmadanNotInitializedVeHataKodu {
    XCTAssertGreaterThan(PZLiveActivities.defaultActivityType.length, 0u);
    NSError *error = nil;
    XCTAssertFalse([PZLiveActivities setupDefaultLiveActivityAndReturnError:&error]);
    XCTAssertEqualObjects(error.domain, PZErrors.domain);
    XCTAssertEqual(error.code, PZErrorCodeNotInitialized);
    XCTAssertEqualObjects(error.userInfo[PZErrors.codeKey], @"NOT_READY");
    error = nil;
    BOOL ok = [PZLiveActivities startDefaultLiveActivityWithActivityId:@"order-1" attributes:@{ @"title": @"Sipariş" }
                                                          contentState:@{ @"step": @2 } error:&error];
    XCTAssertFalse(ok);
    XCTAssertEqual(error.code, PZErrorCodeNotInitialized);
}

- (void)testReklamKimligiYasamDongusuVeOlayKimligiBaslatilmadanGuvenli {
    [PZAds setAdvertisingId:@"00000000-0000-0000-0000-000000000000"];
    [PZAds setAdvertisingId:nil];
    [PZSession sendEvent:@"purchase" properties:@{ @"sku": @"a1" } value:@49.9 eventId:@"order-1234"];
    [PZSession sendEvent:@"purchase" properties:nil value:nil eventId:nil];

    PZTestLifecycleListener *listener = [[PZTestLifecycleListener alloc] init];
    PZListenerToken *first = [PZInAppMessages addLifecycleListener:listener];
    PZListenerToken *second = [PZInAppMessages addLifecycleListener:listener];
    [PZInAppMessages removeLifecycleListener:listener];
    [first remove];
    [second remove];
    XCTAssertEqual(listener.calls, 0);

    PZListenerToken *flags = [PZFeatureFlags addObserver:^{ }];
    [PZFeatureFlags removeObserver:flags];
    PZListenerToken *inbox = [PZInbox addObserver:^(PZInboxChangeEvent *event) { }];
    [PZInbox removeObserver:inbox];
    [inbox remove];
}

@end
