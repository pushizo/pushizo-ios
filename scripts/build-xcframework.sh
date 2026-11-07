#!/usr/bin/env bash
# Pushizo.xcframework üretir (iOS cihaz + iOS simülatör + Mac Catalyst), zip'ler ve SPM binary target sağlama toplamını
# yazar (plan 13 Faz 29). macOS + Xcode 15+ gerekir.
#
#   sdk/ios/scripts/build-xcframework.sh [çıktı klasörü]     (varsayılan: sdk/ios/build/xcframework)
#
# Çıktılar: Pushizo.xcframework, Pushizo.xcframework.zip, Pushizo.xcframework.zip.sha256 (`swift package compute-checksum`).
# Çekirdek ve uygulama kaynakları CocoaPods'taki gibi tek "Pushizo" modülünde derlenir; böylece hem Swift (`import Pushizo`)
# hem Objective-C (`@import Pushizo;`, PZ önekli cephe) aynı framework'ü kullanır. sdk/ios altına derleme çıktısı yazılmaz
# (çıktı klasörü verilmezse `build/`, .gitignore'dadır).
set -euo pipefail

IOS="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$IOS/build/xcframework}"
NAME="Pushizo"
STAGE="$OUT/package"
DERIVED="$OUT/DerivedData"
XCFRAMEWORK="$OUT/$NAME.xcframework"
ZIP="$XCFRAMEWORK.zip"

rm -rf "$STAGE" "$XCFRAMEWORK" "$ZIP" "$ZIP.sha256" "$OUT"/*.xcarchive
mkdir -p "$STAGE/Sources/$NAME"

# Tek modüllü derleme paketi: kaynaklar kopyalanır (ana paket iki modüllüdür; `#if canImport(PushizoCore)` korumaları
# tek modülde de derlenir).
cp -R "$IOS/Sources/PushizoCore" "$STAGE/Sources/$NAME/Core"
cp -R "$IOS/Sources/Pushizo" "$STAGE/Sources/$NAME/App"
cat > "$STAGE/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
// build-xcframework.sh tarafından üretilir; elle düzenlemeyin.
import PackageDescription

let package = Package(
    name: "Pushizo",
    platforms: [.iOS(.v15), .macCatalyst(.v15)],
    products: [.library(name: "Pushizo", type: .dynamic, targets: ["Pushizo"])],
    targets: [
        .target(
            name: "Pushizo",
            path: "Sources/Pushizo",
            // Live Activities (iOS 16.1+): iOS 15'te yüklenebilmesi için zayıf bağlanır (podspec ile aynı).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "ActivityKit"])]
        ),
    ]
)
SWIFT

# Modül adı ("Pushizo") içindeki `Pushizo` tipiyle çakışır; arayüzdeki modül nitelemeleri takma adla yazılır ki
# Swift tüketicileri swiftinterface'i doğru çözsün (doğrulama açık kalır).
archive() {
  local destination="$1" name="$2"
  (cd "$STAGE" && xcodebuild archive \
    -scheme "$NAME" \
    -destination "$destination" \
    -archivePath "$OUT/$name.xcarchive" \
    -derivedDataPath "$DERIVED" \
    -quiet \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -alias-module-names-in-module-interface')
}

# SPM dinamik ürün arşivi framework'e Swift modülünü ve Objective-C başlığını koymaz; derleme ara çıktılarından eklenir.
complete_framework() {
  local archive="$1" platform_dir="$2" framework products
  framework="$(find "$archive/Products" -type d -name "$NAME.framework" -print -quit)"
  if [[ -z "$framework" ]]; then
    echo "Pushizo: $archive içinde $NAME.framework bulunamadı" >&2
    exit 1
  fi
  products="$(find "$DERIVED/Build/Intermediates.noindex/ArchiveIntermediates/$NAME/BuildProductsPath" -maxdepth 1 -type d -name "Release-$platform_dir" -print -quit)"
  local module header
  module="$products/$NAME.swiftmodule"
  # Tüm mimarileri kapsayan birleşik başlık GeneratedModuleMaps altındadır.
  header="$DERIVED/Build/Intermediates.noindex/ArchiveIntermediates/$NAME/IntermediateBuildFilesPath/GeneratedModuleMaps-$platform_dir/$NAME-Swift.h"
  [[ -f "$header" ]] || header=""
  if [[ ! -d "$module" || -z "$header" ]]; then
    echo "Pushizo: $platform_dir için Swift modülü veya $NAME-Swift.h bulunamadı" >&2
    exit 1
  fi
  local root="$framework"
  # Mac Catalyst framework'leri sürümlü yapıdadır (Versions/A).
  [[ -d "$framework/Versions/A" ]] && root="$framework/Versions/A"
  mkdir -p "$root/Modules" "$root/Headers"
  cp -R "$module" "$root/Modules/"
  # Derleyiciye özel, kararlı olmayan ikili modül dağıtılmaz; tüketiciler swiftinterface'ten derler.
  find "$root/Modules/$NAME.swiftmodule" -name "*.swiftmodule" -type f -delete
  find "$root/Modules/$NAME.swiftmodule" -name "*.private.swiftinterface" -type f -delete
  cp "$header" "$root/Headers/$NAME-Swift.h"
  cat > "$root/Modules/module.modulemap" <<MAP
framework module $NAME {
  header "$NAME-Swift.h"
  requires objc
}
MAP
  if [[ "$root" != "$framework" ]]; then
    ln -sfn Versions/Current/Modules "$framework/Modules"
    ln -sfn Versions/Current/Headers "$framework/Headers"
  fi
  echo "$framework"
}

# Ara çıktılar her arşivde üzerine yazıldığından framework arşivden hemen sonra tamamlanır.
FRAMEWORKS=()
for spec in "generic/platform=iOS|ios|iphoneos" \
            "generic/platform=iOS Simulator|ios-simulator|iphonesimulator" \
            "generic/platform=macOS,variant=Mac Catalyst|maccatalyst|maccatalyst"; do
  IFS='|' read -r destination name platform_dir <<<"$spec"
  archive "$destination" "$name"
  FRAMEWORKS+=(-framework "$(complete_framework "$OUT/$name.xcarchive" "$platform_dir")")
done

xcodebuild -create-xcframework "${FRAMEWORKS[@]}" -output "$XCFRAMEWORK"

(cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$NAME.xcframework" "$NAME.xcframework.zip")
(cd "$STAGE" && swift package compute-checksum "$ZIP") > "$ZIP.sha256"

echo "Pushizo: $XCFRAMEWORK"
echo "Pushizo: $ZIP (sha256 $(cat "$ZIP.sha256"))"
