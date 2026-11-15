# 03. `mo uninstall` / `mo purge` / `mo installer` / `mo slim` 포팅 스펙

> 원본: Mole (GPL-3.0), 읽기 전용 분석. 경로 기준 `REPO=src/Mole`. `file:line`은 분석 시점 기준(±수 줄 오차 가능).
> 공통 삭제 깔때기(`safe_remove`, `mole_delete`, `remove_file_list`의 내부 sink, identity 핀닝, Trash/permanent 모드)는 **lib/core/file_ops.sh 담당 문서**를 참조한다. 여기서는 호출 지점과 인자만 적는다.
> 공통 전제: 4개 명령 모두 `EUID==0`이면 즉시 거부 (`bin/uninstall.sh:10-13`, `bin/installer.sh:7-10`, `bin/slim.sh` 상단). 필요한 권한만 개별 단계에서 요청.

---

## 0. 요약 비교표

| 항목 | uninstall | purge | installer | slim |
|---|---|---|---|---|
| 대상 | `.app` 번들 + 잔여물 | 프로젝트 빌드 산출물 디렉터리 | 설치 파일(.dmg/.pkg/...) | 유니버설 앱의 Intel 슬라이스 |
| 기본 삭제 모드 | **Trash** (`MOLE_DELETE_MODE=trash`, `--permanent`로 변경) `bin/uninstall.sh:2027` | permanent (`safe_remove`) `lib/clean/project.sh:3291` | permanent (`mole_delete` 기본) `bin/installer.sh:775` | 원본은 Trash, 사본으로 교체 `bin/slim.sh:~688` |
| 플래그 | `--dry-run/-n`, `--permanent`, `--with-data`, `--list`, `--debug`, `-h`, 인자=앱 이름 | `--paths`, `--dry-run/-n`, `--include-empty`, `--yes`, `--debug`, `-h` | `--dry-run/-n`, `--debug`, `-h` | `--dry-run/-n`, `--debug`, `-h` |
| 관리자 권한 | 조건부(앱 부모 비쓰기/permanent+타 소유자/brew cask) | 없음 | 없음 | **절대 없음** |
| 비TTY 동작 | 실제 실행 거부(exit 1), dry-run은 계획 출력 후 0 | `--yes` 없으면 거부, dry-run 허용 | 메뉴 read 실패=취소 | 목록만 출력 |
| 캐시 | `~/.cache/mole/uninstall_app_metadata_v5` (7일 TTL), `pkg_receipt_apps_v1` | `~/.config/mole/purge_paths` (탐색 결과 저장) | 없음 | 없음 |

---

## 1. `mo uninstall`

### 1.1 흐름

| 단계 | 내용 | 위치 |
|---|---|---|
| 플래그 파싱 | `--help`, `--debug`(MO_DEBUG=1), `--dry-run/-n`(MOLE_DRY_RUN=1), `--permanent`(MOLE_DELETE_MODE=permanent), `--with-data`, `--list`, `--whitelist`는 명시적 에러, 그 외 `-*` 에러, 나머지는 앱 이름 인자 | `bin/uninstall.sh:2020-2072` |
| `--list` | 파괴적 코드 이전에 단락. 스캔→표 또는 JSON 출력(stdout 비TTY면 자동 JSON). 필드: `name,bundle_id,source,uninstall_name(cask 토큰 or 이름),path,size` | `bin/uninstall.sh:1870-2018`, 단락 `:2076-2079` |
| 발견 | `scan_applications` (아래 1.2) | `:1432-1624` |
| 선택(인터랙티브) | 대체 화면(alt screen)에서 스캔+셀렉터. 셀렉터 직전 `drain_pending_input`로 미리 친 Enter 제거(#726) | `:2160-2240` |
| 선택(이름 인자) | `match_apps_by_name`: 소문자 부분일치(표시명+번들 디렉터리명). 여러 단어가 공백 결합으로 정확히 한 앱 이름이면 그 앱(`mo uninstall Tor Browser`), 단 각 단어가 각각 정확한 앱이면 원래 의미 유지 (#1365). 별도 y/N 없이 배치 미리보기가 유일한 확인 | `:1707-1855`, `:2088-2128` |
| 검토(미리보기) | `batch_uninstall_applications` → `_batch_scan_app_details`(크기·잔여물 탐색) → `_batch_preview_and_confirm`: 앱별 `✓ 번들`, `✓ 자동 삭제(캐시/로그)`, `⚠ Review only:`(시스템 경로), 개인 데이터 목록, `D`로 개인 데이터 선택, Enter/y 확인, ESC 취소 | `lib/uninstall/batch.sh:1937-2556` |
| 실행 | `_batch_execute_removals` (1.5) | `batch.sh:2557-3160` |
| 요약 | 성공/실패 앱, 시스템 확장 경고, 실행 중 경고, 설정 파일 참조 힌트, brew autoremove, Dock/LaunchServices 정리 | `batch.sh:3161-3340`, `3352-3585` |
| 반복 | 인터랙티브 모드는 완료 후 5초 카운트다운: Enter=목록 복귀, 그 외 종료. 재진입 시 인벤토리 fingerprint 동일하면 이전 목록 재사용 | `bin/uninstall.sh:2343-2370`, `:2140-2155` |

비TTY 확인 규칙: 프로덕션에서 stdin 비TTY 또는 단일키 read 실패는 Enter가 아님 → preview가 3 반환 → exit 1. dry-run은 계획 출력 후 "no apps were removed" 출력, 상태 4 → exit 0 (`batch.sh:2457-2481`, `.claude/rules/uninstall.md:34`).

### 1.2 앱 인벤토리

**스캔 루트** (`bin/uninstall.sh:525-555`)

| 루트 | 비고 |
|---|---|
| `/Applications` | |
| `~/Applications` | |
| `/Library/Input Methods`, `~/Library/Input Methods` | 입력기 |
| PlayCover 앱 디렉터리 (`mole_playcover_apps_dir`, `~/Library/Containers/io.playcover.PlayCover/Applications`) | 존재 시. Info.plist가 번들 루트에 있는 flat iOS 번들 |
| `/Volumes/*/Applications` | 읽기 가능 + `/Applications`·`~/Applications`와 `-ef` 동일하지 않은 것만 |
| pkg 영수증 비표준 위치 | `pkgutil --pkgs` → 각 `pkgutil --files` → `/usr/local/**.app`, `/opt/**.app` 추출. 캐시 `~/.cache/mole/pkg_receipt_apps_v1`(키=pkg 목록+`/var/db/receipts/*.plist` mtime, TTL 3600s/604800s) `lib/core/pkg_receipts.sh:12-234` |

**열거**: `find <dir> -mindepth 1 -maxdepth 3 ( -type d -name '.*' ! -iname '*.app' -prune ) -o -iname '*.app'` → `stat -f "%m%t%N"` 일괄(앱+Info.plist mtime) (`:683-747`). 숨김 폴더(업데이터 스테이징 `/Applications/.x-update/...`)는 제외, 숨김 `.app` 자체는 포함.

**제외 규칙** `uninstall_should_skip_app_path` (`:557-594`)
- 존재하지 않음, 다른 `.app` 내부에 중첩된 앱
- PlayCover 런처 별칭(대상 번들로 대신 표시)
- symlink가 `/System/*`, `/usr/bin/*`, `/usr/lib/*`, `/bin/*`, `/sbin/*`, `/private/etc/*`를 가리킴

**적격성** `uninstall_app_is_currently_eligible` (`:656-671`)
- `should_protect_from_uninstall(bundle_id)` 참이면 제외 (1.4)
- `LSBackgroundOnly`=true 이면서 스캔 루트 직속이 아니면 제외 (`:625-654`)

**메타데이터**

| 필드 | 출처 | 위치 |
|---|---|---|
| bundle_id | `plutil -extract CFBundleIdentifier raw Contents/Info.plist`, 없으면 캐시값, 없으면 `unknown`. `|`·개행 제거 | `:596-623` |
| 표시 이름 | ① `Contents/Resources/<lang>.lproj/InfoPlist.strings`의 `CFBundleDisplayName`→`CFBundleName` (AppleLanguages 순서, 번들이 지역화한 **첫** 선호 언어에서 멈춤; `Base.lproj`는 `CFBundleDevelopmentRegion` 언어로 간주) ② `mdls kMDItemDisplayName`(40ms, 사용자 로캘; `/`로 시작하거나 `.`로 시작하면 버림) ③ Info.plist `CFBundleDisplayName` ④ `CFBundleName` ⑤ 파일명. 버전 접미사가 숫자 포함이면 파일명 유지. `.app` 제거 | `:124-300` |
| lproj 후보 | `zh-Hans-CN` → `zh-Hans-CN, zh_Hans_CN, zh-Hans, zh_Hans, zh_CN, zh-CN, zh` | `:133-158` |
| 크기(빠른) | `mdls -name kMDItemPhysicalSize -raw` (40ms) → KB | `:84-100` |
| 크기(폴백) | 콜드 행 ≤20개일 때만 `du -skP` (2s) | `:103-121`, `:1032-1080` |
| 크기(정밀/백그라운드) | `get_path_size_kb` (file_ops) | `:362-523` |
| 마지막 사용 | `mdls kMDItemLastUsedDate` (0.2s) → epoch, `978307200`(2001-01-01) 미만은 0. 없으면 앱 mtime 사용 | `:420-430`, `:1340-1350` |
| 상대시간 | Today/Yesterday/N days/weeks/months/years ago, 없으면 Unknown | `:1280-1320` |

**캐시** `~/.cache/mole/uninstall_app_metadata_v5`: 행 `path|app_mtime|size_kb|last_used_epoch|updated_epoch|bundle_id|display_name|language_signature`. 앱 mtime 일치 + 언어 시그니처 일치 + size>0이면 warm. TTL 7일 초과/누락 시 detached 백그라운드 refresh(최대 4 병렬, stdin=/dev/null, mkdir 락 40회·5분 stale) (`:41-54`, `:302-523`, `:912-1030`). 콜드 행은 8–32 병렬 (`:1032-1126`).

**중복 제거** `_scan_dedupe_bundle_ids` (`:1132-1209`): 키 = `bundle_id|basename`. 우선순위 `/Applications` 직속(1) > `~/Applications` 직속(2) > 기타(3) > `/Volumes`(4). 숨김 `.app`은 같은 id의 보이는 앱이 있으면 흡수(#1791). `Xcode.app`과 `Xcode-beta.app`은 별개 유지.

**정렬**: `last_used_epoch` 오름차순(오래 안 쓴 앱 먼저) `:1394`.

### 1.3 잔여물(leftover) 탐색

진입: `find_app_files(bundle_id, app_name, app_path)` (`lib/core/app_protection.sh:1318-2270`), `find_app_system_files` (`:2272-2556`), `find_app_receipt_files` (`:2559-2650`), `get_diagnostic_report_paths_for_app` (`:2202`). 전체 공유 데드라인 `MOLE_TIMEOUT_DISK_VERIFY_SEC`.

**가드 전제**
- bundle_id는 `mole_is_reverse_dns_bundle_id` 통과 시에만 경로/패턴에 사용 (`:1356-1360`).
- app_name 기반 패턴은 길이 ≥2 (`:1367`). 짧은 이름 바닥(LaunchAgent 이름검색 ≥5, crash leaf ≥3 등).
- 이름 변형: 원본, 공백제거, `_`, `-`, 소문자/소문자-공백제거/-하이픈/-언더스코어, 채널 접미사 제거 base(`Nightly|Beta|Alpha|Dev|Canary|Preview|Insider|Edge|Stable|Release|RC|LTS|Developer Edition|Technology Preview`) (`:1336-1353`).

**사용자 영역 (이름 기반, `$N`=app_name)** `:1367-1400`

| 위치 | 패턴 |
|---|---|
| `~/Library/Application Support/`, `Caches/`, `Logs/`, `Preferences/` | `$N` (+ Preferences `$N.plist`) |
| `~/Library/Saved Application State/` | `$N.savedState` |
| `~/Library/Services/` `$N.workflow`, `QuickLook/` `$N.qlgenerator`, `Internet Plug-Ins/` `$N.plugin`, `Audio/Plug-Ins/{Components,VST,VST3,Digidesign}/` `.component/.vst/.vst3/.dpm`, `PreferencePanes/` `.prefPane`, `Input Methods/` `.app`, `Screen Savers/` `.saver`, `Frameworks/` `.framework`, `Contextual Menu Items/` `.plugin`, `Spotlight/` `.mdimporter`, `ColorPickers/` `.colorPicker`, `Workflows/` `.workflow`, `Address Book Plug-Ins/` `.bundle`, `Accessibility/` `.bundle`, `Mail/Bundles/` `.mailbundle` | |
| `~/.config/$N`, `~/.cache/$N`, `~/.cache/<lower>`, `~/.local/share/$N` | XDG |
| 공백 포함 이름(>3자) | 위 주요 위치에 nospace/underscore/hyphen 변형, `~/.config|.cache|.local/share`에 소문자 변형 (`:1498-1523`) |
| base name(채널 제거) | AppSupport/Caches/Logs/Preferences/savedState + XDG 소문자 (`:1526-1538`) |
| 최상위 dotdir(`~/.<name>`) | **이름에서 파생 금지** (Local/Docker 충돌). 제품별 명시 규칙만 |

**사용자 영역 (bundle id 기반, `$B`)** `:1402-1430`

| 위치 |
|---|
| `~/Library/{Application Support,Caches,Logs,Containers,WebKit,HTTPStorages,Application Scripts,Autosave Information}/$B` |
| `~/Library/WebKit/com.apple.WebKit.WebContent/$B`, `HTTPStorages/$B.binarycookies`, `Cookies/$B.binarycookies`, `Saved Application State/$B.savedState`, `Input Methods/$B.app`, `SyncedPreferences/$B.plist` |
| 크래시/업데이터 프레임워크 leaf: `Caches/com.plausiblelabs.crashreporter.data/$B`, `Caches/$B.ShipIt`, `Caches/com.crashlytics.data/$B`, `Application Support/com.bugsnag.Bugsnag/$B` |
| Darwin 사용자 캐시 루트(`getconf DARWIN_USER_CACHE_DIR` 계열) `/$B` |
| `Caches/SentryCrash/$N`, `Caches/KSCrash/$N`, `Caches/<name>-updater`, `Application Support/Caches/<name>-updater` (이름 ≥3, 일반명·`electron` 제외) `:1435-1450` |
| bundle leaf 파생: leaf ≥8자, camelCase, 표시명(공백제거)으로 시작해 대문자/숫자 경계로 이어질 때만 → leaf 원문과 "표시명 + 분리된 나머지" 두 변형 (`AyuGram` / `one.ayugram.AyuGramDesktop` → `AyuGram Desktop`) `:1463-1494` |
| `Preferences/$B.plist`, `Preferences/$B/` |
| `Preferences/ByHost/*.plist` 중 `$B` 또는 `$B.*`로 시작 `:1626-1645` |
| `Caches/com.apple.nsurlsessiond/Downloads/$B` |
| `Group Containers/*` 중 이름에 `$B` 경계 포함(`$B`, `$B.*`, `*.$B`, `*.$B.*`) `:1651-1665` |
| `Application Scripts/`, `Containers/`, `Application Support/FileProvider/` 직속 중 `$B` 경계 포함 (확장 id) `:1667-1700` |
| `Containers/<UUID>`: `.com.apple.containermanagerd.metadata.plist`의 `MCMMetadataIdentifier == $B` 정확 일치 (`:1082-1095`, `:1703-1722`) |
| `Application Support/*/NativeMessagingHosts/*.json`, `*/*/NativeMessagingHosts/*.json`: 정규 파일, ≤64KB, `path`가 선택 앱 내부를 가리킬 때만 (`:1097+`, `:1726-1748`) |
| `Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$B.sfl{2,3,4}` `:1753-1770` |
| 임베디드 번들 id(`Contents/**/Info.plist` maxdepth 12 중 `.xpc`, `.appex`, `Contents/Library/LoginItems/*.app`; `org.sparkle-project.*` 제외) → `Application Scripts/`, `FileProvider/`, `Caches/`, `Containers/`, `HTTPStorages/(.binarycookies)`, `Preferences/<id>.plist`, `WebKit/`, `ByHost/<id>.*.plist` `:1130-1180`, `:1777-1822` |
| vendor 중첩: bundle id의 vendor 토큰(≥3자) 폴더 아래 product (`Application Support/Avid/Sibelius`), AppSupport/Caches/Logs `:891`, `:1607-1620` |
| `~/Library/LaunchAgents/*.plist`: 이름이 `$B.plist`/`$B.*.plist` 또는(이름 ≥5, 일반단어 아님) `*$N*` → 1차, 그 외 전부 2차로 `Program`/`ProgramArguments[0]`이 앱 번들 내부 실제 파일인지 확인. `com.apple.*` 제외 (`:841-889`, `:1826-1870`) |
| `~/Library/Application Support/CrashReporter/{$N,nospace}_*.plist` `:2112-2130` |
| `~/Library/Logs/DiagnosticReports` (실행파일명/앱명 접두, Electron 공유 실행파일명이면 앱명) `:2202-2270` |

**제품별 특수 규칙** (`collect_toolchain_leftovers`일 때; 생성 가능한 캐시만) `:1878-2110`
- Huawei DevEco, Android Studio(`~/.android/{cache,build-cache,breakpad}`, `Application Support/Google/AndroidStudio<ver>`), Xcode(`Developer/Xcode/{DerivedData,*DeviceSupport}`, `CoreSimulator/Caches`, `~/.Xcode`), JetBrains(`Application Support|Caches|Logs/JetBrains/<product><YYYY.x>` 정확 버전 leaf, Info.plist `JVMOptions.Properties["idea.paths.selector"]`), Godot, VSCode(`.vscode`, `Application Support/Code`, ShipIt, Insiders 분기), Docker(`~/.docker/{buildx,scan}`), `.mobiledev`, Anki, Claude(`Claude-3p`), Raycast(`*raycast*` ! `*raycast-x*`), Zed(`HTTPStorages/dev.zed.Zed-*`), PlayCover(`App Settings|Keymapping|Entitlements/$B.plist`, 별칭).

**시스템 영역** `find_app_system_files` (`:2272-2556`) — **CLI에서는 미리보기 "Review only"로만 표시, 삭제 안 함** (`batch.sh:2285-2294`에서 `system_files=""`로 비움)

| 위치 |
|---|
| `/Library/Application Support/{$N,$B}`, `/Library/Caches/{$N,$B}`, `/Library/Logs/{$N,$B}`, `/Library/Preferences/{$B.plist,$N,$N.plist}` |
| `/Library/LaunchAgents/$B.plist`, `/Library/LaunchDaemons/$B.plist` + `$B.*.plist` + (이름 ≥5) `*$N*.plist`(`com.apple.*` 제외) |
| `/Library/Receipts/$B.{bom,plist}`, `/private/var/db/receipts/$B*` |
| `/Library/{Frameworks,Internet Plug-Ins,Input Methods,Audio/Plug-Ins/*,QuickLook,PreferencePanes,Screen Savers,Extensions(.kext),StartupItems}/$N.*` |
| `/Library/PrivilegedHelperTools/` `$B` 접두 또는 이름 변형(≥5자, 일반명 아님) 포함 |
| vendor 중첩(`/Library/{Application Support,Caches,Logs}`), `/Users/Shared` 공유 경로 |
| pkg BOM: `/private/var/db/receipts/$B*.bom` → `lsbom -f -s` → 경로 중 allowlist(`/Library/Launch{Agents,Daemons}/$B(.*).plist`, `/Library/PrivilegedHelperTools/$B*`, `/private/var/db/receipts/$B*`)만, `..` 거부 (`:2559-2680`) |
| `/Library/Logs/DiagnosticReports` |
| `/Library/SystemExtensions/**/*.systemextension` (`$B` 접두) → 삭제 아님, 요약에 경고만 (`batch.sh:3124-3136`) |

**거부/스킵 규칙**
- 결과가 Library 루트 자체(`Application Support`, `Caches`, `Logs`, `Preferences`, `ByHost`, `Containers`, `WebKit`, `HTTPStorages`, `Application Scripts`, `Autosave Information`, `Group Containers`, `.config`, `.cache`, `.local/share`, `$HOME`)면 제외 (`:1560-1580`).
- 공유 홈 상태 루트: `~/.cache`, `~/.config`, `~/.local{,/bin,/lib,/share,/state}`, `~/Library/Unity`, `~/Library/Application Support/Epic` (`:347-360`).
- Steam 라이브러리 `~/Library/Application Support/Steam` 및 하위 전부 금지(대소문자 무시) (`:362-375`).
- 독립 CLI dotdir: 이름 `claude|opencode|codex|gemini` + 부모가 `$HOME|.config|.local/share|.cache` (#993) (`:1037-1060`).
- 일반 단어 이름: `music, notes, photos, ..., helper, agent, daemon, service, update, sync, backup, cloud, manager, ..., utility` (`:746-757`).
- 패밀리 공유 leaf: 같은 패밀리(채널 제거 동일명) 앱이 남아 있으면 이름 기반 leaf 제외, bundle-id leaf만 유지 (`:1290`, `:2162-2170`).
- 모든 결과는 `MOLE_UNINSTALL_MODE=1 should_protect_path`로 재필터 (`batch.sh:2274-2283`).

### 1.4 보호 목록 (`lib/core/app_protection_data.sh`)

| 목록 | 내용 | 효과 |
|---|---|---|
| `SYSTEM_CRITICAL_BUNDLES` `:19-160` | Finder, Dock, Safari, Mail, SystemSettings, Preview, TextEdit, Notes, Photos, AppStore, Terminal, … `com.apple.CoreServices*`, `com.apple.security*`, `com.apple.inputmethod.*` 등 + 비-id 이름(`loginwindow`, `keychain*`, `tcc` …) | 목록에서 제외 |
| `APPLE_UNINSTALLABLE_APPS` `:163-176` | `com.apple.dt.*`(Xcode), `FinalCut*`, `Motion`, `Compressor`, `logic*`, `garageband*`, `iMovie`, `iWork.*`, `MainStage*`, `server.*`, `Playgrounds` | critical보다 먼저 매칭 → 삭제 허용 |
| `OFFICIAL_UNINSTALLER_RULES` `:179-206` | ESET, Jamf, CrowdStrike, SentinelOne, GlobalProtect, Cisco, Alibaba, Adobe Genuine, Avast, AVG, Malwarebytes, TeamViewer, Bitdefender, Intego, Kaspersky, Norton, Trend Micro (`vendor|id-prefix,...|name-fragment,...`) | 미리보기에서 차단, "공식 언인스톨러 필요" 경고 `batch.sh:~1983`, `:2342-2346` |
| 매칭 방식 | 대소문자 구분 glob, `@(a|b|...)` alternation (엔트리에 `| ( )` 금지) | `.claude/rules/uninstall.md:23` |

### 1.5 개인 데이터 분류 (`lib/uninstall/review.sh`)

| 분류 | 규칙 | 기본 선택 |
|---|---|---|
| 자동(disposable) | `~/Library/Caches/*`, `~/Library/Logs/*` (단 Spotify·Raycast·MullvadBrowser 캐시는 개인 데이터) `:4-14` | 항상 삭제 |
| 개인 데이터 | 그 외 전부 | **미선택**; `--with-data`면 holdback 제외 전부 선택; `D`로 토글 |
| holdback | `~/Library/Group Containers/*`, Whisky 컨테이너, `Application Support/{Google/Chrome*,BraveSoftware*,Microsoft Edge*,com.operasoftware.Opera*,Chromium,Vivaldi,Arc,Firefox,Zen,CrossOver,OpenEmu,Dolphin,PCSX2,RetroArch,PrismLauncher,Minecraft,Citra,Cemu,Ryujinx,PPSSPP,RPCS3,MultiMC,ATLauncher}` (대소문자 무시) `:24-62` | `--with-data`여도 미선택 |
| 민감 표시 | `has_sensitive_data`: `.ssh/.gnupg/.aws/.kube/Cookies/Passwords/Accounts/credentials/secrets/Preferences/*.plist/User Data/...` 포함 시 플래그 `batch.sh:33-55` | 표시용 |
| 중첩 제거 | `mole_filter_nested_paths`로 상위 경로만 유지 `:73` | |

### 1.6 실행 순서 (앱 1개당, `batch.sh:2557-3160`)

| # | 동작 | 외부 명령 | 비고 |
|---|---|---|---|
| 0 | sudo 세션 확보 (sudo_apps 또는 brew cask 존재 시, dry-run 제외) | `sudo` (file_ops/sudo.sh) | `:2531-2540`. lsof-mode memo 순서상 반드시 실행 전 |
| 1 | 동일 bundle id 형제 스냅샷 재구성 → 미리보기와 다르면 거부 | `find`, `pkgutil` | `:2600-2665` |
| 2 | 앱 identity(inode 등)·Info.plist identity 재확인 | `stat` | `:2674-2684`, `:1899` |
| 3 | LaunchAgents 언로드 (`~/Library/LaunchAgents`만; 시스템 Agents/Daemons는 `has_system_files` 필요한데 CLI에서 비워지므로 사실상 미실행) | `launchctl unload [sudo]` | `:566-617`, `:434-485` |
| 4 | LaunchServices 등록 해제 | `lsregister -u <app>` | `:619-639` |
| 5 | 로그인 항목 제거(이름 일치, 역순 삭제). sibling guard `guard_login`·PlayCover면 생략 | `osascript` → System Events | `:655-711`, `:2709-2720` |
| 6 | 앱 종료 (sibling guard 없을 때). 시스템 프로세스명 거부, 공유 런타임(Electron)은 `osascript "application id … to quit"`만. 실패해도 계속(경고) | `osascript`, `pgrep -x`, `kill` | `app_protection.sh:~2690-2800`, `batch.sh:2730-2740` |
| 7 | 앱 삭제: brew cask면 `brew uninstall --cask <token>` (**nozap**, sudo 컨텍스트면 `sudo -u $SUDO_USER`). 실패 시 cask 미설치 확인되면 수동 삭제. 아니면 `mole_delete(app, needs_sudo, identity)` | `brew`, file_ops | `:2766-2900`, `brew.sh:519-618` |
| 8 | 잔여물 삭제 `remove_file_list(related_files, …, bundle_id, app_path)` — UUID 컨테이너/NativeMessaging은 개별 sink, 앱 재출현·형제 발견 시 `MOLE_ERR_OWNER_UNVERIFIED`로 패밀리 보류 | file_ops | `:2915-2927`, `:730-975` |
| 9 | 남은 잔여물 측정 (containermanagerd stub은 성공 간주) | `du` | `:2930-2990`, `:713-728` |
| 10 | 로그인 아이템 헬퍼 bootout (`Contents/Library/LoginItems/*.app` id) | `launchctl bootout gui/<uid>/<id>` | `:394-422`, `:347-392` |
| 11 | review-only 시스템 경로 재확인(남은 것만 요약에 표시) | | `:3101-3112` |
| 배치 후 | 설정파일 참조 힌트, `brew autoremove`(brew 성공 시), Dock에서 제거(`PlistBuddy` on `com.apple.dock.plist`), `lsregister -gc` | `perl`, `brew`, `PlistBuddy`, `killall Dock`(추정), `lsregister` | `:3510-3535`, `common.sh:281` |

**needs_sudo 결정** (`batch.sh:2163-2171`): 부모 디렉터리 비쓰기 OR (permanent 모드 AND 소유자가 root/타 사용자). Trash 모드에서 root 소유 앱이라도 부모 쓰기 가능하면 sudo 불필요(TCC 차단 시 Finder 경유 재시도). sudo 필요 + 사용자 변경 가능한 조상 경로면 "Finder로 휴지통 이동" 안내 후 제외 (`:2178-2183`).

### 1.7 Sibling guard / 패밀리 소유권

| 개념 | 규칙 | 위치 |
|---|---|---|
| 형제 판정 | id 동일(대소문자 무시), dot-continuation(`a.b` vs `a.b.c`), 또는 버전/채널 접미사 제거한 `.app` 이름 동일. JetBrains는 selector 비교, 못 읽으면 공유로 간주 | `batch.sh:990-1028` |
| 라이브 스캔 루트 | `/Applications`, `~/Applications`, `/System/Applications`, `/Library/Input Methods`, `~/Library/Input Methods`, `~/Library/Application Support/Setapp/Applications`, PlayCover, `/opt/homebrew/Caskroom`, `/usr/local/Caskroom`, `/Volumes/*`(1단계 아래, TimeMachine localsnapshots·죽은 네트워크 공유 제외) + pkg 영수증 앱 | `:1035-1045`, `:1370-1420` |
| 결과 | 0=형제 있음, 1=완전 부재 증명, 2/3(PARTIAL)=불확실 → 불확실하면 앱 번들만 삭제로 축소 | `:1420-1676` |
| 형제 존재 시 | bundle_id를 `unknown`으로 강등(이름 기반만), 이름도 충돌하면 `guard_login`(로그인 항목·kill·helper bootout 생략), 이름 없음이면 번들만 | `batch.sh:2060-2116` |
| 보류 원인 | `shared-owner`, `owner-unknown`, `app-reappeared` — 원인당 1회 출력, reclaimed에 미포함 | `.claude/rules/uninstall.md:54` |
| symlink 스캔 루트 | 부재 증거 아님(`find -L` 금지) | `uninstall.md:48` |

### 1.8 Homebrew / Steam / 설정 참조

| 기능 | 규칙 | 위치 |
|---|---|---|
| cask 감지 순서 | ① realpath가 `/opt/homebrew/Caskroom` 또는 `/usr/local/Caskroom` 아래 → 토큰 추출 ② Caskroom에서 번들명 검색 ③ 앱이 Caskroom 직접 symlink ④ `brew list --cask`에서 앱명 소문자 일치 후 `brew info --cask` 출력에 앱 경로 포함 확인 | `brew.sh:479-517`, `:282-478` |
| 실패 처리 | `brew info` 실패 시, 유일 설치 cask의 app symlink가 정확히 선택 앱을 가리키면 Caskroom 소유 인정. 파싱 불가 cask는 앱 이름 + `brew info --cask` 안내 | `uninstall.md:61-63` |
| env | `HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1`, 타임아웃 | `brew.sh:519-618` (`brew_uninstall_cask`) |
| Steam 런처 | `Contents/MacOS/<exec>`가 ≤4KB `#!/bin/(ba|z)sh` 스크립트, 유일 활성 명령이 `open steam://run/<appid>` → 크기 "N/A (Steam-managed)", 게임 파일 미포함 경고 | `steam.sh:19-103`, `bin/uninstall.sh:57-71` |
| 설정 참조 | 삭제된 경로(및 `~/`, `$HOME/`, `${HOME}/` 형태)를 `.zshrc .zprofile .zshenv .bashrc .bash_profile .profile .config/fish/config.fish .claude/settings.json .claude.json .codex/hooks.json .codex/config.toml .cursor/hooks.json .cursor/mcp.json .gemini/settings.json`에서 검색(≤1MB, O_NOFOLLOW, 홈 내부 realpath). **내용 출력 금지, `파일:줄`만** | `config_refs.sh:4-84` |

### 1.9 `mo clean`의 고아 데이터(참고, `lib/clean/apps.sh`)
- 설치 앱 목록: `/Applications`, `/System/Applications`, `~/Applications`, Setapp 등 `find -maxdepth 3 -iname '*.app'`, 5분 캐시 `~/.cache/mole/installed_apps_cache` (`:150-437`). uninstall이 새 앱 형태(PlayCover 별칭)를 받으면 여기도 동일 헬퍼 필요(`uninstall.md:29`).
- 고아 판정 `is_bundle_orphaned` (`:464-543`): `should_protect_data` 아님 + 설치목록에 없음 + mtime ≥30일(`MOLE_ORPHAN_AGE_DAYS`) + `mdfind "kMDItemCFBundleIdentifier == '<id>'"` 결과 없음.

### 1.10 외부 명령 (uninstall)
`plutil`, `PlistBuddy`, `mdls`, `mdfind`, `stat`, `du`, `find`, `defaults read -g AppleLanguages`, `pkgutil --pkgs/--files`, `lsbom`, `launchctl unload/bootout`, `lsregister -u/-gc`, `osascript`(System Events, app quit), `pgrep/kill`, `brew`, `sudo`, `perl`, `lsof`(file_ops).

---

## 2. `mo purge`

### 2.1 흐름

| 단계 | 내용 | 위치 |
|---|---|---|
| 플래그 | `--paths`(설정 편집 후 종료), `--dry-run/-n`, `--yes`(MOLE_PURGE_YES), `--include-empty`, `--debug`, `-h` | `bin/purge.sh:331-362` |
| 사전 | 화이트리스트 로드 실패 시 종료 | `bin/purge.sh:35` |
| 비TTY | `! -t 0 && !dry-run && !--yes` → 거부 | `project.sh:2044` |
| 루트 결정 | `load_purge_config` (2.2) | `project.sh:207-276` |
| 스캔 | 루트별 1 unit 병렬 스캔 → 타임아웃 시 직속 자식 단위 재스캔(#1666) | `project.sh:2043-2420` |
| 바인딩 | 후보를 스캔 루트 identity(부모 id, 대상 id)에 바인딩, 루트 변경 시 전부 폐기 | `:2450-2545` |
| 활동 분류 | `classify_purge_activity` 병렬(공유 데드라인) | `:2595-2710`, `:1228-1302` |
| 크기 | `du` 슬라이딩 윈도우 병렬, unknown 허용; size 0은 `--include-empty` 없으면 숨김 | `:2715-2905` |
| 그룹/정렬 | 프로젝트 루트(지표 기반, 없으면 직속 부모)별 그룹, 그룹 총합 크기 내림차순 → 항목 크기 | `:2840-3080` |
| 선택 | TTY: `select_purge_categories`(recent는 미선택). 비TTY: recent 아닌 것 전부, 클라우드 경로는 dry-run 아니면 건너뜀 | `:3118-3145`, `:1510` |
| 확인 | 선택 경로 목록, 클라우드 경고, `Enter` 확인/`ESC` 취소; read 실패=취소 | `:1978-2041` |
| 실행 | 항목별 재검증 후 `safe_remove(path, true, size, "", parent, parent_id, target_id)` + 최종 가드 `_mole_purge_final_remove_guard` | `:3185-3300`, `:1334-1367` |
| 요약 | `print_summary_block`, 통계 파일 `~/.cache/mole/purge_stats|purge_count` | `bin/purge.sh:180-307` |

### 2.2 스캔 루트

| 출처 | 내용 | 위치 |
|---|---|---|
| 사용자 설정 | `~/.config/mole/purge_paths` (한 줄 1경로, `#` 주석, `~` 확장, 실제 대소문자로 정규화) — 있으면 이것만 사용 | `purge_shared.sh:312-325` |
| 최초 실행 탐색 | 기본 경로 중 존재하는 것 + `$HOME/*/` 중 `is_project_container`(maxdepth 2에서 프로젝트 지표 발견) → 완전 성공 시 설정 파일에 저장, 부분 성공이면 저장 안 함 | `project.sh:98-147`, `:233-275` |
| 기본 경로 | `~/www ~/dev ~/Projects ~/GitHub ~/Code ~/Workspace ~/Repos ~/Development ~/Developer ~/Library/CloudStorage ~/.codex/worktrees ~/.claude/worktrees ~/.t3/worktrees` | `purge_shared.sh:54-73` |
| 컨테이너 제외 | basename `.*`, `Library`, `Applications`, `Movies`, `Music`, `Pictures`, `Public`, **모든 PURGE_TARGETS 이름**(#1459) | `project.sh:40-96` |
| `--paths` | 템플릿 생성 → 현재 경로 상태 표시 → 편집기 열기 | `lib/manage/purge_paths.sh:19-122` |

### 2.3 산출물 이름 (전체, `MOLE_PURGE_TARGETS`, `purge_shared.sh:18-52`)

| 이름 | 생태계 | 이름 | 생태계 |
|---|---|---|---|
| `node_modules` | npm/pnpm/Yarn (추가 보호) | `.next` | Next.js |
| `target` | Rust, Maven | `.nuxt`, `.output` | Nuxt |
| `build` | Gradle 등 | `vendor` | PHP Composer (보호 규칙) |
| `dist` | JS | `bin` | .NET (보호 규칙) |
| `venv`, `.venv` | Python | `obj` | C#/Unity |
| `.pytest_cache` | pytest | `.turbo` | Turborepo |
| `.mypy_cache` | mypy | `.parcel-cache` | Parcel |
| `.tox`, `.nox` | tox/nox | `.dart_tool` | Flutter/Dart |
| `.ruff_cache` | ruff | `.zig-cache`, `zig-out` | Zig |
| `.gradle` | Gradle | `.angular` | Angular |
| `.terragrunt-cache` | Terragrunt | `.svelte-kit` | SvelteKit |
| `__pycache__` | Python | `.astro` | Astro |
| `coverage` | 커버리지 | `DerivedData` | Xcode (단 `~/Library/Developer/Xcode/DerivedData`는 보호) |
| `Pods` | CocoaPods | `.cxx` | RN Android NDK |
| `.expo` | Expo | `.build` | SwiftPM |

추가 후보: 스캔 루트 깊이 2–7의 `CACHEDIR.TAG` 파일 중 첫 바이트가 `Signature: 8a477f597d28d172789f06886806bc55`인 디렉터리 (`purge_shared.sh:105-106,263-271`, `project.sh:831-843`).

프로젝트 지표: monorepo `lerna.json pnpm-workspace.yaml nx.json rush.json .git`, 일반 `package.json Cargo.toml go.mod pyproject.toml requirements.txt pom.xml build.gradle terragrunt.hcl Gemfile composer.json pubspec.yaml Package.swift Makefile build.zig build.zig.zon .git` (`purge_shared.sh:75-103`).

### 2.4 워크 규칙

| 규칙 | 값 | 위치 |
|---|---|---|
| 깊이 | 대상 1–6 (루트 기준), 태그 2–7 | `project.sh:20-21`, `:775-812` |
| prune | `.git`, `Library`, `.Trash`, `Applications`, dataless(iCloud online-only, `find -flags +dataless` 지원 시) | `:676`, `:662-675` |
| 대상 발견 시 | `-print -prune` (하위로 내려가지 않음) | `:1025-1030` |
| 도구 | `fd` 있으면 fd(오류 보고 시 find 재스캔), 클라우드 경로·`MO_USE_FIND=1`은 find | `:880-975` |
| 타임아웃 | 루트당 `MO_PURGE_SCAN_TIMEOUT_SEC`(기본 60s). 비-프로젝트 루트가 124면 직속 자식 단위로 재스캔(각자 예산, 총량 cap=예산×슬롯), 스킵 경로 최대 10개 + `and N more` | `:754-760`, `:709-752` |
| 중첩 제거 | 정렬 후 상위 산출물만 유지 (`a/node_modules` 안의 `node_modules` 제외) | `:1074-1100` |
| 깊이 0 산출물 | 루트 자체가 프로젝트 루트일 때만 직속 자식 산출물 허용 | `:358-375` |
| 물리 경로 포함 | `pwd -P`로 루트 내부 확인 | `:377-418` |

### 2.5 보호 규칙 (`is_protected_purge_artifact`, `project.sh:602-660`; 발견 시와 삭제 직전 모두)

| 조건 | 결과 |
|---|---|
| 산출물 내부에 `.git` 또는 `*-keypair.json` 존재 | 보호 |
| Git 추적 파일 포함: 물리 경로 상위의 `.git` 저장소에서 `git ls-files -- ':(top,literal,icase)<rel>'` 결과 비어있지 않음. `/usr/bin/git` shim이면 `xcode-select -p`로 실제 git 해석(없으면 unknown, 설치 프롬프트 금지). `GIT_*` env 해제, `core.fsmonitor=false`, `GIT_OPTIONAL_LOCKS=0` | 보호 (`purge_shared.sh:195-261`) |
| 위 probe 타임아웃/실패 | 상태 2 = unverified → 유지, "Could not inspect X; kept" | |
| `node_modules` | 부모에 `package.json` 없음 → 보호. 락파일/설치기록 쌍(`package-lock.json:.package-lock.json`, `npm-shrinkwrap.json:.package-lock.json`, `pnpm-lock.yaml:.modules.yaml`, `yarn.lock:.yarn-integrity`, `yarn.lock:.yarn-state.yml`) 없음 → 보호. 기록보다 새 파일 존재(`.cache` 제외) → 보호. 프로젝트 cwd 또는 인자로 실행 중인 프로세스(`lsof -d cwd`, `pgrep -f`) → 보호, 가시성 불완전 → unverified (`:550-600`) |
| `bin` | `*.csproj/.fsproj/.vbproj` 형제 + `Debug|Release` 하위 있을 때만 삭제 가능, 그 외 보호 (`:469-485`) |
| `vendor` | 부모가 `composer.json`(PHP)일 때만 삭제 가능, Rails/Go/기타 보호 (`:487-518`) |
| `DerivedData` | `/Library/Developer/Xcode/DerivedData` 경로면 보호 |
| probe 동시성 | 최대 4, 입력 순서대로 결과 게시, 취소 시 아무것도 게시 안 함 (`:1115-1226`) |

### 2.6 나이(활동) 규칙
- `MIN_AGE_DAYS=7` (`project.sh:17`). 디렉터리 mtime < 7일 → recent. 아니면 `find <path> -type f -mtime -7 -print -quit`로 최근 파일 있으면 recent, 없으면 old. 읽기 실패/예산 소진 → uncertain (`:1228-1302`).
- recent/uncertain은 메뉴에 표시되나 **미선택**(비TTY에서는 제외). 삭제 직전 old였던 항목은 재분류해 recent로 바뀌면 건너뜀 (`:1312-1332`).

### 2.7 Git worktree
- 워크트리 컨테이너(`~/.codex/worktrees` 등)는 기본 경로에 명시 등록; 일반 dot 디렉터리로 확장 금지 (`purge-installer.md:83`).
- 워크트리 자체는 절대 삭제 대상 아님; 내부 화이트리스트 산출물만. "삭제해도 안전" 판정 금지, 상태 표면은 blocker(dirty/unpushed/locked/ignored 비대상)만 보고 가능 (`purge-installer.md:82`).
- `.git`은 prune 대상이므로 워크트리의 `.git` 파일/디렉터리 하위로 내려가지 않음.

### 2.8 최종 sink 가드 (`_mole_purge_final_remove_guard`, `project.sh:1334-1367`)
1) 설정 루트 안의 안전 산출물 2) 활동 재확인 3) 보호 재검사 4) 스캔 루트(논리/물리) identity 일치 5) 대상 identity(parent, parent_id, target_id) 일치 6) 현재 물리 경로가 루트 안. 하나라도 실패 시 skip("path changed after review" 등).

### 2.9 외부 명령 (purge)
`find`(BSD, `-flags +dataless`), `fd`(선택), `du`, `git ls-files`, `xcode-select -p`, `lsof -nP -a -u <uid> -d cwd -Fn`, `pgrep -f`, `stat`, `sort`, `awk`, `dd`.

---

## 3. `mo installer`

### 3.1 흐름

| 단계 | 내용 | 위치 |
|---|---|---|
| 플래그 | `--dry-run/-n`, `--debug`, `-h` | `bin/installer.sh:995-1010` |
| 스캔 | 경로별 fd/find, 실패 시 부분 결과 게시 안 함 | `:134-226` |
| 수집 | `sort -zu` 중복 제거 → `stat -f%z` 크기 → 표시행(이름, 크기, 출처) | `:308-426` |
| 선택 | alt screen 페이지 메뉴, read EOF=취소(선택 후에도) | `:428-669` |
| 계획 | 선택 인덱스 → `mole_deletion_identity`로 불변 계획(path, size, identity) | `:702-735` |
| 확인 | "Files to be removed" + `Delete N installers, SIZE  Enter/ESC`; read 실패/ESC/q/기타 = 취소 | `:798-876` |
| 실행 | 존재·identity·크기 재확인 후 `mole_delete(path, false, identity)` | `:737-796` |
| 요약 | dry-run/incomplete 헤딩, MB 단위 | `:939-993` |
| 종료코드 | 0 성공, 1 취소/불완전, 2 없음, 3 불완전 삭제(→1), 4 스캔 실패(→1) | `:1018-1050` |

### 3.2 위치 · 파일 유형

| 스캔 경로 (`:40-54`) | 출처 라벨 |
|---|---|
| `~/Downloads` | Downloads |
| `~/Desktop` | Desktop |
| `~/Documents` | Documents |
| `~/Public` | Public |
| `~/Library/Downloads` | Library |
| `/Users/Shared`, `/Users/Shared/Downloads` | Shared |
| `~/Library/Caches/Homebrew` | Homebrew |
| `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads` | iCloud |
| `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | Mail |
| `~/Library/Application Support/Telegram Desktop`, `~/Downloads/Telegram Desktop` | Telegram |

| 규칙 | 값 |
|---|---|
| 깊이 | `MOLE_INSTALLER_SCAN_MAX_DEPTH` 기본 2 |
| 도구 | `fd --show-errors --print0 --no-ignore --hidden --type f --max-depth N -e dmg -e pkg -e mpkg -e iso -e xip -e zip` 또는 `find -H … -type f ( -name '*.dmg' … ) -print0` |
| 확장자 | `.dmg .pkg .mpkg .iso .xip` 무조건, `.zip`은 설치용일 때만 |
| zip 판정 | `zipinfo -1`(없으면 `unzip -Z -1`) 전체 목록 성공 후 **처음 50개 엔트리** 중 `\.(app|pkg|dmg|xip)(/|$)` 존재 (`:72-94`). 손상/읽기불가 = 일반 zip. 개별 zip 타임아웃은 skip, 전체 데드라인만 중단 |
| symlink | 건너뜀 (`:98`) |
| 권한 오류 | 진단이 전부 `Permission denied`/`Operation not permitted`이면 무시하고 진행, 그 외 진단은 스캔 실패 (`:129-132`, `:172-180`) |
| 보호/나이 | 없음(나이·화이트리스트 필터 없음) |

### 3.3 외부 명령
`fd`/`find`, `zipinfo`/`unzip`, `stat`, `awk`, `sort -z`.

---

## 4. `mo slim`

### 4.1 흐름

| 단계 | 내용 | 위치 |
|---|---|---|
| preflight | Apple Silicon 아니면 exit 4 문구 출력(→1). `/usr/sbin/sysctl -n hw.optional.arm64 == 1` (절대 경로, Rosetta 셸 대응 #1804). 화이트리스트 로드, 작업 temp dir | `bin/slim.sh:85-93`, `:834-842` |
| 수집 | 앱 열거 → `slim_skip_reason`(running 제외) → Developer ID Team → 계획 → identity → Gatekeeper 병렬 사전검사 → Intel 바이트 내림차순 | `:400-485` |
| 비TTY/dry-run | 목록만 출력 후 0 ("Run mo slim in a terminal") | `:880-886` |
| 선택 | 공유 셀렉터, 사전 선택 없음, 실행 중 앱 `[Running]` 태그 | `:717-777` |
| 실행 | 앱별 `slim_one_app`, 신호 상태면 중단 | `:900-925`, `:592-715` |
| 요약 | 성공 앱 3개씩, 실패는 사유별 그룹, 앱당 `REBUILT` 로그 | `:779-832` |

### 4.2 범위 / 제외 (`slim_skip_reason`, `:137-197`)

| 조건 | 사유 |
|---|---|
| 루트 | `/Applications`, `~/Applications`, 그 아래 일반 폴더 1단계(번들/symlink 아님) (`:409-421`) |
| whitelist 경로 | `whitelisted` |
| symlink | `symlink` |
| `Contents/` 없음 | `not an app bundle` |
| `Contents/_MASReceipt` | `App Store app` |
| 소유자 ≠ 현재 uid | `not owned by you` |
| 부모 비쓰기 | `folder not writable` |
| 내부에 다른 사용자 소유 파일(`find ! -user`) | `contains files owned by another user` |
| CFBundleIdentifier 없음 / `com.apple.*` | |
| `should_protect_from_uninstall` 또는 공식 언인스톨러 벤더 | `protected app` |
| `~/Library/Preferences/com.apple.LaunchServices/com.apple.LaunchServices.plist`의 `LSArchitecturesForX86_64`에 id 존재 ("Rosetta로 열기") | `set to open using Rosetta` (`:122-135`) |
| 실행 중 (`ps -axww -o comm=`가 앱 경로 하위) | `still running` (시작 시·스왑 직전) |
| 서명 | `codesign -dv --verbose=2`에 `Authority=Developer ID Application: ` + 10자 TeamIdentifier 필수 (`:103-111`) |
| Gatekeeper | `spctl --assess --type execute` 병렬 20s, **exit 3만** 제외(타임아웃·기타 오류는 유지) (`:446-466`) |
| Intel 바이트 0 | 제외 |

### 4.3 Intel 슬라이스 탐지 / 제거

| 항목 | 규칙 | 위치 |
|---|---|---|
| 파일 후보 | `find <app>/Contents -type f ! -path '*/Resources/*' ! -path '*/_CodeSignature/*'` → `file -N`이 `Mach-O universal` | `:392-396` |
| 봉인 루트 | 파일에서 위로 올라가며 `_CodeSignature/CodeResources` 있는 첫 디렉터리 (`Contents/` 또는 `Versions/<v>/`) | `:234-248` |
| 허용 조건 | (a) 봉인 루트의 메인 실행파일(`MacOS/<CFBundleExecutable>` 또는 프레임워크 `Versions/<v>/<CFBundleExecutable>`) 또는 (b) CodeResources `files2` 항목이 `cdhash`로 봉인됨(`c`) | `:250-261`, `:360-391` |
| 거부 조건 | `hash2`로만 봉인(`h`), **또는 앱까지의 모든 상위 봉인 중 하나라도 같은 파일을 `h`로 나열** (ScreenFlow/Stash 사례) | `:375-383` |
| CodeResources 파싱 | `plutil -convert xml1 -o -` → awk로 `files2` dict 키별 `cdhash` 키 존재 여부 | `:199-232` |
| fat 헤더 | `od`로 읽음(lipo 사용 금지: CLT 미설치 시 설치 프롬프트). 매직 `CA FE BA BE`(FAT_MAGIC, 엔트리 20B) / `CA FE BA BF`(FAT_MAGIC_64, 32B), 빅엔디언, nfat 1–16, off+size ≤ 파일 크기 | `:263-308` |
| arch 매핑 | cputype `0x0100000C`(16777228): subtype 2=arm64e, 그 외 arm64; `0x01000007`: subtype 8=x86_64h, 그 외 x86_64; `7`=i386; 나머지 other | `:296-303` |
| 대상 파일 | arm64 슬라이스 정확히 1개 + Intel ≥1개, 그 외(arm64e·other 포함) 없음 | `:310-328` |
| 절단 | 슬라이스 출력은 `mktemp "$file.mole-slim.XXXXXX"`(배타 생성, 고정 접미사 금지) ← `tail -c +(off+1) | head -c size`(tail SIGPIPE 무시). 크기 일치 + thin arm64 확인(첫 8바이트 `CF FA ED FE 0C 00 00 01`) → 원 권한 `chmod` → `mv -f` | `:338-341`, `:530-556` |
| 재서명 | **없음** (슬라이스별 서명이므로 arm64 cdhash 유지) | `slim.md:128` |

### 4.4 교체 절차 (`slim_one_app`, `:592-715`)

| # | 단계 | 실패 시 |
|---|---|---|
| 1 | 화이트리스트 재로드, skip reason 재검사(running 포함), identity 재확인 | 원본 유지, 사유 기록 |
| 2 | 원본 `codesign --verify --deep --strict` (180s). 실패 메시지가 `detritus not allowed`이면 허용 플래그 | `code signature already invalid` |
| 3 | `mktemp -d $WORK/app.XXXX` + `ditto --clone <app> <stage>/<name>.app` | `copy failed` |
| 4 | detritus면 사본에만 `/usr/bin/xattr -rsd com.apple.FinderInfo`, `…ResourceFork` 후 사본 deep strict 재검증 | 폐기 |
| 5 | 계획 파일 각각 thin | `could not remove Intel code from X` |
| 6 | 사본 검증: 계획 파일 모두 thin arm64 → `codesign --verify --deep --strict` → Team ID 동일 → `spctl --assess --type execute` | 각 사유 |
| 7 | 화이트리스트 재로드·재검사, running 재검사 | |
| 8 | INT/TERM 보류 → `MOLE_DELETE_MODE=trash mole_delete(app, false, identity)` → `mv copy app` → 트랩 복원, 보류 신호 재발생 | Trash 실패: 사본 폐기 / mv 실패: "original is in the Trash, drag it back" |
| 9 | `REBUILT` 로그, 절감 바이트 합산 | |

### 4.5 외부 명령 (slim)
`/usr/sbin/sysctl`, `codesign -dv / --verify --deep --strict`, `spctl --assess --type execute`, `plutil`, `file -N -F`, `od`, `tail`, `head`, `stat`, `ditto --clone`, `/usr/bin/xattr -rsd`, `ps`, `find`, `mktemp`, `mv`, `chmod`.

---

## 5. Swift 포팅 노트

### 5.1 공통

| 주제 | 권장 | 주의 |
|---|---|---|
| 삭제 | file_ops 문서의 identity-pinned sink를 Swift로 단일 구현(`FileManager.trashItem` / `removeItem` + `stat` 기반 dev/inode 재확인) | 각 명령의 "계획 시 identity 기록 → 실행 직전 재확인" 패턴 유지 |
| 루트 실행 금지 | 앱은 사용자 권한으로 실행, 관리자 작업만 helper로 | |
| 타임아웃/취소 | `Task` + `withTaskCancellationHandler`, 외부 프로세스는 `Process` + 타임아웃 래퍼. "타임아웃=불확실(유지)" vs "취소=중단" 구분 유지 | 쉘 원본은 124/128+ 상태로 구분 |
| 병렬 | `TaskGroup` 동시성 상한(메타데이터 8–32, 보호 probe 4, refresh 4) | 결과는 입력 순서로 게시 |
| 확인 UI | SwiftUI 시트: 미리보기 = 유일한 확인. 키 입력 누수 방지 개념은 "스캔 중 클릭 무시"로 대체 | |
| 샌드박스 | **비샌드박스 + Developer ID 배포 필수** (`/Applications` 쓰기, `~/Library` 전체, `launchctl`, `lsregister`) | Full Disk Access 필요: `~/Library/Containers`, Mail Downloads, Safari 등 TCC 보호 경로 — 미허용 시 "권한 거부" 구분 처리 |

### 5.2 uninstall

| 원본 | Swift 대체 |
|---|---|
| `find -maxdepth 3 -iname '*.app'` | `FileManager.enumerator(at:includingPropertiesForKeys:options:[.skipsPackageDescendants])` + 깊이 제한, 숨김 비-.app 디렉터리 skip |
| `plutil -extract CFBundleIdentifier` | `Bundle(url:)?.bundleIdentifier` / `infoDictionary` (PlayCover flat 번들은 `Info.plist` 직접 `PropertyListSerialization`) |
| 표시 이름(lproj 탐색) | `FileManager.default.displayName(atPath:)` 가 기준값(규칙 문서가 검증 기준으로 명시). LaunchServices 지역 rename(TV→Videos)은 번들로 재현 불가. 번들 단위는 `Bundle.preferredLocalizations(from:forPreferences:)` + `localizedInfoDictionary` |
| `mdls kMDItemPhysicalSize / LastUsedDate` | `MDItemCreateWithURL` + `MDItemCopyAttribute(kMDItemLastUsedDate)`; 크기는 `URLResourceValues.totalFileAllocatedSize` 재귀 합(백그라운드) |
| `mdfind kMDItemCFBundleIdentifier` | `NSMetadataQuery` 또는 `LSCopyApplicationURLsForBundleIdentifier` / `NSWorkspace.urlsForApplications(withBundleIdentifier:)` (macOS 12+) |
| `pkgutil --pkgs/--files`, `lsbom` | `Process` 쉘아웃(공개 API 없음). 결과 캐시 |
| 실행 여부/종료 | `NSRunningApplication.runningApplications(withBundleIdentifier:)`, `.terminate()` → 타임아웃 후 `.forceTerminate()`. 시스템 프로세스·공유 런타임(Electron) 이름 기반 kill 금지 |
| 로그인 항목 | macOS 13+: `SMAppService`는 타 앱 항목 제어 불가 → 원본처럼 System Events AppleScript(`NSAppleScript`, Automation TCC 프롬프트) 또는 BTM은 "백그라운드 항목" 안내로 대체. 타임아웃=건너뜀 |
| `launchctl unload/bootout` | `Process("/bin/launchctl", ["bootout","gui/\(uid)/\(label)"])`; 시스템 데몬은 privileged helper |
| `lsregister -u/-gc` | `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister` 쉘아웃 (또는 `LSRegisterURL(url,false)` 역등록 불가 → 쉘아웃 유지) |
| Dock 항목 제거 | `com.apple.dock` 도메인 `persistent-apps` 편집(`CFPreferences`) + `killall Dock` |
| brew | `Process`로 `brew` (경로 `/opt/homebrew/bin/brew`, `/usr/local/bin/brew`), env 3종 설정, `--zap` 금지 |
| UUID 컨테이너 | `.com.apple.containermanagerd.metadata.plist`의 `MCMMetadataIdentifier` 읽기 (FDA 필요) |
| 관리자 권한 | `SMAppService.daemon` 기반 privileged helper(XPC) 또는 `AuthorizationExecuteWithPrivileges` 대체 불가 → helper 권장. CLI는 시스템 잔여물을 **삭제하지 않음**(review-only) — MVP도 동일하게 시작하면 helper 범위가 "앱 번들 삭제(부모 비쓰기)·brew sudo" 수준으로 축소 |
| 설정 참조 스캔 | Swift로 파일 읽기(≤1MB, `O_NOFOLLOW`, inode/mtime 전후 비교), 결과는 `파일:줄`만 |

**Gotchas**
- `mdls kMDItemDisplayName`은 번들 파일명을 반환 → 표시 이름으로 쓰지 말 것(#1520).
- 대소문자 무시 APFS: 경로 비교·`Containers` 경계 매칭·보호 glob의 대소문자 정책을 명확히(보호 목록은 대소문자 구분 + 양 표기 등재).
- bundle id는 reverse-DNS 검증 후에만 경로 조립(glob/`..` 주입 방지).
- 이름 기반 패턴은 일반 단어·짧은 이름·공유 루트·독립 CLI(`~/.claude` 등)·Steam 라이브러리 차단 목록 필수.
- 형제 설치(Xcode/Xcode-beta, `/Volumes` 사본, Setapp, Caskroom) 존재 시 bundle id 기반 잔여물·로그인 항목·kill 생략. 스캔 불완전 = 형제 존재로 간주.
- 실행 중 앱 번들 삭제는 macOS가 허용 → kill 실패는 경고일 뿐 실패 아님.
- containermanagerd가 비운 컨테이너 루트(provenance xattr) 잔존은 성공으로 간주, 컨테이너 전체 잔존은 실패.
- 시스템 확장(`/Library/SystemExtensions`)은 삭제 불가 → 경고만.
- 기본 Trash 모드에서 root 소유 앱도 부모 쓰기 가능하면 sudo 불필요.

### 5.3 purge

| 원본 | Swift 대체 |
|---|---|
| `find` 워크 + prune | `FileManager.enumerator` + `skipDescendants()`; dataless는 `URLResourceKey.ubiquitousItemDownloadingStatusKey` 또는 `stat.st_flags & SF_DATALESS`(0x40000000) 확인 후 skip |
| `CACHEDIR.TAG` | 첫 43바이트 `Signature: 8a477f597d28d172789f06886806bc55` 비교 |
| `git ls-files` | `Process` 쉘아웃. `/usr/bin/git` shim 직접 호출 금지 → `xcode-select -p`로 개발자 디렉터리의 실제 git, 없으면 unknown(보호) |
| `lsof -d cwd` | `proc_pidinfo(PROC_PIDVNODEPATHINFO)`로 각 PID cwd 조회(libproc) 또는 lsof 쉘아웃 |
| `pgrep -f` | `sysctl KERN_PROCARGS2`로 인자 확인 |
| 크기 | `totalFileAllocatedSize` 재귀, unknown 허용 |
| 설정 | `~/.config/mole/purge_paths` 호환 포맷 유지(또는 앱 설정으로 이관 + 가져오기) |

**Gotchas**: 산출물 이름 디렉터리를 컨테이너로 취급 금지(#1459), `bin`/`vendor`/`node_modules`/`DerivedData` 특수 보호, recent(7일)는 기본 미선택, iCloud/CloudStorage 경로는 다른 기기에서도 삭제됨 경고 + 무인 모드 제외, Git worktree 자체 삭제·"안전" 판정 금지, probe 실패는 보호(삭제 근거 아님).

### 5.4 installer

| 원본 | Swift 대체 |
|---|---|
| fd/find | `FileManager.enumerator`(depth 2, hidden 포함, symlink 미추적) |
| `zipinfo -1` | `Process("/usr/bin/zipinfo")` 또는 ZIP central directory 직접 파싱(처음 50 엔트리) |
| 출처 라벨 | 경로 접두 매핑 그대로 |

**Gotchas**: Mail Downloads·Telegram 등은 TCC/FDA 필요 → 권한 거부는 스캔 실패가 아니라 해당 폴더 skip. 계획 후 파일 크기·identity 변하면 skip. iCloud zip은 다운로드 유발 가능 → 타임아웃 skip.

### 5.5 slim

| 원본 | Swift 대체 |
|---|---|
| `od` fat 헤더 파싱 | `FileHandle` + `fat_header`/`fat_arch`/`fat_arch_64` (`<mach-o/fat.h>`, 빅엔디언 `OSSwapBigToHost*`) |
| `tail|head` 슬라이스 추출 | `FileHandle.seek(toOffset:)` + `read(upToCount:)`, `mkstemp`로 배타 생성 |
| thin 검증 | `MH_MAGIC_64`(0xFEEDFACF, LE) + `CPU_TYPE_ARM64` |
| CodeResources 파싱 | `PropertyListSerialization` → `files2` dict, 값이 dict이고 `cdhash` 키 있으면 c, 그 외 h |
| `codesign -dv` Team/Authority | `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation(kSecCSSigningInformation)` → `kSecCodeInfoTeamIdentifier`, `kSecCodeInfoCertificates` 첫 cert CN이 `Developer ID Application:` |
| `codesign --verify --deep --strict` | `SecStaticCodeCheckValidity(code, [kSecCSCheckAllArchitectures, kSecCSCheckNestedCode, kSecCSStrictValidate], nil)` — 원본의 "detritus" 문자열 분기는 `errSecCSUnsealedAppRoot`/`errSecCSResourceForkDetritus`류 OSStatus로 매핑 필요(검증 요) |
| `spctl --assess --type execute` | 공개 API 없음 → `Process("/usr/sbin/spctl")` 쉘아웃, exit 3만 거부로 해석 |
| `ditto --clone` | `copyfile(…, COPYFILE_CLONE)` 또는 `FileManager.copyItem`(APFS clone 자동) |
| `xattr -rsd` | 재귀 열거 + `removexattr(path, name, XATTR_NOFOLLOW)` |
| 실행 확인 | `NSRunningApplication` + `bundleURL` 비교 (원본은 `ps comm` 경로 접두) |
| Rosetta 선호 | `com.apple.LaunchServices` plist `LSArchitecturesForX86_64` 키 확인 |
| Apple Silicon | `sysctlbyname("hw.optional.arm64")` |
| 원자 교체 | Trash 이동 후 rename; 대안 `FileManager.replaceItemAt`은 원본을 Trash로 보내지 않음 → 원본 동작 유지 시 직접 구현, 교체 구간 취소 무시 |

**Gotchas**: `lipo` 사용 금지(CLT 설치 프롬프트), arm64e 포함 파일 skip, `Resources/` 및 hash2 봉인 파일 절대 수정 금지, 재서명 금지(Team ID·TCC·키체인 유지), App Store/root 소유 앱 제외(관리자 권한 요청 없음), Sparkle 델타 업데이트 실패→풀 다운로드로 Intel 복귀(사용자 안내), 앱 업데이트 시 원복됨.

### 5.6 privileged helper 필요 범위 요약

| 명령 | helper 필요 여부 |
|---|---|
| uninstall | 부모 비쓰기 위치의 앱 번들 삭제, permanent 모드의 타 소유 번들, 시스템 LaunchAgents/Daemons unload(원본 CLI는 사실상 미사용), brew cask의 sudo 훅 |
| purge / installer / slim | 불필요 |
