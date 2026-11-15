# 01. `mo clean` 포팅 스펙 (맥클린 / MacClean)

> 원본: Mole (GPL-3.0) `bin/clean.sh`, `lib/clean/{user,app_caches,apps,caches,system,brew,dev,snapshots,hints}.sh`.
> 줄 번호는 분석 시점 클론 기준(`파일:줄`). `~` = 실행 사용자 HOME. 경로 끝의 `/*`는 "디렉터리 자체는 남기고 자식만 삭제"를 의미한다.
> 표기: **sudo** = 관리자 권한 필요, **FDA** = Full Disk Access(TCC) 없으면 접근 거부 가능, **RO** = 삭제 없이 리뷰 행만 출력.

---

## 1. 전체 흐름

### 1.1 진입/플래그 (`bin/clean.sh:2155-2207`)

| 플래그 | 동작 |
|---|---|
| (없음) | 실제 정리. root(EUID 0)로 실행 시 즉시 거부(`clean.sh:10`) — 필요할 때만 sudo 요청 |
| `--dry-run`, `-n` | `DRY_RUN=true`, `MOLE_DRY_RUN=1`. 삭제 없이 후보를 ledger에 기록 → `~/.config/mole/clean-list.txt`로 게시 |
| `--external <path>` | 외장 볼륨 모드. `diskutil info -plist`로 `Internal=false` + 네트워크가 아닌 `BusProtocol` 검증 후 `.TemporaryItems`, `.DS_Store`, `._*`만 삭제 (`user.sh:1736-2057`) |
| `--whitelist` | `lib/manage/whitelist.sh`의 `manage_whitelist clean` 대화형 메뉴 후 종료 |
| `--debug` | `MO_DEBUG=1` (리스크 분류, 타이밍, 지연 항목 로그) |
| `--select/--categories/--exclude` | 제거된 옵션 → 에러 |
| env `MOLE_DRY_RUN=1` | dry-run과 동일 |

### 1.2 시작 단계 (`start_cleanup`, `clean.sh:1505-1593`)
1. 화이트리스트 로드: `~/.config/mole/whitelist` (없으면 `DEFAULT_WHITELIST_PATTERNS`, 항상 `SAFETY_WHITELIST_PATTERNS` 병합) — `base.sh:469`.
2. dry-run이면 preview 파일 준비 + 헤더 작성.
3. sudo 결정:
   - dry-run: 이미 캐시된 sudo 세션이 있으면(`adopt_sudo_session`) System 섹션 미리보기 포함, 아니면 생략 + "sudo -v 후 다시" 안내.
   - 실제 + TTY: 캐시된 세션 있으면 사용, 없으면 프롬프트 `System caches need sudo. Enter continue, Space skip` (`prompt_for_system_clean`, `clean.sh:557`). Enter→`ensure_sudo_session`, Space→스킵, ESC→종료, 문자 입력→그대로 비밀번호로 간주. 실패 시 user-level만 계속.
   - 비대화형: 캐시된 세션 있을 때만 System 수행.
4. `perform_cleanup` (`clean.sh:1595`): 초기 free space 측정(`get_free_space_kb`), 아키텍처/여유공간 출력, `check_tcc_permissions`(`caches.sh:35` — 최초 1회 `~/Library/{Caches,Logs,Application Support,Containers}`, `~/.cache`를 `find -maxdepth 1`로 건드려 TCC 다이얼로그 유도, 플래그 `~/.cache/mole/permissions_granted`), 화이트리스트 요약(`N core + M custom`), FDA 미보유 시 안내(`has_full_disk_access`).
5. 백그라운드 프리페치: `start_project_cache_prefetch`(프로젝트 캐시 스캔), legacy analyzer 캐시 sweep(`~/.cache/mole/*.cache`).

### 1.3 섹션 순서 (`run_clean_sections`, `clean.sh:1765-1890`)

| # | 섹션 헤더 | 호출 함수 | 비고 |
|---|---|---|---|
| 0 | External volume | `clean_external_volume_target` | `--external`일 때만, 나머지 전부 생략 |
| 1 | System | `clean_deep_system`, `clean_local_snapshots` | `SYSTEM_CLEAN=true`일 때만 |
| 2 | User essentials | `clean_user_essentials`, `clean_finder_metadata` | |
| 3 | App caches | `clean_app_caches` | |
| 4 | Browsers | `clean_browsers` | |
| 5 | Cloud & Office | `run_cloud_and_office_cleanup` → `clean_cloud_storage`, `clean_office_applications` | 섹션 예산 300s(`MOLE_CLOUD_OFFICE_SECTION_BUDGET_SEC`) |
| 6 | Developer tools | `clean_developer_tools` (`dev.sh:6278`) | 가장 큼 |
| 7 | Apps & utilities | `clean_user_gui_applications` (`app_caches.sh:2221`) | |
| 8 | Virtualization | `clean_virtualization_tools` (`user.sh:2514`) | |
| 9 | Application Support | `clean_application_support_logs` (`user.sh:2619`) | |
| 10 | App leftovers | `clean_orphaned_app_data`, `clean_orphaned_system_services`, `clean_orphaned_container_stubs`, `show_user_launch_agent_hint_notice` | |
| 11 | (헤더 없음) | `clean_apple_silicon_caches` | arm64만 |
| 12 | Device backups & firmware | `clean_cached_device_firmware` | |
| 13 | Time Machine | `clean_time_machine_failed_backups` | |
| 14 | Large files | `check_large_file_candidates` | **RO** 리뷰 전용 |
| 15 | Project artifacts | `show_project_artifact_hint_notice` | **RO** `mo purge` 안내 |

- 각 단계는 `_run_cleanup_step`으로 감싸짐: 일반 실패는 무시하고 진행, **timeout(124)/signal(≥128)** 이면 이후 섹션 전부 중단하고 요약으로 이동(`MOLE_CLEAN_CANCEL_STATUS` sticky).
- 섹션 출력 리듬: 제목 → 스피너 → 행 → 빈 줄. 아무 행도 없으면 "Nothing to clean"(TTY에서는 다음 섹션이 줄을 덮어씀).

### 1.4 사이즈/카운트 회계
- 전역 카운터: `total_size_cleaned`(KB), `files_cleaned`(항목 수), `total_items`(카테고리 수). `mole_add_cleaned_row`(`file_ops.sh:4143`).
- 크기 측정 `_cleanup_path_sizes_kb`(`clean.sh:754`): perl `File::Find` no-follow, 같은 디바이스만, **할당 블록×512**, APFS clone은 `getattrlist`의 private size(공유 블록 제외)로 보정, 하드링크는 모든 링크가 대상 안에 있을 때만 계산. 타임아웃 30s(`MOLE_TIMEOUT_DISK_VERIFY_SEC`). 타임아웃 시 "partial" 표시(`X+`).
- 0B 행은 삭제·카운트는 하되 출력 안 함. 같은 라벨의 여러 루트는 한 행으로 합침.
- 요약 박스(`clean.sh:1894-2110`): 실제 = `Removed: X · N items` + `Free space: Y (+Δ)`; dry-run = `Potential space: X · N items` + `Detailed file list: ~/.config/mole/clean-list.txt`. 취소 시 `Cleanup cancelled/interrupted/incomplete`.
- 실행 중 앱 때문에 미룬 캐시(`DEFERRED_CLEANUP_FAMILIES`)는 요약에 표시하지 않음(debug 로그만).
- 운영 로그: `log_operation clean REMOVED/SKIPPED <path> <reason>` (세션 start/end 포함).

### 1.5 단일 타깃 삭제 파이프라인 `safe_clean` → `_safe_clean_impl` (`clean.sh:856-1490`)
인자: `safe_clean <path...> "<label>"` (마지막 인자가 라벨). `safe_clean_guarded <guard_fn> ...`는 각 타깃마다 guard 재확인.
1. 존재하지 않는 경로 제거(`-e || -L`).
2. 필터: `should_protect_path` → `is_path_whitelisted` → `holds_compiled_model_cache`(`com.apple.e5rt.e5bundlecache` 포함 여부) — 해당 시 SKIPPED 로그.
3. `normalize_paths_for_cleanup`: 중첩 경로 제거(부모가 있으면 자식 제외), Gradle DSL 경로 정규화.
4. 섹션 데드라인/취소 확인.
5. 각 경로: 크기 측정 → dry-run이면 ledger 기록, 아니면 `safe_remove path silent size deadline ...`.
6. guard가 "이 경로만 거부"(`_MOLE_SAFE_CLEAN_SKIP_PATH`)면 그 타깃만 건너뛰고 계속, 그 외 non-zero는 75로 중단.

### 1.6 실제 삭제 sink
| 함수 | 위치 | 동작 |
|---|---|---|
| `safe_remove` | `file_ops.sh:1473` | `validate_path_for_deletion` → 화이트리스트 재확인 → compiled-model 재확인 → (dry-run이면 기록 후 return) → 부모/타깃 identity(dev:ino) 재바인딩 → 선택적 final guard(`_MOLE_SAFE_REMOVE_FINAL_GUARD`) → **`rm -rf`** (timeout 30s). **휴지통 아님, 영구 삭제** |
| `safe_sudo_remove` | `file_ops.sh:2004` | 동일 정책 + `sudo -n rm -rf`, 가변(사용자 쓰기 가능) 조상 거부 |
| `safe_find_delete` | `file_ops.sh:3447` | `find <dir> -name <pat> -type f -mtime +N` 결과를 `safe_remove` |
| `safe_sudo_find_delete` | `file_ops.sh:3578` | sudo find + 배치 삭제(`maxdepth` 인자), 결과 수는 `MOLE_SAFE_SUDO_FIND_DELETE_COUNT` |
| owner command | `clean_tool_cache` (`dev.sh:51`) | 툴 자체 명령(`npm cache clean` 등) 실행, 루트 전후 크기 차이만 "제거됨"으로 집계 |

`mole_delete`/`MOLE_DELETE_MODE=trash`는 uninstall 전용. **clean은 항상 영구 삭제**(유일한 예외: Trash 비우기 자체).

---

## 2. 정리 대상 카탈로그

열: **경로/패턴 | 설명 | 조건·가드 | sudo | 외부 명령 | 소스**. 공통 가드(보호경로/화이트리스트/compiled-model/validate)는 모든 `safe_clean`/`safe_remove` 행에 암묵 적용되므로 생략. "앱 미실행"은 `pgrep` 기반 3-상태(0=실행, 1=미실행, 2=모름) 프로브이며 **실행 중이면 조용히 defer, 모름이면 경고 후 스킵**.

### 2.0 External volume (`--external`)
| 경로 | 설명 | 조건 | sudo | 외부 명령 | 소스 |
|---|---|---|---|---|---|
| `<vol>/.TemporaryItems` | 임시 스테이징 | 볼륨 identity 재확인(`_mole_external_volume_final_guard`), 읽기 불가 시 스킵 | N | `diskutil info -plist`, `find -P -xdev` | `user.sh:1856-2057` |
| `<vol>/**/.DS_Store`, `<vol>/**/._*` | Finder/AppleDouble 메타데이터 | `.Trashes` prune, `FINDER_METADATA` 화이트리스트 시 전부 스킵 | N | `find` | 〃 |

### 2.1 System (sudo 필요, 전체 예산 120s — `system.sh:267`)
| 경로/패턴 | 설명 | 조건 | sudo | 외부 명령 | 소스 |
|---|---|---|---|---|---|
| `/Library/Caches/**/*.cache`, `*.tmp` (+`*.log`) | 시스템 캐시 파일 | mtime > 7일(`MOLE_TEMP_FILE_AGE_DAYS`), maxdepth 5, 파일만 | Y | `sudo find` | `system.sh:281-297` |
| `/Library/Logs/DiagnosticReports/*` | 시스템 크래시 리포트 | > 7일, depth 1 | Y | | `system.sh:324` |
| `/private/var/log/**/*.log, *.gz, *.asl` | 시스템 로그 | > 7일, depth 3 | Y | | `system.sh:346` |
| `/Library/Logs/Adobe/*`, `/Library/Logs/CreativeCloud/*`, `/Library/Logs/adobegc.log` | 서드파티 시스템 로그 | > 7일 | Y | | `system.sh:369-401` |
| `/Library/Updates`, `/macOS Install Data` | — | **유지**(Software Update 관리) | — | | `system.sh:427-432` |
| `/Applications/Install macOS*.app` | 구버전 macOS 설치 앱 | mtime ≥14일, `DTPlatformVersion` 메이저 ≠ 현재(`sw_vers`), Apple 서명(`codesign --verify`+`CFBundleIdentifier`), 실행 중 아님(`pgrep -f`), SoftwareUpdate 대기 없음(`com.apple.SoftwareUpdate.plist`), identity 불변(전후 재검사) | Y | `sw_vers`, `PlistBuddy`, `plutil`, `codesign`, `pgrep` | `system.sh:150-560` |
| `/Library/Caches/com.apple.iconservices.store` | 아이콘 서비스 캐시 | 존재 확인(sudo test) | Y | | `system.sh:584-609` |
| `/private/var/folders/*/*/C/**/com.apple.{gpuarchiver,metal,metalfe}` | GPU/Metal 셰이더 캐시 | 최근 1일 내 수정 파일 없음(`MOLE_GPU_CACHE_AGE_DAYS=1`), find maxdepth 8, `T/` prune | Y(삭제) | `find` | `system.sh:9-56, 640-700` |
| `/private/var/folders/**/T/**/com.apple.idleassetsd/CFNetworkDownload_*.tmp` | 배경화면(에어리얼) 다운로드 잔여 | > 7일 | Y | `sudo find` | `system.sh:728-760` |
| `/private/var/db/diagnostics/**` | 통합 로그 저장소 | > 7일, depth 5 | Y | | `system.sh:779-786` |
| `/private/var/db/DiagnosticPipeline/**` | 진단 파이프라인 | > 7일 | Y | | `system.sh:801` |
| `/private/var/db/powerlog/**` | 전원 로그 | > 7일, **활성 DB 거부**(`_mole_is_active_powerlog_database_path`); 큰 활성 DB는 안내만 | Y | | `system.sh:827, 88` |
| `/private/var/db/reportmemoryexception/MemoryLimitViolations/**` | 메모리 예외 리포트 | > 30일 | Y | `sudo find -exec stat` | `system.sh:851-890` |
| `tmutil listlocalsnapshots /` | APFS/TM 로컬 스냅샷 | **RO**: TM 스냅샷 개수(AutoBackup 설정 있고 백업 중 아닐 때)·서드파티 스냅샷 소유자만 표시, **삭제 안 함** | N | `tmutil`, `defaults read` | `system.sh:1430`, `snapshots.sh` |

### 2.2 User essentials
| 경로/패턴 | 설명 | 조건 | sudo | 외부 | 소스 |
|---|---|---|---|---|---|
| `~/Library/Caches/*` (모든 자식) | **사용자 캐시 일괄 스윕** | 제외: `Google`(Chrome 라이브 캐시), `DENO_DIR`(또는 그 물리 경로)를 포함하는 항목. `DENO_DIR` 해석 실패 시 스윕 전체 중단. guard가 sink 직전 재확인. SAFETY 화이트리스트(FontRegistry, Spotlight, CloudKit, kitty, pypoetry/virtualenvs, renv, pnpm/dlx, llama.cpp)와 protect 목록(ms-playwright, Cypress, Adobe, containermanagerd, homed, HomeKit, FamilyCircle 등) 자동 제외. 라이브 SQLite/프로세스 소유 캐시는 validate에서 거부(`live user cache`) | N | `lsof`(SQLite 핸들) | `user.sh:267-330` |
| `~/Library/Logs/*` | 사용자 앱 로그 | **나이 제한 없음**. `DiagnosticReports` 디렉터리 자체는 유지하고 내부만. 조상 symlink 거부, root identity 바인딩 후 sink 재확인. `~/Library/Logs/mole` 보호 | N | | `user.sh:224-262, 332` |
| `~/.Trash/*` | 휴지통 비우기 | 화이트리스트에 `~/.Trash` 있으면 전체 스킵. `ls` 실패 → "FDA 필요" 경고. 항목별 `safe_remove` | N | | `user.sh:42-173` |
| `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.Recent{Applications,Documents,Servers,Hosts}.sfl{,2}` | 최근 항목 목록 | — | N | | `user.sh:345-362` |
| `~/Library/Preferences/com.apple.recentitems.plist` | 최근 항목 설정 | — | N | | `user.sh:362` |
| `~/Library/Mail Downloads/*/<file>`, `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*/<file>` | Mail 첨부 사본 | Mail 미실행, 폴더 birth > 30일(`MOLE_MAIL_AGE_DAYS`), 파일이 "손대지 않은 사본"(f_mtime ≤ f_birth+2s, 폴더 mtime ≤ birth+2s), nlink 1, 조상 symlink 없음 | N | `stat` | `user.sh:442-600` |
| `~/**/.DS_Store` | Finder 메타데이터 | HOME 기준 maxdepth 5, prune: `MobileSync`, `Library/Developer`, `.Trash`, `node_modules`, `.git`, `Library/Caches`. `FINDER_METADATA` 화이트리스트(기본 SAFETY 포함) 시 **스킵 → 기본적으로 비활성** | N | `find -P` (15s) | `user.sh:1063`, `apps.sh:9-110` |

### 2.3 App caches (`clean_app_caches`, `user.sh:1250-1367`)
| 경로/패턴 | 설명 | 조건 | sudo | 소스 |
|---|---|---|---|---|
| `~/Library/Saved Application State/*` | 창 복원 상태 | 나이 제한 없음 | N | `user.sh:1257` |
| `~/Library/Caches/com.apple.photoanalysisd`, `com.apple.akd`, `com.apple.WebKit.Networking/*`, `com.apple.QuickLook.thumbnailcache`, `Quick Look/*`, `com.apple.iconservices*` | Apple 시스템 사용자 캐시 | — | N | `user.sh:1258-1264` |
| `~/Library/DiagnosticReports/*` | 사용자 진단 리포트 | 로그 디렉터리 guard 동일 | N | `user.sh:1261` |
| `~/Downloads/*.download`, `*.crdownload`, `*.part` | 미완료 다운로드 | 열린 핸들 없음(`lsof`), 프로브 불가 시 스킵, sink에서 identity 재확인 | N | `user.sh:365-440` |
| `~/Library/IdentityCaches/*`, `~/Library/Suggestions/*`, `~/Library/Application Support/AddressBook/Sources/*/Photos.cache` | ID/Siri/연락처 사진 캐시 | — | N | `user.sh:1268-1274` |
| `~/Library/Application Support/CrashReporter/*` | 크래시 리포터 | 파일 > 30일 (`safe_find_delete`) | N | `user.sh:1071-1080` |
| `~/Library/Messages/StickerCache/*`, `Messages/Caches/Previews/Attachments/*`, `Messages/Caches/Previews/StickerCache/*` | Messages 캐시 | **FDA 필요** | N | `user.sh:1090-1092` |
| `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/**/*.bmp` | 배경화면 렌더 | 폴더별 최신 렌더 유지, 나머지(stale)만 | N | `user.sh:1165-1245` |
| `~/Library/Containers/com.apple.{mediaanalysisd,AppStore,stocks,AvatarUI.AvatarPickerMemojiPicker,AMPArtworkAgent,CoreDevice.CoreDeviceService,NeptuneOneExtension}/Data/Library/Caches/*` | Apple 컨테이너 캐시 | — | N | `user.sh:1286-1303` |
| `~/Library/Containers/com.apple.{mediaanalysisd,configurator.xpc.InternetService,wallpaper.extension.aerials,geod,AppleMediaServicesUI.UtilityExtension}/Data/tmp/*` | Apple 컨테이너 tmp | — | N | 〃 |
| `~/Library/Caches/com.apple.{helpd,AppleMediaServices,duetexpertd,parsecd,python}/*`, `~/Library/Caches/GeoServices/*` | 도움말/Maps/기타 | — | N | `user.sh:1298-1308` |
| `~/Library/Containers/<bundle>/Data/Library/Caches/*` (모든 샌드박스 앱) | **샌드박스 앱 캐시 일괄** | 제외: symlink, `is_critical_system_component`, `should_protect_data(bundle)`(com.apple.*, 비밀번호관리자, 입력기 등). 항목 >100개면 크기 미측정, 정밀 측정 최대 64개 | N | `user.sh:1312-1518` |
| `~/Library/Group Containers/<id>/{Logs,Library/Logs}/*` 및 (보호되지 않으면) `{tmp,Library/tmp,Caches,Library/Caches}/*` | 그룹 컨테이너 캐시/로그 | 제외: `com.apple.*`, `group.com.apple.*`, `systemgroup.com.apple.*`, 같은 id의 Container에 `*Safari*` 확장이 있으면 스킵. 보호 데이터면 Logs만 | N | `user.sh:1520-1716` |
| `~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/*` | Handoff 클립보드 | 60분 이상(`-mmin +60`) | N | `user.sh:1369-1420` |

### 2.4 Browsers (`clean_browsers`, `user.sh:2059-2310`)
공통: Chromium 계열 프로필 캐시 리프 = `Application Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `GrShaderCache`, `GraphiteDawnCache`, (`DawnGraphiteCache`, `DawnWebGPUCache`, `GPUPersistentCache`), 루트의 `ShaderCache`, `GrShaderCache`, `GraphiteDawnCache`, `component_crx_cache`, `extensions_crx_cache`, `Crashpad/completed`. **브라우저 실행 중이면 전부 defer**.

| 브라우저 | 경로 | 조건 | 소스 |
|---|---|---|---|
| Safari | `~/Library/Caches/com.apple.Safari/*` | 가드 없음 | `user.sh:2062` |
| Chrome | `~/Library/Caches/Google/Chrome/*`; `~/Library/Application Support/Google/Chrome/*/{Application Cache,Code Cache,GPUCache,DawnCache,GrShaderCache,GraphiteDawnCache}/*`; 루트 `component_crx_cache, ShaderCache, GrShaderCache, GraphiteDawnCache, Crashpad/completed, OptGuideOnDeviceModel, OptGuideOnDeviceClassifierModel, optimization_guide_model_store` /* | Chrome 미실행 | `user.sh:838-866, 2066-2108` |
| Chrome Service Worker | `<profile>/Service Worker/CacheStorage/<origin-hash>/*` | Chrome 미실행, `PROTECTED_SW_DOMAINS`(capcut, photopea, pixlr, docs/sheets/slides/drive/mail.google.com, github, gitlab, codepen, codesandbox, replit, stackblitz, notion.so, figma, linear.app, excalidraw) 도메인 매칭 스킵, symlink 루트 거부 | `caches.sh:74-230`, `clean.sh:53-75` |
| GoogleUpdater | `~/Library/Application Support/Google/GoogleUpdater/crx_cache/*`, `GoogleUpdater/*.old` | — | `user.sh:2109-2110` |
| Chromium / Puppeteer / Edge | `~/Library/Caches/Chromium/*`, `~/.cache/puppeteer/*`, `~/Library/Caches/com.microsoft.edgemac/*` | — | `user.sh:2111-2113` |
| Arc | `~/Library/Caches/company.thebrowser.Browser/*`; `~/Library/Application Support/Arc/{*,User Data/*}/<leaves>/*`, 루트 leaves, Service Worker | Arc 미실행 | `user.sh:2114-2150` |
| Dia | `~/Library/Caches/company.thebrowser.dia/*`; `~/Library/Caches/Dia/User Data/*/{Cache,Code Cache}/*`; `~/Library/Application Support/Dia/User Data/...` leaves | Dia 미실행 | `user.sh:2155-2186` |
| Brave | `~/Library/Caches/BraveSoftware/Brave-Browser/*`; `~/Library/Application Support/BraveSoftware/Brave-Browser/...` leaves, SW | Brave 미실행 | `user.sh:2188-2212` |
| Helium | `~/Library/Caches/net.imput.helium/*`; `Application Support/net.imput.helium/...` | 디렉터리 존재 시 | `user.sh:2214-2221` |
| Yandex | `~/Library/Caches/Yandex/YandexBrowser/*`; `Application Support/Yandex/YandexBrowser/{ShaderCache,GrShaderCache,GraphiteDawnCache,*/GPUCache}/*` | — | `user.sh:2225-2229` |
| Firefox | `~/Library/Caches/Firefox/*`, `~/Library/Application Support/Firefox/Profiles/*/cache2/*` | Firefox 미실행 | `user.sh:869-874, 2230-2246` |
| Opera, Comet, Orion, Zen | `~/Library/Caches/{com.operasoftware.Opera,Comet,com.kagi.kagimacOS,zen}/*` | — | `user.sh:2247-2271` |
| Vivaldi | `~/Library/Caches/com.vivaldi.Vivaldi/*`, `Application Support/Vivaldi/...` | 미실행 | `user.sh:2248-2267` |
| QQ Browser | `~/Library/Caches/com.tencent.QQBrowser3/*`, `Application Support/QQBrowser3/...` | 미실행 | `user.sh:2276-2290` |
| BrowserOS | `~/Library/Caches/BrowserOS/*/{Cache,Code Cache}/*`, `Application Support/BrowserOS/...` | 미실행 | `user.sh:2291-2308` |
| Chrome 구버전 | `/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/<v>` (+`~/Applications`) | `Current` symlink 대상과 그보다 최신(staged update) 1개 유지, Chrome 미실행(3회 재확인) | sudo 세션 있으면 `safe_sudo_remove`, 아니면 `safe_remove` | `user.sh:605-778, 884` |
| Edge 구버전 | `.../Microsoft Edge Framework.framework/Versions/<v>` | 동일 | 〃 | `user.sh:900` |
| Brave 구버전 | `.../Brave Browser Framework.framework/Versions/<v>` | 동일 | 〃 | `user.sh:1047` |
| Edge Updater | `~/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable/<v>` | 설치된 Edge 버전보다 **엄격히 낮은** 것만(읽기 실패 시 `sort -V` 최신 유지), sudo 미사용 | N | `user.sh:916-1045` |

### 2.5 Cloud & Office (`user.sh:2312-2399`)
| 경로 | 조건 | 소스 |
|---|---|---|
| `~/Library/Caches/com.getdropbox.dropbox`, `~/Library/Caches/com.dropbox.*` | Dropbox 미실행 | `user.sh:2315-2330` |
| `~/Library/Caches/com.google.GoogleDrive` | Google Drive 미실행 | `user.sh:2333-2347` |
| `~/Library/Caches/{com.baidu.netdisk,com.alibaba.teambitiondisk,com.box.desktop}` | — | `user.sh:2349-2351` |
| `~/Library/Caches/com.microsoft.OneDrive` | OneDrive 미실행 | `user.sh:2353-2367` |
| `~/Library/Caches/com.microsoft.{Word,Excel,Powerpoint}`, `com.microsoft.Outlook/*` | — | `user.sh:2378-2393` |
| `~/Library/Containers/com.microsoft.{Word,Excel}/Data/{Library/Caches,tmp,Library/Logs}/*` | (Office 컨테이너 로그는 데이터 보호 정책으로 차단될 수 있음) | `user.sh:2382-2391` |
| `~/Library/Caches/{com.apple.iWork.*,com.kingsoft.wpsoffice.mac,org.mozilla.thunderbird/*,com.apple.mail/*}` | — | `user.sh:2394-2397` |

### 2.6 Developer tools (`clean_developer_tools`, `dev.sh:6278-6328`)
실행 순서대로. **OC** = owner command(`clean_tool_cache`: 루트 절대경로 확인→`owner_cache_root_is_safe`(화이트리스트/보호/물리경로)→전후 크기 측정→명령 실행, timeout은 해당 항목만 스킵, signal은 전체 취소, 직접 삭제로 폴백하지 않음).

#### 2.6.1 JS/Node (`clean_dev_npm`, `dev.sh:663-725`)
| 경로 | 설명 | 조건 | 외부 명령 | 소스 |
|---|---|---|---|---|
| `$(npm config get cache)` | npm 캐시 | 절대·단일행 경로 확인 시 OC | `npm cache clean --force` (20s) | `dev.sh:664-676` |
| `~/.npm/{_cacache,_logs,_prebuilds}/*` (+커스텀 경로 동일) | npm 잔여 | — | | `dev.sh:681-707` |
| pnpm store (`pnpm store path`, 각 설치된 pnpm 바이너리별) | pnpm 스토어 | pnpm 프로세스 없음, 안전 경로 | `pnpm store prune` (OC) | `dev.sh:459-612` |
| `~/Library/Caches/pnpm/metadata*/*` | pnpm 메타데이터 | — | | `dev.sh:713` |
| `${COREPACK_HOME:-~/.cache/node/corepack}` | Corepack | corepack 사용 가능 시 OC, 아니면 `/*` 직접 | `corepack cache clean` | `dev.sh:161-181` |
| `$(bun pm cache)` / `~/.bun/install/cache/*` | Bun | bun/bunx 미실행(명령 직전 재확인), 루트 `/` 거부. bun 사용 불가 시 프로세스 없을 때만 직접 삭제 | `bun pm cache rm` | `dev.sh:614-661` |
| `~/.tnpm/{_cacache,_logs}/*` | tnpm | — | | `dev.sh:718-719` |
| `~/Library/Caches/Yarn/*` | Yarn v1 | `~/.yarn/berry/cache`는 **절대 비대상**(PnP 의존성) | | `dev.sh:723` |

#### 2.6.2 Python (`clean_dev_python`, `dev.sh:946-979`)
| 경로 | 조건 | 외부 명령 | 소스 |
|---|---|---|---|
| `$(pip3 cache dir)` | 절대경로 확인 | `pip3 cache purge` (OC) | `dev.sh:948-954` |
| `~/.pyenv/cache/*`, `~/.cache/poetry/*`, `~/Library/Caches/pypoetry/{artifacts,cache}/*` | `pypoetry/virtualenvs` 보호 | | `dev.sh:956-966` |
| `$(uv cache dir)` / `~/.cache/uv/*` | uv/uvx 미실행; uv 없으면 프로세스 없을 때만 직접 | `uv cache prune` (`UV_LOCK_TIMEOUT=3`) | `dev.sh:204-222` |
| `~/.cache/{ruff,mypy}/*`, `~/.pytest_cache/*` | — | | `dev.sh:968-970` |
| `~/Library/Application Support/pyinstaller/bincache*` | PyInstaller 빌드 프로세스 없음 | | `dev.sh:881-902` |
| conda `pkgs_dirs` (`~/.conda/pkgs`, `~/{ana,mini}conda3/pkgs`, `~/miniforge3/pkgs`, `~/mambaforge/pkgs`) | `conda info --json`의 모든 루트 검증, 하나라도 화이트리스트면 전체 스킵 | `conda clean --yes --index-cache --tarballs --logfiles` (OC, 30s) | `dev.sh:381-448` |
| **비대상** | `~/.jupyter/runtime`, `~/.cache/{huggingface,torch,tensorflow,wandb}` | | `dev.sh:972-977` |

#### 2.6.3 Go / mise / Rust / Ruby / Perl
| 경로 | 조건 | 외부 명령 | 소스 |
|---|---|---|---|
| `$(go env GOMODCACHE)` | go/gopls 미실행, 루트가 `/`, HOME, `~/Library`, `~/Library/Caches`, `~/.cache`, `~/go` 자체면 거부, `go env` timeout 시 스킵 | `go clean -modcache` (dry-run은 `-n`) | `dev.sh:981-1250` |
| `$(go env GOCACHE)` | 동일 | `go clean -cache` | 〃 |
| `$(mise cache path)` 또는 `$MISE_CACHE_DIR` / `~/Library/Caches/mise` | 절대경로 확인 시 OC, 아니면 `/*` | `mise cache clear` | `dev.sh:1252-1292` |
| `${CARGO_HOME:-~/.cargo}/registry/cache/*` | cargo/rustc 빌드 프로세스 없음, CARGO_HOME 내부 검증 | | `dev.sh:1381-1438` |
| `${RUSTUP_HOME:-~/.rustup}/downloads/*` | — | | `dev.sh:1440` |
| `~/.rustup/toolchains` | **RO**: 기본 외 툴체인 버전 수 리뷰 | | `dev.sh:1501-1521` |
| `~/.rbenv/cache/*`, `~/.gem/specs/*`, `~/.gem/ruby/*/cache/*.gem`, `~/.bundle/cache/*` | — | | `dev.sh:1443-1447` |
| `~/.cpan/build/*` | `~/.cpan/sources` 유지 | | `dev.sh:1450-1454` |
| **비대상** | Cargo `registry/src`, `git`, `$DENO_DIR`, `~/.m2/repository`, `~/.ivy2/cache`, `~/.nuget/packages`, `~/.cabal/packages`, `~/.sbt/{boot,launchers}`, `~/.stack/programs` | | rule `clean-dev.md` |

#### 2.6.4 Docker / Cloud / Nix / Shell / Frontend
| 경로 | 조건 | 외부 명령 | 소스 |
|---|---|---|---|
| Docker 빌드 캐시 | 엔드포인트가 로컬 `unix://`(`docker context inspect`), `docker info` 응답(엔진 기동 안 함), `~/Library/Containers/com.docker.docker/Data` 미화이트리스트 | `env BUILDX_BUILDER=$(docker context show) docker builder prune -f --filter until=168h` | `dev.sh:1563-1670` |
| Docker dangling 이미지 | 동일 | `docker image prune -f` (컨테이너/볼륨/네트워크/태그 이미지 미변경) | 〃 |
| OrbStack `~/Library/Group Containers/*dev.orbstack/data` | **RO** 크기만 표시 | | `dev.sh:1675-1690` |
| `~/.docker/buildx/cache/*` | — | | `dev.sh:1692` |
| GitHub CLI `${XDG_CACHE_HOME:-~/.cache}/gh` | gh 미실행, XDG 경로 검증 | `gh config clear-cache` | `dev.sh:224-379` |
| `~/.kube/cache/*`, `~/.local/share/containers/storage/tmp/*`, `~/.aws/cli/cache/*`, `~/.config/gcloud/logs/*`, `~/.azure/logs/*` | — | | `dev.sh:1704-1711` |
| `/nix/store` | GC root 미참조 경로만(세대 삭제 안 함) | `nix-store --gc` (OC, 크기 측정 안 함) | `dev.sh:1699-1702` |
| `~/.oh-my-zsh/cache/*`, `~/.cache/pre-commit/*` | — | | `dev.sh:6217-6222` |
| `~/.cache/{typescript,electron,node-gyp,vite,webpack,eslint,prettier}/*`, `~/.node-gyp/*`, `~/.turbo/cache/*`, `~/.vite/cache/*`, `~/.parcel-cache/*` | — | | `dev.sh:1713-1725` |

#### 2.6.5 프로젝트 캐시 (`clean_project_caches`, `caches.sh:1022`)
| 대상 | 탐색 루트 | 조건 | 외부 | 소스 |
|---|---|---|---|---|
| `<proj>/.next/cache/*` | `~/{www,dev,Projects,GitHub,Code,Workspace,Repos,Development,Developer}`, `~/Library/CloudStorage`, `~/.codex/worktrees`, `~/.claude/worktrees`, `~/.t3/worktrees` (`purge_shared.sh:55`) | find maxdepth 9, `-mount`, prune(`Library, .Trash, node_modules, .git, .venv, venv, target, .build, .gradle, DerivedData, Pods, *conda*, site-packages, ...`), 스캔 6s/루트. **Git 추적 파일 포함 시 제외**(`git ls-files` 인덱스 + sink 재확인), 중첩 repo 제외 | `find`, `git` | `caches.sh:398-905` |
| `**/__pycache__` (`.pyc/.pyo` 존재 시) | 동일 | 프로젝트 단위 그룹 삭제, 추적 파일 제외 | | `caches.sh:348, 907` |
| `<flutter>/.dart_tool`, 형제 `build/` | 동일 | 추적 파일 없음, `build/`는 중첩 repo 없음 | | `caches.sh:877-897` |

#### 2.6.6 모바일 / Xcode (`clean_dev_mobile`, `dev.sh:2991-3271`; `clean_xcode_tools`, `app_caches.sh:399-553`)
| 경로 | 설명 | 조건 | sudo | 외부 명령 | 소스 |
|---|---|---|---|---|---|
| `~/Library/Android/sdk/ndk/*` | **RO** 다중 버전 리뷰 | | N | | `dev.sh:1727` |
| `/Library/Developer/Xcode/DocumentationCache/DeveloperDocumentation*.index` | 문서 인덱스 | 최신(mtime) 1개 유지, Xcode/빌드툴 미실행, `SYSTEM_CLEAN` 필요 | **Y** | | `dev.sh:1736-1915` |
| `/Library/Developer/CoreSimulator/Caches/*` | 시스템 시뮬레이터 캐시 | Simulator/CoreSimulator 비활성(부팅 기기 없음 포함) | **Y** | `xcrun simctl list` | `dev.sh:2179-2368` |
| `~/Library/Developer/XCTestDevices` (전체) | XCTest 기기 | 시뮬레이터 비활성 | N | | `dev.sh:2124-2177` |
| 사용 불가 시뮬레이터 | `xcrun simctl list devices unavailable` | Xcode first-launch 완료(`xcodebuild -checkFirstLaunchStatus`), DEVELOPER_DIR 해석 성공(여러 Xcode면 중단) | N | `xcrun simctl delete unavailable` | `dev.sh:2697-2826, 2997-3220` |
| 고아 시뮬레이터 런타임 | **RO** `simctl runtime list -j`/`list devices -j`를 `runtimeIdentifier`로 조인, Ready+deletable+이미지 1개 | | N | `xcrun simctl runtime ...` | `dev.sh:2887-2989` |
| `~/Library/Developer/Xcode/{iOS,macOS,watchOS,tvOS,visionOS,xrOS} DeviceSupport/<ver>` | 디바이스 지원 심볼 | 최신 2개 유지(`MOLE_XCODE_DEVICE_SUPPORT_KEEP=2`, mtime 순), 나머지 버전 디렉터리 삭제 + 남은 버전의 `*/Symbols/System/Library/Caches/*`, `*.log` | N | | `dev.sh:2370-2675, 3233-3238` |
| `~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/*` | 런타임 캐시 | 시뮬레이터 비활성 | N | | `dev.sh:3245-3249` |
| `~/Library/Caches/Google/AndroidStudio*/*`, `~/.android/{build-cache,cache}/*` | Android | — | N | | `dev.sh:3250-3254` |
| `~/Library/Developer/Xcode/UserData/IB Support/*` | IB 캐시 | Xcode 미실행 | N | | `dev.sh:3255-3259` |
| `~/.cache/swift-package-manager/*`, `~/Library/Caches/org.swift.swiftpm/*` | SwiftPM | — | N | | `dev.sh:3260-3261` |
| `~/.expo/{expo-go,android-apk-cache,ios-simulator-app-cache,native-modules-cache,schema-cache,template-cache,versions-cache}/*` | Expo (`state.json` 유지) | — | N | | `dev.sh:3263-3269` |
| `~/Library/Developer/CoreSimulator/Caches/*`, `Devices/*/data/tmp/*`, `~/Library/Logs/CoreSimulator/*` | 시뮬레이터 캐시/tmp/로그 | Simulator 미실행 | N | | `app_caches.sh:410-460` |
| `Devices/<udid>/{data/private/var/MobileAsset/AssetsV2, data/var/db/diagnostics, data/var/db/uuidtext, data/Library/Caches, data/Library/Application Support/PRBPosterExtensionDataStore}` | 기기별 리프(통째로) | `device.plist`를 `plutil -convert xml1`로 읽어 `state`==정수 1 & `isDeleted` 없음/false; sink 직전 재확인; `data/Containers` **절대 비대상** | N | `plutil` | `app_caches.sh:60-176` |
| `~/Library/Caches/com.apple.dt.Xcode/*` | Xcode 캐시 | Xcode/빌드툴 미실행 | N | | `app_caches.sh:475-500` |
| `~/Library/Developer/Xcode/Products/*` | 빌드 산출물 | 동일 | N | | `app_caches.sh:501-525` |
| `~/Library/Developer/Xcode/DerivedData/<project>` | DerivedData (프로젝트 디렉터리 단위) | 동일, **나이 제한 없음** | N | | `app_caches.sh:215-397` |
| **비대상** | CoreSimulator `Volumes`, `Cryptex`; `Xcode/Archives`(Large files RO만) | | | | rule |

#### 2.6.7 JVM / JetBrains
| 경로 | 조건 | 소스 |
|---|---|---|
| `~/.gradle/{notifications,daemon,workers}/*`(dot 제외), `~/.gradle/caches/build-cache-*/*` | Gradle 데몬 미실행. **기본 화이트리스트가 `~/.gradle/caches/*`, `~/.gradle/daemon/*`를 보호** | `dev.sh:3273-3396` |
| `~/Library/Application Support/JetBrains/Toolbox/apps/<product>/ch-*/<version>` | 채널당 최신 1개(`MOLE_JETBRAINS_TOOLBOX_KEEP=1`) 유지 | `dev.sh:3398-3503` |
| `~/Library/Logs/JetBrains/*` | — | `dev.sh:3505` |

#### 2.6.8 AI 에이전트 / Codex / 브라우저 자동화
| 경로 | 조건 | 외부 | 소스 |
|---|---|---|---|
| `~/.local/share/claude/versions/*` | 활성 버전(`~/.local/bin/claude` symlink 대상) + 직전 1개 유지(`MOLE_AI_AGENTS_KEEP=1`), symlink 깨짐/모름 → 전부 유지 | | `dev.sh:4356-4403, 3519-3885` |
| `~/.local/share/cursor-agent/versions/*` (`~/.local/bin/cursor-agent`) | 동일 | | 〃 |
| `~/.copilot/pkg/universal/*` (`~/.local/bin/copilot`) | 동일 | | 〃 |
| `~/Library/Application Support/Claude/{claude-code,claude-code-vm}/<ver>` | Claude Desktop 미실행, SDK 버전 유지 | | `dev.sh:4071-4233` |
| Playwright 누수 프로필 `playwright_chromiumdev_profile*` | ppid 1인 브라우저 루트 프로세스 기준, `pgrep -f` 정확히 1(없음)일 때만 | `ps`, `pgrep` | `dev.sh:4235-4354` |
| `~/Library/Caches/Codex/{Default,Default/Partitions/codex-browser-app,codex-browser-app}/{Cache,Code Cache}/*` | Codex 미실행 | | `dev.sh:4514-4572` |
| `~/Library/Application Support/{t3code-v2,T3 Code (Alpha)}/Partitions/t3code-preview-*/{Cache,Code Cache}` | T3 Code 미실행 | | `dev.sh:5829-5886` |
| `~/.cache/codex-runtimes/<dir>` | Codex 비활성 + stale 판정 | | `dev.sh:5442-5535` |
| `~/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation/<dir>` | > 30일, Codex/Sparkle 미실행, 열린 파일 없음, 설치 빌드보다 오래됨 | `lsof`, `mdfind`, `plutil` | `dev.sh:4574-5004` |
| `~/.codex/packages/app-server-daemon/releases/<rel>` | 활성 release 유지, 락 획득, 열린 핸들 없음 | | `dev.sh:5006-5226` |
| `~/Library/Application Support/Codex/Crashpad/pending/*` (파일) | > 30일, Codex·crash handler 미실행 | | `dev.sh:5237-5358` |
| `~/.codex/.tmp/<staging>` | > 30일, Codex 미실행, `~/.codex` 미화이트리스트 | | `dev.sh:5620-5747` |
| `~/.codex` 기타, `~/Library/Application Support/Codex` | **비대상**(보호) | | `dev.sh:5537`, `app_protection.sh` |
| `~/.gemini/antigravity-browser-profile/Default/{Cache,Code Cache,GPUCache,DawnGraphiteCache,DawnWebGPUCache}/*` | Antigravity/Gemini 미실행 | | `dev.sh:5781-5827` |
| `~/.cache/chrome-devtools-mcp/chrome-profile/Default/...` + SW | chrome-devtools-mcp 미실행 | | `dev.sh:5888-5957` |
| `~/.agent-browser/browsers/<old chrome>` | 설정에서 쓰는 버전·최근 1일 내 수정 제외, 미실행 | | `dev.sh:5959-6123` |
| `~/.local/share/cursor-agent/**/*.log` | > 7일 | `find` | `dev.sh:6197-6203` |

#### 2.6.9 기타 언어/CI/DB/API/네트워크/misc
| 경로 | 소스 |
|---|---|
| `~/.composer/cache/*`, `~/Library/Caches/composer/*`, `~/.cache/bazel/*`, `~/.cache/zig/*` | `dev.sh:4405-4420` |
| `$(getconf DARWIN_USER_CACHE_DIR)/clang/*` (Clang 모듈 캐시; Xcode/clang 미실행) | `dev.sh:904-944` |
| `~/.cache/terraform/*`, `~/.grafana/cache/*`, `~/.jenkins/workspace/*/target/*`, `~/.cache/gitlab-runner/*`, `~/.github/cache/*`, `~/.circleci/cache/*`, `~/.sonar/*` | `dev.sh:4422-4432` |
| `~/Library/Caches/{com.sequel-ace.sequel-ace/*,com.eggerapps.Sequel-Pro/*,redis-desktop-manager/*,com.navicat.*,com.dbeaver.*,com.redis.RedisInsight}` | `dev.sh:4434-4441` |
| `~/Library/Caches/{com.postmanlabs.mac,com.konghq.insomnia,com.tinyapp.TablePlus,com.getpaw.Paw,com.charlesproxy.charles,com.proxyman.NSProxy}/*` | `dev.sh:4443-4450` |
| `~/.cache/{curl,wget}/*`, `~/Library/Caches/{curl,wget}/*` | `dev.sh:6224-6229` |
| `~/.hex/cache/*`, `~/.opam/download-cache/*` | `dev.sh:6232-6242` |
| `~/Library/Caches/{com.unity3d.*,com.mongodb.compass,com.figma.Desktop,com.github.GitHubDesktop,SentryCrash,KSCrash,com.crashlytics.data}/*` | `dev.sh:6126-6132` |
| `~/Library/Application Support/{Antigravity,Filo/production,Claude,Qoder}/{Cache,Code Cache,GPUCache,DawnGraphiteCache,DawnWebGPUCache,CachedData,CachedExtensionVSIXs,logs,sentry}/*` (앱 미실행: `mole_safe_clean_app_cache`) | `dev.sh:6133-6171` |
| `~/.cache/prisma/*`, `~/.cache/opencode/*`, `~/Library/Application Support/com.wondershare.Installer/*` | `dev.sh:6173-6214` |

#### 2.6.10 에디터 (`clean_code_editors`, `app_caches.sh:589-672`)
| 경로 | 조건 |
|---|---|
| `~/.vscode/extensions`, `~/.vscode-insiders/extensions`, `~/.cursor/extensions` 내 `.obsolete`에서 값이 **boolean true**인 확장 폴더 | — |
| `~/Library/Application Support/Code/{logs,Cache,CachedExtensionVSIXs,CachedData,WebStorage/*/CacheStorage}/*`, `Cursor/CachedExtensionVSIXs/*` | VS Code/Cursor 미실행 |
| `~/Library/Caches/com.sublimetext.*/*`, `~/Library/Caches/Zed/*`, `~/Library/Logs/Zed/*`, `Application Support/Zed/node/{cache,node-v*/cache}/*` | Zed 항목은 Zed 미실행 |
| `Application Support/CodeBuddyExtension/{Cache,logs}/*`, `CodeBuddy CN/{Cache,CachedData,CachedExtensionVSIXs,Code Cache,GPUCache,DawnGraphiteCache,DawnWebGPUCache,logs}/*` | CodeBuddy 미실행 |

#### 2.6.11 Homebrew (`brew.sh`)
| 대상 | 조건 | 외부 명령 | 소스 |
|---|---|---|---|
| `~/Library/Caches/Homebrew/downloads/*` | — | | `dev.sh:6319` |
| `brew cleanup --prune=30` | 최근 7일 내 실행 기록(`~/.cache/mole/brew_last_cleanup`) 없음, `~/Library/Caches/Homebrew` 미화이트리스트. dry-run은 `--dry-run` 미리보기. 실행 전 활성 링크 스냅샷, 후 복원(`brew --prefix/--cellar`) | `HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 NONINTERACTIVE=1 brew cleanup --prune=30` | `brew.sh:295-430` |
| `brew autoremove` | **RO**: `--dry-run` 결과만 리뷰 행(실행 안 함) | `brew autoremove --dry-run` | `brew.sh:11-42, 117` |
| `$(brew --prefix)/var/log/**/*.log*` | > 7일, 소유자 uid 일치, nlink 1, 열린 핸들 없음 | `find`, `lsof` | `brew.sh:434-652` |

### 2.7 Apps & utilities (`clean_user_gui_applications`, `app_caches.sh:2221`)
대부분 `~/Library/Caches/<id>[/*]`는 2.2의 일괄 스윕과 중복(이미 비어 있음). 아래는 스윕 밖 경로 위주로 정리; 전체 목록은 소스 참조.

| 그룹 | 스윕 밖(고유) 대상 | 조건 | 소스 |
|---|---|---|---|
| 커뮤니케이션 | `~/Library/Application Support/{discord,legcord,Slack}/Cache/*`, `vesktop/sessionData/{Cache,Code Cache}/*`, `Microsoft/Teams/{Cache,Application Cache,Code Cache,GPUCache,logs,tmp}/*` | 앱 미실행 | `app_caches.sh:1106-1140` |
| WeChat | `~/Library/Containers/com.tencent.xinWeChat/Data/{Documents/app_data/log, .wxapplet/WMPF, Documents/app_data/radium/web/profiles/*/{Cache,Service Worker/CacheStorage}}` | WeChat 미실행, 물리경로 바인딩 | `app_caches.sh:1044-1104` |
| WeCom | `~/Library/Containers/com.tencent.WeWorkMac/Data/{Library/Application Support/WXWork/Log, Documents/cefcache/{Default,wew_N}/{Cache,Code Cache,GPUCache,Service Worker/CacheStorage}}` | WeCom 미실행 | 〃 |
| Feishu/Lark | `~/Library/Caches/LarkShell`, `Containers/com.bytedance.macos.feishu/Data/Library/Caches`, `Application Support/{LarkShell,LarkInternational}/{aha,iron}/users/*/profile_{explorer,main}/Service Worker/CacheStorage` | 미실행 | `app_caches.sh:674-790` |
| Notion | `~/Library/Application Support/Notion/Partitions/*/Service Worker/CacheStorage` | 미실행, PROTECTED_SW_DOMAINS | `app_caches.sh:792-876` |
| DingTalk | `Application Support/iDingTalk/{log,holmeslogs}/*` | — | `app_caches.sh:1142-1149` |
| AI 앱 | `~/Library/Logs/Claude/*` | — | `app_caches.sh:1151-1168` |
| 디자인 | `Application Support/com.bohemiancoding.sketch3/cache/*`, `Caches/Adobe/*`, `Caches/com.adobe.*/*`, `Application Support/Adobe/Common/Media Cache Files/*` | Adobe 앱 미실행 (단, `Caches/Adobe *`는 protect 목록) | `app_caches.sh:1188-1203` |
| 영상 | `~/Movies/CacheClip/*`, `~/Movies/JianyingPro/User Data/Cache/<subdirs>` | Jianying 미실행 | `app_caches.sh:1205-1275` |
| 3D/Autodesk | `Caches/com.autodesk.*`; `~/Library/Application Support/Autodesk/webdeploy/production/<40-hex>` 구 Fusion 번들 | Autodesk 미실행; Fusion은 정확히 1개 `com.autodesk.fusion360` 번들, 현재보다 낮은 `CFBundleVersion`, 별칭 해석(`osascript`) | `app_caches.sh:1277-1925` |
| Futu | `Containers/cn.futu.niuniu.nx/Data/Library/Application Support/LiveUpdate/mac_qtnn/*` | Futu 미실행 | `app_caches.sh:1929-1961` |
| 생산성 | `Application Support/Quark/Cache/videoCache/*`, `Containers/{com.ranchero.NetNewsWire-Evergreen,com.ideasoncanvas.mindnode}/Data/Library/Caches/*`, `~/.cache/kaku/*`, `Application Support/spacedrive/thumbnails/*`, `Containers/is.follow/.../Folo/Cache/Cache_Data/*` | — | `app_caches.sh:1963-1977` |
| 미디어 | `Containers/com.apple.podcasts/Data/tmp/{StreamedMedia,*.heic,*.img,*CFNetworkDownload*.tmp}`, `Containers/com.tencent.QQMusicMac/.../QQMusicMac/{iRRCache,iLog,iCache,iTemp}/*`, `Containers/com.tencent.tenvideo/.../{Upgrade,VideoNative,documentCache}/*`, `Containers/com.wuziqi.SenPlayer/Data/tmp/videoCache/*`, `Application Support/stremio/stremio-server/stremio-cache/*` | — | `app_caches.sh:1979-2028` |
| 다운로드 관리자 | `Application Support/com.NeatDownloadManager/<seg>` (seg.x0 > 30일) | — | `app_caches.sh:2030-2103` |
| 게임 | `Application Support/Steam/{htmlcache,appcache,depotcache,steamapps/shadercache,logs}/*`, `Battle.net/Cache/*`, `minecraft/{logs,crash-reports,webcache,webcache2}/*`, `~/.lunarclient/{game-cache,launcher-cache,logs,offline/*/logs,offline/files/*/logs}/*`, `PCSX2/cache/*`, `~/Library/Logs/PCSX2/*`, `rpcs3/logs/*` | — | `app_caches.sh:2105-2144` |
| 셸 유틸 | `~/.zcompdump*`, `~/.lesshst`, `~/.viminfo.tmp`, `~/.wget-hsts`, `~/.cacher/logs/*`, `~/.kite/logs/*`, `~/Library/Logs/warp.log` | — | `app_caches.sh:2168-2179` |
| 시스템 유틸 | `Application Support/WeType/{com.onevcat.Kingfisher.ImageCache.WeType,DictUpdate}/*`, `Application Support/mihomo-party/{Cache,Code Cache,GPUCache,DawnGraphiteCache,DawnWebGPUCache,logs}/*` | mihomo-party 미실행 | `app_caches.sh:2181-2198` |
| 스윕 중복 `~/Library/Caches/<id>` 목록 | Zoom, Telegram, Teams, WhatsApp, Skype, Tencent Meeting, QQ, ChatGPT, Claude, LM Studio, Sketch, Figma, ScreenFlow, Final Cut, DaVinci, Premiere, Blender, Cinema4D, SketchUp, MiaoYan, Klee, Ora, Filo, Flomo, Music, Podcasts, TV, Plex, NetEase, QQMusic, Kugou, Kuwo, IINA, VLC, mpv, iQIYI, Tencent Video, Bilibili, Douyu, Huya, Stremio, aria2, Transmission, qBittorrent, Downie, Folx, Pacifist, Steam, Epic, Battle.net, EA, GOG, Riot, PCSX2, RPCS3, Youdao, Eudic, Bob, CleanShot, Camo, Xnip, Spark, Airmail, Todoist, Any.do, Warp, SentryCrash/Warp, Ghostty, Input Source Pro, WakaTime, Stash, Notion, Obsidian, Logseq, Bear, Evernote, Yinxiang, Alfred, The Unarchiver, TeamViewer, AnyDesk, ToDesk, Sunlogin | — | `app_caches.sh:1113-2218` |

### 2.8 Virtualization (`user.sh:2401-2525`)
| 경로 | 조건 | 외부 | 소스 |
|---|---|---|---|
| `~/Library/Caches/com.vmware.fusion`, `~/Library/Caches/com.parallels.*` | — | | `user.sh:2516-2517` |
| `~/Library/Caches/com.utmapp.UTM/*`, `Containers/com.utmapp.UTM/Data/{Library/Caches,tmp}/*` | UTM 미실행 | | `user.sh:2401-2417` |
| `~/VirtualBox VMs/.cache`, `~/Library/Caches/lima/download/by-url-sha256/*`, `~/.vagrant.d/tmp/*` | — | | `user.sh:2519-2521` |
| `~/.tart/cache` | tart 미실행, 미화이트리스트, 30일 초과 항목 | `tart prune --entries caches --older-than 30` | `user.sh:2419-2512` |

### 2.9 Application Support (`clean_application_support_logs`, `user.sh:2619-2916`)
| 경로 | 조건 | 소스 |
|---|---|---|
| `~/Library/Application Support/<app>/{Code Cache,GPUCache,DawnCache,GrShaderCache,GraphiteDawnCache,DawnGraphiteCache,DawnWebGPUCache,Crashpad/completed}/*` | 앱 폴더가 화이트리스트/보호/`should_protect_data(name 또는 lowercase)`/critical 아님; `SingletonLock`(symlink `<host>-<pid>`)의 pid가 살아 있거나 읽을 수 없으면 **스킵**(각 후보 전 재확인). 항목 >100이면 bulk(크기 생략) | `user.sh:2581-2790` |
| 위 + `<app>/{Cache,CachedData}/*` | 위 마커(Electron/Chromium 흔적) 중 하나라도 존재할 때만 | 〃 |
| `~/Library/Group Containers/group.com.apple.contentdelivery/{Logs,Library/Logs}/*` | 명시적 허용 목록 | `user.sh:2795-2880` |

### 2.10 App leftovers (`apps.sh`)
| 대상 | 조건 | sudo | 외부 명령 | 소스 |
|---|---|---|---|---|
| `~/Library/Caches/{com.*,org.*,net.*,io.*}`, `~/Library/Logs/{com.*,...}`, `~/Library/Saved Application State/*.savedState` 중 **고아** | 설치 앱 목록(`/Applications`, `/System/Applications`, `~/Applications`, `/opt/homebrew/Caskroom`, `/usr/local/Caskroom`, Setapp; maxdepth 3 `*.app`)과 실행 중 앱(`osascript System Events` / `lsappinfo list`), LaunchAgents 참조에 없음; mtime ≥ 30일; `ORPHAN_NEVER_DELETE_PATTERNS`/`should_protect_data` 아님; reverse-DNS면 `mdfind kMDItemCFBundleIdentifier==` 결과 없음; timeout은 해당 항목만 유지. 설치앱 캐시 `~/.cache/mole/installed_apps_cache` | N | `osascript`, `lsappinfo`, `mdfind`, `PlistBuddy` | `apps.sh:118-910` |
| `~/Library/Application Support/Claude/vm_bundles/*.bundle` | Claude 미설치(mdfind)·미실행, 번들 내부 모든 항목 mtime > 7일(발견 시+sink 재확인) | N | `find`, `mdfind` | `apps.sh:545-790` |
| `/Library/LaunchDaemons/*.plist`, `/Library/LaunchAgents/*.plist` + 참조 helper, `/Library/PrivilegedHelperTools/*` | 부모 앱 부재(`known_protect_patterns` 앱 경로, `mdfind`), `Program/ProgramArguments`는 절대경로만, helper 이름이 reverse-DNS일 때만 부모 앱 질의, helper가 **Developer ID 서명**(`codesign --verify -R`)일 때만 고아, 남은 plist가 참조하면 유지. 예산 60s. `launchctl bootout` 없음(파일만 삭제) | **Y** | `sudo find`, `PlistBuddy`, `plutil`, `codesign`, `mdfind` | `apps.sh:921-2026` |
| `~/Library/Containers/{com.macpaw.CleanMyMac*,*.com.macpaw.CleanMyMac*}` 빈 스텁 | 앱 미설치, 내부가 `.com.apple.containermanagerd.metadata.plist` 하나뿐 | N | `rm -f`, `rmdir` | `apps.sh:2028-2236` |
| `~/Library/LaunchAgents/*.plist` | **RO**: 대상 프로그램/연결 앱이 없는 로그인 항목 최대 3개 경고 | N | `PlistBuddy` | `hints.sh:470-537` |

### 2.11 Apple Silicon (`user.sh:3858-3866`, arm64만)
| 경로 | sudo | 비고 |
|---|---|---|
| `/Library/Apple/usr/share/rosetta/rosetta_update_bundle` | (sudo 없으면 validate/권한에서 실패; `/Library/Apple/*`는 critical tree라 사실상 거부) | `safe_clean` 경유 |
| `~/Library/Caches/com.apple.rosetta.update`, `~/Library/Caches/com.apple.amp.mediasevicesd` | N | |

### 2.12 Device backups & firmware (`user.sh:2918-3058`)
| 경로 | 조건 | 소스 |
|---|---|---|
| `~/Library/iTunes/{iPhone,iPad,iPod,Apple TV} Software Updates/*.ipsw` (maxdepth 1) | 열린 핸들 없음(sizing 전후·sink), 조상 symlink 거부, 부모/파일 identity 바인딩, 부분 다운로드·백업 제외 | `user.sh:2940-3030` |
| `~/Library/Group Containers/*.group.com.apple.configurator/**/*.ipsw` | 동일 | `user.sh:2951-3040` |
| iOS 백업 `~/Library/Application Support/MobileSync/Backup` | **RO**(Large files에서만) | |

### 2.13 Time Machine (`system.sh:977-1428`)
| 대상 | 조건 | sudo | 외부 | 소스 |
|---|---|---|---|---|
| `/Volumes/*/Backups.backupdb/**/*.inProgress` (maxdepth 3), 마운트된 sparsebundle 내부 동일 | TM 비실행(`tmutil status`), 로컬/비네트워크 FS(`df -T`), mtime ≥ 48h(`MOLE_TM_BACKUP_SAFE_HOURS`), identity 불변, 전체 60s | (tmutil delete는 실질적으로 root 필요) | `tmutil destinationinfo/status/delete`, `hdiutil info`, `df` | `system.sh:977-1400` |

### 2.14 Large files — RO (`user.sh:3409-3856`)
임계값 1GB 이상만 `⊙ label · size · fact` 행 출력, 삭제 없음. 최대 4 워커 프리페치(`du -skP`).
| 라벨 | 경로 |
|---|---|
| Mail data / Mail downloads | `~/Library/Mail`, `~/Library/Mail Downloads` |
| Conductor | `~/Conductor/{workspaces,archived-contexts}` |
| macOS installer | `/Applications/Install macOS*.app` |
| macOS updates cache | `~/Library/Updates` |
| Snapshots | `tmutil listlocalsnapshots /` (System 섹션 미수행 시) |
| Docker storage | `docker system df` (로컬 엔진만) 또는 `~/Library/Containers/com.docker.docker/Data` |
| Xcode DerivedData / archives / Simulator data | `~/Library/Developer/Xcode/{DerivedData,Archives}`, `~/Library/Developer/CoreSimulator/Devices` |
| iOS backups | `~/Library/Application Support/MobileSync/Backup` |
| LM Studio models | `~/.lmstudio/models` |
| OrbStack / Lima | `~/Library/Group Containers/*dev.orbstack/data`, `~/OrbStack`, `~/.lima` |
| Maven/Ivy/NuGet/pnpm/Conda/Anaconda/Gradle | `~/.m2/repository`, `~/.ivy2/cache`, `~/.nuget/packages`, `~/Library/pnpm/store`, `~/.conda/pkgs`, `~/anaconda3/pkgs`, `~/.gradle/caches` |
| Compiled model cache | `~/Library/Caches/*/com.apple.e5rt.e5bundlecache` (depth ≤2) |
| Android emulators / system images | `${ANDROID_AVD_HOME:-~/.android/avd}`, `${ANDROID_HOME:-~/Library/Android/sdk}/system-images` |
| Hugging Face | `${HF_HOME:-~/.cache/huggingface}` |
| mise installs / FVM | `${MISE_DATA_DIR:-~/.local/share/mise}/installs/*`, `~/fvm/versions` |
| JetBrains old version data | `~/Library/Application Support/JetBrains/<old>` |
| AI agent worktrees | `~/.codex/worktrees`, `~/.t3/worktrees`, 프로젝트 루트 하위 `.claude/worktrees` (maxdepth 6) |

### 2.15 Project artifacts — RO (`hints.sh:195-468`)
프로젝트 루트(최대 200개, 15s 예산)에서 `node_modules`, `target` 등 빌드 산출물 추정 크기 합이 200MB 이상이면 `Build artifacts · N dirs, X · mo purge` 한 줄.

---

## 3. clean 전용 안전 가드

### 3.1 보호 레이어 (적용 순서)
| 레이어 | 위치 | 내용 |
|---|---|---|
| 하드 deny (`_mole_is_critical_deletion_path`) | `file_ops.sh:1044` | `/`, `/bin`, `/sbin`, `/usr`(단 `/usr/local/*` 자식 허용), `/System`, `/Library`(루트), `/Library/{Apple,Extensions,Keychains}`, `/Library/Application Support`(루트), `/Applications`(루트), Finder/Safari.app, `/Volumes`, `/opt`, `/opt/homebrew`(루트), `/Users`, `/Users/<name>`(홈 루트), `/Users/Shared`, `/private`, `/private/tmp`, `/etc`, `/var/db`, `/private/var/{folders,tmp,db,audit,root}`(루트). 대소문자 별칭도 inode 비교로 차단 |
| `validate_path_for_deletion` | `file_ops.sh:1160` | 절대경로, `..` 컴포넌트 금지, 제어문자 금지, symlink 대상 재검증, **조상 symlink 해석 후 재검증**, 활성 powerlog DB, **라이브 사용자 캐시**(reverse-DNS 캐시 소유 프로세스 + SQLite 핸들), 사용 중/불명 SQLite, 진행 중 다운로드, EDR/endpoint-security 캐시 거부 |
| `should_protect_path` | `app_protection.sh:406` | 공유 XDG 루트(`~/.cache`, `~/.config`, `~/.local{,/bin,/lib,/share,/state}`), `~/.jupyter/runtime`, `~/.yarn/berry/cache`, `~/.prometheus/data`, 셸 히스토리 백업; System Settings/ControlCenter/Notes/Finder/Dock 관련; Container/Group Container의 보호 번들(`should_protect_data`) — 단 `Data/Library/Caches/*`, `Data/tmp/*`는 허용; OrbStack; Codex 상태; Keychains/Mail/Calendars/Contacts/Accounts/Mobile Documents; 오디오 플러그인; Playwright/Cypress/Adobe/HomeKit 등 캐시; idleassetsd/wallpaper; coreaudio |
| `should_protect_data(bundle_id)` | `app_protection.sh:199` | `com.apple.*`, cups, keychain/security/bluetooth/wifi/network/tcc, 입력기·키보드, Karabiner, 비밀번호 관리자(1Password, LastPass, Dashlane, Bitwarden …) 및 `DATA_PROTECTED_BUNDLES` |
| compiled model | `app_protection.sh:330` | `com.apple.e5rt.e5bundlecache`를 포함하는 경로는 항상 스킵 |
| 화이트리스트 | `app_protection.sh:684` | 아래 3.2 |

### 3.2 화이트리스트 의미론
- 파일: `~/.config/mole/whitelist` (한 줄당 패턴, `#` 주석, `~`/`$HOME` 확장). 파일이 없을 때만 `DEFAULT_WHITELIST_PATTERNS` 사용(`base.sh:172` — ms-playwright*, camoufox*, Cypress*, `~/.gradle/caches/*`, `~/.gradle/daemon/*`, `~/.ollama/models/*`, Surge, renv, JetBrains*, tealdeer, `com.apple.finder`, `Mobile Documents*`, `FINDER_METADATA`). 파일이 있으면 **완전 대체**.
- `SAFETY_WHITELIST_PATTERNS`(`base.sh:199`)는 항상 병합: `FINDER_METADATA`, FontRegistry*, spotlight*/Spotlight*, CloudKit*, kitty, pypoetry/virtualenvs*, renv/*, pnpm/dlx*, llama.cpp.
- 로드 시 거부: `..` 포함, 상대경로, 제어문자, `//`, `/`·`/System`·`/bin`·`/sbin`·`/usr/bin`·`/usr/sbin`·`/etc`·`/var/db` (경고로 표시).
- 매칭(`is_path_whitelisted`): ① 정확 일치 ② bash glob 일치(`*`는 `/`도 매치) ③ **패턴이 타깃의 하위 경로면 타깃도 보호**(부모 삭제 방지) ④ 글롭 없는 패턴이면 그 하위 전체 보호.
- 특수 센티넬 `FINDER_METADATA` → `PROTECT_FINDER_METADATA=true` → `.DS_Store`/`._*` 정리 비활성(기본 ON이므로 사실상 기본 비활성).
- `~/.Trash` 패턴 → 휴지통 비우기 전체 스킵.
- 화이트리스트는 `safe_clean` 필터와 `safe_remove` sink 양쪽에서 확인(직접 `safe_remove` 호출 경로 포함).
- 메뉴(`whitelist.sh:91-187`)는 "표시명|패턴|카테고리" 카탈로그 체크박스 UI(+ Go/GitHub CLI/Clang 동적 행).

### 3.3 실행 중 앱 가드
- 프로브는 `pgrep -x/-f` 기반 3-상태(0 실행 / 1 미실행 / 2 불명). **1일 때만 삭제**. 0은 조용히 defer(debug 로그), 2는 "stopped (process state unknown)" 경고.
- 가드는 (a) 배치 시작 전, (b) `safe_clean_guarded`로 각 타깃 직전, (c) `_MOLE_SAFE_REMOVE_FINAL_GUARD`로 `rm` 직전에 반복.
- Electron/Chromium 앱 범용: `SingletonLock` symlink의 pid 생존 확인(`kill -0`/`ps -p`).
- 열린 파일: `lsof` 기반 `_mole_paths_have_open_handle`(미완료 다운로드, ipsw, brew 로그, Codex staging, 컨테이너 캐시). 불명은 유지.

### 3.4 Trash vs rm
- clean의 모든 삭제는 **`rm -rf` 영구 삭제**(sudo 경로는 `sudo rm -rf`). 휴지통 이동은 uninstall 전용.
- 휴지통(`~/.Trash`)은 기본적으로 **전체 비움**(나이 제한·확인 프롬프트 없음, 유지보수자 결정). 사용자는 화이트리스트로 끔.
- dry-run과 실제 실행은 동일 후보 집합(같은 필터 → 경계에서 재검증)을 보장.

### 3.5 시간/중단 의미론
- 타임아웃 상수(`timeouts.sh:61-68`): quick 2s, short 3s, medium 5s, pkg-list 10s, pkg-cleanup 20s, disk-verify 30s, hint-scan 15s, Cloud&Office 300s, System 120s, 고아 서비스 60s, TM 60s.
- 크기 측정 timeout → 행은 `X+`/partial. 삭제 timeout → 실패 카운트(경로 로그). signal → 전체 중단 후 요약.

---

## 4. Swift 포팅 노트

### 4.1 구현 수단 매핑
| 영역 | Swift 수단 | 비고 |
|---|---|---|
| 사용자 영역 글롭 삭제(대부분의 `safe_clean`) | `FileManager.contentsOfDirectory` + `removeItem(at:)` | `/*` 의미 = 자식만. 글롭은 `fnmatch`/직접 구현(`*`가 `/`를 넘지 않게 — 원본 bash pathname glob 동작) |
| 크기 측정 | `URLResourceValues` `.totalFileAllocatedSizeKey` + `lstat`(no-follow), 디바이스 경계, 하드링크 dedupe; APFS clone private size는 `getattrlist(ATTR_CMNEXT_PRIVATESIZE)` | 30s 예산·취소 토큰 |
| 나이 조건 | `.contentModificationDateKey`, `.creationDateKey`(Mail 첨부 birth 비교) | |
| 프로세스 상태 | `NSWorkspace.runningApplications`(bundle id) + `sysctl(KERN_PROC_ALL)`/`proc_listpids`+`proc_pidpath`(CLI·helper 이름, `pgrep -f` 대체) | 3-상태 유지(조회 실패=불명) |
| 열린 파일 확인 | `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo` 또는 `/usr/sbin/lsof` shell-out | 타 사용자 프로세스는 root 필요 → 불명 처리 |
| identity 바인딩 | `stat` dev/ino 스냅샷 → 삭제 직전 비교, `openat`/`unlinkat`(`AT_SYMLINK_NOFOLLOW`) 기반 삭제 권장 | TOCTOU 방지; `FileManager.removeItem`은 symlink를 따라가지 않지만 조상 symlink는 직접 검사 필요 |
| plist 읽기 | `PropertyListSerialization` (device.plist, Info.plist, LaunchDaemon plist) | `PlistBuddy`/`plutil` 불필요 |
| 코드서명 | `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` + `SecRequirementCreateWithString("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]...")` | macOS installer(Apple), helper(Developer ID) |
| 설치 앱/고아 판정 | `NSWorkspace.urlForApplication(withBundleIdentifier:)`, `NSMetadataQuery`(`kMDItemCFBundleIdentifier`), LaunchServices | `mdfind` 대체 |
| 실행 중 앱 목록 | `NSWorkspace.shared.runningApplications` | `osascript`/`lsappinfo` 대체 |
| 외장 볼륨 검증 | `URLResourceValues` `.volumeIsInternalKey`, `.volumeIsLocalKey` 또는 DiskArbitration `DADiskCopyDescription`(`kDADiskDescriptionDeviceInternalKey`, `DeviceProtocol`) | |
| 여유 공간 | `.volumeAvailableCapacityForImportantUsageKey` | |
| `DARWIN_USER_CACHE_DIR` | `confstr(_CS_DARWIN_USER_CACHE_DIR)` | Clang 모듈 캐시, GPU 캐시 위치 |

### 4.2 Shell-out 필요 (Process, 타임아웃·시그널 처리 필수)
| 명령 | 용도 |
|---|---|
| `npm cache clean --force`, `pnpm store prune`, `corepack cache clean`, `bun pm cache rm`, `pip3 cache purge`, `uv cache prune`, `conda clean ...`, `go clean -cache/-modcache`, `mise cache clear`, `gh config clear-cache`, `nix-store --gc` | owner command. 각각 `<tool> cache dir/path` 류로 루트 확인 후 실행. **GUI 앱에서는 사용자 셸 PATH가 없음** → `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, `~/go/bin`, mise/asdf shim 등을 탐색하거나 로그인 셸(`zsh -lc`)로 PATH 획득 |
| `brew cleanup --prune=30`, `brew autoremove --dry-run`, `brew --prefix/--cellar` | Homebrew (root로 실행 금지) |
| `docker context inspect/show`, `docker info`, `docker builder prune`, `docker image prune`, `docker system df` | Docker (로컬 소켓만) |
| `xcrun simctl list/delete unavailable/runtime list`, `xcodebuild -checkFirstLaunchStatus` | 시뮬레이터 (first-launch 미완 시 관리자 프롬프트 유발 → 반드시 선확인) |
| `tmutil listlocalsnapshots/status/destinationinfo/delete`, `hdiutil info` | Time Machine |
| `tart prune` | Tart |
| `git ls-files`(literal icase pathspec) | 프로젝트 캐시의 추적 파일 확인 (또는 libgit2) |

### 4.3 Privileged helper 필요 (SMAppService daemon + XPC, 경로 화이트리스트 내장)
- 2.1 System 전체: `/Library/Caches`, `/Library/Logs/*`, `/private/var/log`, `/private/var/db/{diagnostics,DiagnosticPipeline,powerlog,reportmemoryexception}`, `/private/var/folders/*/*/C/**` GPU 캐시, idleassetsd tmp, `/Library/Caches/com.apple.iconservices.store`, `/Applications/Install macOS*.app`.
- `/Library/Developer/Xcode/DocumentationCache`, `/Library/Developer/CoreSimulator/Caches`.
- 고아 시스템 서비스: `/Library/LaunchDaemons`, `/Library/LaunchAgents`, `/Library/PrivilegedHelperTools`.
- 루트 소유 브라우저 앱 번들의 구버전 `Versions/<v>` (사용자 소유면 불필요).
- `tmutil delete`(TM in-progress).
- 헬퍼는 **경로 prefix/패턴 허용 목록 + 하드 deny 목록을 자체 보유**해야 함(클라이언트 입력 신뢰 금지). 원본처럼 "가변 조상(사용자 쓰기 가능 부모) 거부".

### 4.4 Full Disk Access(TCC) 영향
| FDA 없으면 실패/스킵 | 비고 |
|---|---|
| `~/.Trash` | 원본도 `ls` 실패 시 "FDA 필요" 출력 |
| `~/Library/Messages/**`, `~/Library/Mail*`, `~/Library/Containers/com.apple.mail/**` | Mail Downloads, Messages 캐시 |
| `~/Library/Containers/*`, `~/Library/Group Containers/*` (타 앱 데이터) | macOS 14+는 타 앱 컨테이너 접근 시 "App Data" 동의 프롬프트/거부 |
| `~/Library/Safari`, `~/Library/Caches/com.apple.Safari` | |
| `~/Library/Application Support/MobileSync/Backup`, `~/Library/Application Support/com.apple.sharedfilelist`, `~/Library/Suggestions`, `~/Library/IdentityCaches` | |
| `/Volumes/*/Backups.backupdb`, 이동식 볼륨, `~/Desktop`/`~/Documents`/`~/Downloads`(파일·폴더 권한) | 미완료 다운로드, 외장 볼륨 |
- 앱은 **App Sandbox 불가**(임의 경로 삭제). Hardened Runtime + Developer ID 배포, FDA 안내 화면(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) 제공. 접근 가능 여부는 `~/Library/Safari` 등 보호 경로 `open` 시도로 판별(원본 `has_full_disk_access`).

### 4.5 포팅 시 주의점 (gotchas)
1. **영구 삭제**: 원본 clean은 휴지통을 거치지 않는다. Swift 버전에서 휴지통 이동(`FileManager.trashItem`)을 택하면 공간이 즉시 회수되지 않으므로 UX 결정 필요. 원본 의미 유지 시 `rm -rf` 동등.
2. **`~/Library/Caches/*` 일괄 스윕이 핵심**: 앱별 `~/Library/Caches/<id>` 행 대다수는 중복. 카탈로그를 데이터 주도(JSON/plist 규칙 테이블)로 만들되, 스윕 제외 목록(Google, DENO_DIR, SAFETY/보호 패턴)을 정확히 이식.
3. **로그/세이브스테이트에 나이 제한 없음**: `~/Library/Logs/*`, `~/Library/Saved Application State/*`, DerivedData는 전부 삭제. 나이 기반은 System(7일), CrashReporter(30일), Mail(30일), Handoff(60분), GPU(1일), Codex/NeatDM/Tart(30일), TM(48h), installer(14일).
4. **3-상태 프로세스 판정**과 "불명=유지" 원칙을 그대로 유지. 실행 중이면 조용히 건너뜀.
5. **다중 재검증**(발견 → 크기 측정 후 → sink 직전)과 dev/ino identity 바인딩. 측정 동안 대상이 바뀌면 건너뜀.
6. **화이트리스트 조상 보호**: 패턴이 타깃의 하위면 타깃 전체 보호(부모 삭제 금지). 사용자 파일 저장 시 기본값이 사라지므로 SAFETY 패턴은 코드 상수로 항상 병합.
7. **owner command는 직접 삭제로 폴백 금지**: 실패/timeout 시 그 캐시는 유지. 크기는 전후 차이만 집계, dry-run은 "would clean"(크기 미표시).
8. **simctl 사전 조건**: `xcodebuild -checkFirstLaunchStatus`가 0이 아니면 simctl을 아예 호출하지 않음(관리자 설치 프롬프트 방지). Xcode가 여러 개면 DEVELOPER_DIR 명시 요구. 기기/런타임 조인은 이름이 아닌 `runtimeIdentifier`.
9. **Docker**: 원격 컨텍스트(`tcp://`, `ssh://`)면 아무 질의도 하지 않음. `docker info`로 엔진 기동 여부만 확인(Docker Desktop을 띄우지 않음).
10. **시스템 섹션 예산** 120s, 섹션별 단계 사이 예산 확인 후 "time limit reached" 출력하고 다음 섹션으로.
11. **LC_ALL=C / 파일명**: 공백·유니코드·개행 포함 경로를 NUL 구분으로 처리했던 부분 → Swift에선 URL 기반이라 자연 해결되나, 외부 명령 출력 파싱 시 주의.
12. **APFS 대소문자 무시**: 보호 경로 비교는 문자열이 아니라 inode/`URL.resourceValues(.fileResourceIdentifierKey)` 비교로(원본 `_mole_path_is_same_existing_file`).
13. **Large files / Snapshots / brew autoremove / 고아 런타임 / Project artifacts / OrbStack / LaunchAgent 힌트는 읽기 전용** — UI에서는 "검토" 카드로 분리하고 자동 삭제 대상에 넣지 않음.
14. `.DS_Store` 정리는 기본 화이트리스트(SAFETY의 `FINDER_METADATA`) 때문에 **사실상 기본 꺼짐**. 사용자 토글로 노출.
15. 사용자 데이터로 명시된 비대상 목록(2.6.2/2.6.3/2.6.6의 "비대상" 행, `data/Containers`, `~/.yarn/berry/cache`, `~/.jupyter/runtime`, `~/.codex` 상태, HF/torch 모델)은 규칙 테이블에서 명시적 deny로 둘 것.
