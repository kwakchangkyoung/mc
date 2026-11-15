# 05. Analyze / Status (Go TUI) 포팅 스펙

- 원본: `cmd/analyze/*.go`, `cmd/status/*.go`, `internal/units/bytes.go` (Mole, GPL-3.0). 경로는 저장소 루트 기준.
- 대상: 맥클린(MacClean) Swift/SwiftUI 네이티브 앱.
- 표기: `파일:줄`. "(추정)"은 소스에 직접 나오지 않고 의존 라이브러리 동작을 추론한 부분.
- 불변식 참고: `.claude/rules/go-tuis.md` (문서로만 읽음).

---

## Part A. ANALYZE (디스크 사용량 분석기)

### A1. 진입점 / 모드

| 항목 | 내용 | 근거 |
|---|---|---|
| CLI | `mo analyze [--json] [PATH]` | `cmd/analyze/main.go:28-40` |
| 대상 결정 | `MO_ANALYZE_PATH` env → 첫 인자 → 없으면 **overview 모드**(`/` 앵커) | `main.go:89-106` |
| 시작 시 | `go pruneAnalyzerCache()` (레거시 캐시 스윕 + 캐시 디렉터리 정리) 백그라운드 | `main.go:77`, `cache.go:419-430` |
| TUI 디렉터리 모드 | 30초 타임아웃으로 overview 크기 prefetch 동시 실행 (overview 모드에선 생략: du 이중 부하 방지) | `main.go:111-118`, `cache.go:851-885` |
| 초기 디스크 여유 | `statfs(path)` → `Bavail*Bsize` (헤더 "(X free)") | `main.go:131-135`, `view.go:28-29` |
| 진행률 힌트 | 오래된 캐시라도 `TotalFiles` peek → 프로그레스 바 분모 | `main.go:172-177`, `cache.go:766-772` |

### A2. 스캔 상태 모델

| 타입 | 필드 | 근거 |
|---|---|---|
| `scanState` | `complete`(0) / `partial` / `unavailable`; JSON 문자열로 직렬화 | `model.go:19-46` |
| `measurementState(size, err)` | err 없음→complete, size>0→partial, else unavailable | `model.go:50-58` |
| 권한 실패 | `EACCES/EPERM/fs.ErrPermission` = "영구적" 실패 → partial 이어도 캐시 가능 | `model.go:64-70`, `model.go:106-108` |
| 일시 실패(transient) | 그 외 모든 오류(timeout, 사라진 파일, I/O) → 캐시 저장 금지, 항상 refresh | `model.go:98-102` |
| `dirEntry` | `State, Name, Path, Size(-1=pending), IsDir, LastAccess(atime)` | `model.go:72-79` |
| `fileEntry` | `Name, Path, Size` | `model.go:81-85` |
| `scanResult` | `State, Entries, LargeFiles, TotalSize, TotalFiles, dedupedHardlink(메모리 전용), transientFailure(메모리 전용)` | `model.go:87-103` |

### A3. 스캔 알고리즘 (`scanPathConcurrentWithLimiter`, `scanner.go:263-620`)

1. `os.ReadDir(root)` (1단계 children). 실패 시 에러 반환 (`scanner.go:267`).
2. 수집용 goroutine 2개: entries Top-N 힌(min-heap, `entryLimit=maxEntries=30`, 0이면 전부) / large files Top-20 힙 (`scanner.go:305-353`). 정렬 키 `sizePathBefore(size, path)`.
3. child 분기:

| child 종류 | 처리 | 근거 |
|---|---|---|
| symlink | 따라가지 않음. 링크 자체 크기(`getActualFileSize`)만 합산, 이름에 `" →"` 접미사, target이 dir이면 IsDir=true | `scanner.go:366-392` |
| dir ∈ `defaultSkipDirs` | 완전 건너뜀 (nfs, PHD, Permissions, OrbStack, Colima, VMware Fusion, VirtualBox VMs, Rancher Desktop, .lima, .colima, .orbstack) | `constants.go:233-247`, `scanner.go:395` |
| root=`/` 이고 dir ∈ `skipSystemDirs` | 건너뜀 (dev,tmp,private,cores,net,home,System,sbin,bin,etc,var,Volumes,Network,.vol,.Spotlight-V100,.fseventsd,.DocumentRevisions-V100,.TemporaryItems,.MobileBackups; `opt`/`usr`=false 이므로 스캔) | `constants.go:209-231`, `scanner.go:400` |
| root=`$HOME` 이고 child=`Library` | overview 스냅샷 캐시 우선 사용, 없으면 `scanSubdirWithCache` | `scanner.go:405-451` |
| **folded dir** (`foldDirs` 이름 또는 npm 캐시 구조) | 펼치지 않고 `/usr/bin/du -skPx`로 크기만 측정; du 실패+size 0이면 Go 병렬 walker fallback | `scanner.go:454-490`, `scanner.go:697-714` |
| 일반 dir | `scanSubdirWithCache` 재귀(디스크 캐시 → 없으면 재귀 스캔). entry 세마포어 획득 실패 시 **인라인 동기 실행** | `scanner.go:492-527` |
| 일반 file | `countableFileSize`(하드링크/클론 dedupe) 합산, LastAccess=atime, 코드 확장자 아니고 size ≥ 현재 Top-20 최소값이면 large 후보 | `scanner.go:530-558` |

4. 모든 worker 종료 → 힙을 내림차순 슬라이스로 (`scanner.go:568-593`).
5. `useSpotlight`(최상위 호출만 true; 하위 재귀는 false) → `mdfind -onlyin <root> "kMDItemFSSize >= 104857600"` (5초 타임아웃). 결과가 기존 large 리스트보다 **많으면 교체** (`scanner.go:595-604`, `806-882`). 코드 확장자/folded dir 내부/디렉터리/symlink 제외.
6. 상태: 실패 하나라도 있으면 partial (`scanner.go:607-610`).

#### foldDirs (펼치지 않고 du로만 측정) — `constants.go:75-207`

| 분류 | 이름 |
|---|---|
| VCS | `.git .svn .hg` |
| JS/Node | `node_modules .npm _npx _cacache _logs _locks _quick _libvips _prebuilds _update-notifier-last-checked .yarn .pnpm-store .next .nuxt bower_components .vite .turbo .parcel-cache .nx .rush tnpm .tnpm .bun .deno` |
| Python | `__pycache__ .pytest_cache .mypy_cache .ruff_cache venv .venv virtualenv .tox site-packages .eggs *.egg-info(리터럴 키, glob 아님) .pyenv .poetry .pip .pipx` |
| Ruby/Go/PHP/JVM/Rust | `vendor .bundle gems .rbenv target .gradle .m2 .ivy2 out pkg composer.phar .composer .cargo` |
| 빌드 산출물 | `build dist .output coverage .coverage` |
| IDE | `.idea .vscode .vs .fleet` |
| 캐시 | `.cache __MACOSX .DS_Store .Trash Caches .Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems $RECYCLE.BIN .temp .tmp _temp _tmp .Homebrew .rustup .sdkman .nvm` |
| macOS | `Application Scripts`, `Saved Application State`, `Mobile Documents`(iCloud) |
| 컨테이너/모바일/웹/DB/기타 | `.docker .containerd Pods DerivedData .build xcuserdata Carthage .dart_tool .angular .svelte-kit .astro .solid .mysql .postgres mongodb .terraform .vagrant tmp temp` |
| npm 특수 | 경로에 `/.npm/` 또는 `/.tnpm/` 포함 & (부모가 `.npm`/`.tnpm`/`_*` 또는 이름 1글자) | `scanner.go:702-711` |

#### large-file 제외 확장자 (`skipExtensions`, `constants.go:249-291`)
`.go .js .ts .tsx .jsx .json .md .txt .yml .yaml .xml .html .css .scss .sass .less .py .rb .java .kt .rs .swift .m .mm .c .cpp .h .hpp .cs .sql .db .lock .gradle .mjs .cjs .coffee .dart .svelte .vue .nim .hx`

### A4. 크기 산정 (du 유사 시맨틱)

| 함수 | 시맨틱 | 근거 |
|---|---|---|
| `getActualFileSize` | **`min(st_blocks*512, st_size)`** — sparse/클라우드 placeholder는 할당량, 일반 파일은 논리 크기. (du와 다름: du는 항상 할당 블록) | `scanner.go:1279-1290` |
| `countableFileSize` | ① `nlink>1`이면 `(dev, ino)` 키로 스캔 범위 내 첫 링크만 계수 ② size>0 이고 APFS 클론이 **모든 블록 공유**(`EF_SHARES_ALL_BLOCKS`)면 `(dev, cloneID)` 키로 1회만 계수. 편집된 클론은 전체 계수. dedupe 발생 시 `deduped=true` | `scanner.go:1253-1277` |
| `cloneIdentity` | `getattrlist(path, forkattr=ATTR_CMNEXT_CLONEID(0x100)|ATTR_CMNEXT_EXT_FLAGS(0x200), FSOPT_NOFOLLOW|FSOPT_ATTR_CMN_EXTENDED)` → 응답 `u32 len, u64 cloneid, u64 extflags`; `EF_SHARES_ALL_BLOCKS=0x40`. 주의: 확장 common attr은 **forkAttr 슬롯**에 넣어야 함 | `clone_darwin.go:12-55` |
| dedupe 범위 | `scanLimiter.seen sync.Map` — 한 스캔 패스(최상위 limiter) 전체 공유 | `scanner.go:146-148` |
| dedupe된 서브트리 | 스캔 순서 의존 → **디스크 캐시 저장 금지** | `scanner.go:678-682` |
| du 호출 | `/usr/bin/du -skPx [-I name]... target` (BSD 고정: GNU du는 `-I` 거부). stdout 첫 필드 KB×1024. 비정상 종료여도 bytes 유지 + 에러. stderr가 전부 `Permission denied`/`Operation not permitted`면 권한 실패로 분류 | `scanner.go:44`, `994-1104` |
| du timeout | `duTimeout = 30s` | `constants.go:21` |
| Home overview | `~/Library` 제외: Home의 직접 child마다 du 병렬(최대 `min(max(2*NCPU,2),8)`), Library는 skip | `scanner.go:915-920`, `1135-1203` |
| User Library overview | **단일 du 1회** (교차 디렉터리 하드링크 1회 계수). 30초 초과 시 unavailable, 저장 안 함 | `scanner.go:1084-1085`, rules |
| overview du ignore | 측정 대상 직속 child에 `Mobile Documents` dir 있으면 `-I "Mobile Documents"` (iCloud FileProvider가 du를 수십 초 블록) | `constants.go:68-73`, `scanner.go:1119-1133` |
| du 실패 fallback | `filepath.WalkDir` 논리 합산(`getDirectoryLogicalSizeWithExclude`) / folded는 `calculateDirSizeFastWithLimiter` (5분 타임아웃, 세마포어 실패 시 동기 재귀) | `scanner.go:926-928`, `726-803`, `1205-1236` |
| overview 저장 기준 | size>0 && (err 없음 or 권한 실패만) | `scanner.go:945-947` |

### A5. 동시성 예산 (`scanLimiter`, `scanner.go:117-162`)

| 세마포어 | 크기 | 용도 |
|---|---|---|
| `entrySem` | `clamp(NCPU*1, 2, 12)` 및 ≤ childCount | 하위 디렉터리 worker. `tryAcquire` 실패 시 **인라인** 실행 (deadlock/스레드 폭증 방지) |
| `duSem` | `min(4, NCPU)` | 동시 du 프로세스 |
| `duQueueSem` | `2 × duSem` | du 대기 goroutine 수 상한 (메모리 선형 증가 방지) |
| `fastSem` | `min(NCPU, 12)` | du 대체 walker |
| overview | `maxConcurrentOverview = 8` | overview 행 측정 (`constants.go:23`, `update.go:16-56`) |
| 근거 | macOS per-user 스레드 한도 초과 시 Go 런타임 fatal (#765) → 보수적 | `constants.go:53-66` |
| 채널 전송 | `trySend` 100ms 타임아웃(`scanSendTimeout`), 버퍼 `min(len(children),4096)` | `scanner.go:184-225`, `320` |
| 취소 | `context` + `scanPublication`(cancel과 결과 publish 사이 선형화 경계: commit은 cancel 이후 거부) | `scanner.go:62-115` |

### A6. 라이브 스캔 / UI 업데이트 (`live_scan.go`)

| 항목 | 내용 | 근거 |
|---|---|---|
| 시작 | 새 scan ID(atomic) + publication을 **디스패치 전에** 모델에 예약; 이전 스캔 cancel | `update.go:86-96` |
| 진입 순서 | 디스크 캐시(신선) → stale 캐시(≤3일, `stale=true`로 표시 후 재스캔 예약) → 라이브 스캔 | `update.go:98-131` |
| 초기 목록 | root `ReadDir` 1회로 파일은 즉시 크기, 하위 dir은 target(directory / folded / homeLibrary)으로 | `live_scan.go:139-240` |
| 이벤트 스트림 | 채널 cap = `targets*4`, progress는 lossy(예약 슬롯 `targets+1` 남김), target 결과·완료 이벤트는 보장 | `live_scan.go:40-89` |
| progress 주기 | target별 ticker `uiTickInterval*2 = 200ms` | `live_scan.go:402`, `constants.go:65` |
| UI tick | 100ms; 이벤트는 경로 인덱스로 즉시 반영, 정렬/필터 재빌드는 tick에서 1회 | `update.go:143-144`, rules |
| live sort 모드 | `freeze-on-move`(기본: 커서 이동 시 정렬 고정) ↔ `continuous` (키 `s`) | `live_config.go:5-17`, `main.go:155` |
| target 실패 | 해당 행 `unavailable` 표시, 전체는 partial | `live_scan.go:286-298` |
| 로컬 스냅샷 | overview에서 `/usr/bin/tmutil listlocalsnapshots /` (3s) → reverse-DNS 이름 개수(`com.apple.TimeMachine.YYYY-MM-DD-HHMMSS*` 또는 비-`com.apple.*`) → 헤더 "N local snapshots · snapshot-only space is not listed below". 크기는 추정 안 함 | `snapshots.go:15-77`, `view.go:32-42` |
| 마운트 볼륨 | `getfsstat(MNT_NOWAIT)`; `MNT_LOCAL` && !`MNT_RDONLY|MNT_DONTBROWSE` && device `/dev/disk*` && 부모가 `/Volumes` | `volumes.go:14-44` |

### A7. 캐시 (`cache.go`)

| 항목 | 디렉터리 캐시 | overview 스냅샷 |
|---|---|---|
| 위치 | `~/.cache/mole/analyzer/<xxhash64(path) hex>.cache` | `~/.cache/mole/analyzer/overview_sizes.json` |
| 포맷 | Go `gob` 인코딩 `cacheEntry{State, Entries(≤30), LargeFiles, TotalSize, TotalFiles, ModTime(dir mtime), ScanTime, NeedsRefresh, SchemaVersion}` | JSON map `path → {size, partial?, updated, schema_version}` |
| 스키마 | `cacheSchemaVersion = 10`; 불일치 시 파일 삭제 | 동일, 불일치 항목 로드 시 버림 |
| TTL | 7일(`analyzerCacheTTL`); stale 허용 3일(`staleCacheTTL`) | 7일; 동일 값 재저장은 TTL/8 이내면 no-op |
| 무효화 | dir `mtime > entry.ModTime` 이면 즉시 거부(유예 없음); 경로 사라지면 삭제 | 삭제/refresh 시 명시 제거 |
| 저장 조건 | `persistable()` && !dedupedHardlink && (`TotalFiles ≥ 100` 또는 `TotalSize ≥ 10MB`) | size>0 && (ok or 권한실패) |
| 원자적 쓰기 | `CreateTemp("entry-*.tmp")` → chmod 0644 → rename (publication.commit 안에서) | `overview_sizes.json.*.tmp` → rename |
| 용량 제한 | 최대 5000 파일 / 50MB, 오래된 mtime부터 evict; `.tmp` 1시간 경과 삭제; 512개씩 ReadDir | 1000 초과 시 900까지 오래된 순 evict |
| 손상 | gob decode 실패 → 파일 삭제 | JSON 파싱 실패 → `.corrupt`로 rename |
| 근거 | `cache.go:37`, `336-369`, `376-378`, `436-526`, `591-753`; `constants.go:18-51`; `model.go:110-123` | `cache.go:39-299` |

| 무효화 API | 대상 | 근거 |
|---|---|---|
| `invalidateCache(p)` | p의 dir 캐시 + 스냅샷 | `cache.go:774-777` |
| `invalidateCacheAncestry(paths)` | 삭제 경로의 **모든 조상**(→`/`) dir 캐시 + 스냅샷 | `cache.go:783-800` (삭제 후 `update.go:383`) |
| `invalidateCacheTree(p)` | p + 직속 하위 dir | `cache.go:805-820` (`r` 키 `update.go:822`) |
| 레거시 스윕 | `~/.cache/mole/` 최상위 regular `*.cache` + `overview_sizes.json` 삭제 (4 workers). 1.48.0 이전 무제한 캐시(1.88M 파일/7.82GB) 정리 | `cache.go:540-589`, rules |
| 메모리 히스토리 | `historyEntry`(뒤로가기 스택, selection/offset 보존, `NeedsRefresh`) | `cache.go:52-95` |

### A8. Insights (overview 숨은 공간 행) — `insights.go:15-92`

overview 기본 행: `Home`(~/Library 제외), `User Library`(~/Library), `Applications`, `System Library`(/Library), 마운트 볼륨 (`main.go:186-217`). 그 뒤 insight 행 (경로 존재 시에만):

| 이름 | 경로 | 측정 |
|---|---|---|
| iOS Backups | `~/Library/Application Support/MobileSync/Backup` | du |
| Old Downloads (90d+) | `~/Downloads` | **직속 항목 중 mtime 90일 초과**만: 파일=논리크기, dir=du. 숨김(`.`) 제외 (`insights.go:112-153`) |
| System Logs | `~/Library/Logs` | du |
| Homebrew Cache | `~/Library/Caches/Homebrew` | du |
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData` | du |
| Xcode Simulators | `~/Library/Developer/CoreSimulator/Devices` | du |
| Xcode Archives | `~/Library/Developer/Xcode/Archives` | du |
| Spotify Cache | `~/Library/Application Support/Spotify/PersistentCache` | du |
| JetBrains Cache | `~/Library/Caches/JetBrains` | du |
| Docker Data | `~/Library/Containers/com.docker.docker/Data` | du |
| pip Cache | `~/Library/Caches/pip` | du |
| uv Cache | `~/.cache/uv` | du |
| Gradle Cache | `~/.gradle/caches` | du |
| CocoaPods Cache | `~/Library/Caches/CocoaPods` | du |
| OrbStack Data | `~/Library/Group Containers/*dev.orbstack/data` (첫 매치) | du |

- `~/Library/Caches` 전체는 이중 계상 방지로 의도적 제외 (`insights.go:45-48`).
- 측정 후 size 0 & complete 행은 숨김 (`json.go:97-100`, TUI 동일).

### A9. Cleanable 판정 (🧹 표시) — `cleanable.go:17-144`

`isCleanableDir(path)` = dir 이고:
1. `mo clean` 처리 경로 fragment 포함 시 **false**: `/Library/Caches/`, `/Library/Logs/`, `/Library/Saved Application State/`, `/.Trash/`, `/Library/DiagnosticReports/` (`cleanable.go:77-83`)
2. `CACHEDIR.TAG` regular file 이고 첫 43바이트가 `Signature: 8a477f597d28d172789f06886806bc55` → true (`cleanable.go:12-64`)
3. basename ∈ `projectDependencyDirs` → true:
   `node_modules bower_components .yarn .pnpm-store venv .venv virtualenv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .eggs htmlcov .ipynb_checkpoints vendor .bundle .gradle out build dist target .next .nuxt .output .parcel-cache .turbo .vite .nx coverage .coverage .nyc_output .angular .svelte-kit .astro .docusaurus DerivedData Pods .build Carthage .dart_tool .terraform`

추가 힌트: 🧹이 아니면 atime 기반 미사용 표시 — 90일 미만 없음, `>Nmo`(3–11개월), `>1yr`, `>Nyr`(2년+) (`format.go:171-195`, `view.go:562-570`).

### A10. 삭제 (휴지통 이동) — `delete.go`

| 단계 | 내용 | 근거 |
|---|---|---|
| 확인 | `⌫/delete` → 확인 프롬프트 → `Enter` 실행 / `Esc,q` 취소. 스캔 중엔 불가. 크기 unknown 항목 선택/삭제 불가 | `update.go:650-705`, `1042+` |
| 순서 | 다중 선택 시 경로 깊이 내림차순 (자식 먼저) | `delete.go:63-66` |
| 개수 | 항목당 count=1 (재귀 개수 세지 않음) | `delete.go:113-133` |
| 이동 체인 | ① `/usr/bin/trash <abs>` (30s) ② 직접 rename: 같은 볼륨이면 `~/.Trash`, 아니면 `<mount>/.Trashes/<uid>`; 소유자=uid & group/other 쓰기 불가 검증; `renameatx_np(RENAME_EXCL)`, 충돌 시 `name.<ns>.<pid>.<n>` 100회 ③ `osascript -e 'tell application "Finder" to delete POSIX file "…"'` | `delete.go:138-307` |
| 경로 검증 | 절대경로, NUL 없음, `..` 컴포넌트 없음 | `delete.go:643-658` |
| 보호 경로 (원본 + symlink 해석본 모두 검사) | 아래 표 | `delete.go:309-399` |
| 완료 후 | 뷰에서 제거, 라이브/overview/백그라운드 쓰기 cancel → `invalidateCacheAncestry`, 영향받은 히스토리 `NeedsRefresh` | `update.go:364-400` |

보호 경로:

| 규칙 | 경로 |
|---|---|
| 정확히 일치(또는 동일 inode) | `/ /Applications /Applications/Finder.app /Applications/Safari.app /Library /Library/Apple /Library/Application Support /Library/Extensions /Library/Keychains /System /Users /Volumes /Network /cores /dev /etc /home /net /tmp /var /private /private/etc /private/tmp /private/var /private/var/audit /private/var/db /private/var/root /private/var/tmp /private/var/folders /bin /sbin /usr /opt /opt/homebrew` (`delete.go:401-442`) |
| `/Users/*` 직속 (홈 디렉터리) | `delete.go:447-449` |
| 하위 트리 전체 | `/System /bin /sbin /usr /private/etc /private/var/audit /private/var/db /private/var/root /Library/Apple /Library/Extensions /Library/Keychains /Applications/Finder.app /Applications/Safari.app /dev` (`delete.go:453-474`) |
| 홈 자체 ($HOME, user.Current, symlink 해석) | `delete.go:532-555` |
| Docker Desktop / OrbStack 상태 루트와 그 **조상** | `~/Library/Containers/com.docker.docker`, `~/.orbstack`, `~/Library/Group Containers/*dev.orbstack` (`delete.go:349-396`) |
| iCloud 구조 | `~/Library/Mobile Documents` 및 그 조상, 직속 컨테이너(depth1), `<container>/Documents`(depth2) — **디렉터리만**; 파일은 허용 (`delete.go:484-530`) |
| `/var/folders` 상위 3단계 이내 또는 EDR 번들 접두 | `com.crowdstrike. com.sentinelone. com.sentinel-labs. com.eset. com.jamf. com.jamfsoftware. com.paloaltonetworks. com.cisco.anyconnect com.cisco.secureclient com.alibaba.security.` (`delete.go:604-639`) |

### A11. 감사 로그 (oplog) — `oplog.go`

| 항목 | 내용 |
|---|---|
| 비활성화 | `MO_NO_OPLOG=1` (`oplog.go:42-44`) |
| operations.log | `~/Library/Logs/mole/operations.log` 추가 기록. 세션 헤더 `# ========== analyze run=<YYYYMMDDhhmmss-pid-r1-r2> session started at <ts> ==========`, 항목 `[ts] [analyze run=…] TRASHED <path> (1.23GB)` / `FAILED <path> (protected|removal timed out|permission denied|trash-failed)`, 푸터 `… session ended at <ts>, N items, <size> ==========` (`oplog.go:150-217`) |
| deletions.log | `$MOLE_DELETE_LOG` 또는 `~/Library/Logs/mole/deletions.log`; TSV `ISO8601(-0700)\ttrash\t<KB 올림>\tok|trash-failed\t<path>` (`oplog.go:62-71`, `197-207`) |
| 크기 표기 | SI 10진: ≥1e9 `x.xxGB`, ≥1e6 `x.xMB`, ≥1e3 `xKB`, else `xB` (`oplog.go:98-111`) |
| 이스케이프 | `\n \r \t`, 제어문자 `\xNN` (`oplog.go:76-94`) |
| NotExist | 기록 생략 (`oplog.go:176-178`) |
| 쓰기 실패 | 상태줄에 "audit log unavailable" (`oplog.go:221-226`) |

### A12. JSON 출력 (`--json`, `json.go`)

```jsonc
{
  "scan_status": "complete|partial|unavailable",
  "path": "/abs/path",            // overview면 "/"
  "overview": false,
  "entries": [{
    "scan_status": "complete", "name": "node_modules", "path": "/…",
    "size": 123, "is_dir": true,
    "insight": true,              // overview 전용, omitempty
    "cleanable": true,            // omitempty (isCleanableDir)
    "last_access": "RFC3339 UTC"  // omitempty (atime)
  }],
  "large_files": [{"name":"…","path":"…","size":0}],  // omitempty, 디렉터리 모드만
  "total_size": 0,
  "total_files": 0                // omitempty
}
```
- 디렉터리 모드: **전체 entries**(Top-30 제한 없음), Spotlight 사용 (`json.go:60-80`).
- overview 모드: 8개 병렬 측정, 스냅샷/디렉터리 캐시 우선, size 0 complete 제외, 크기 내림차순 (`json.go:88-164`).
- 2-space indent, 실패 시 stderr + exit 1.

### A13. TUI 뷰/키 (간략) — `update.go:635-1100`, `view.go`

| 키 | 동작 |
|---|---|
| `↑/k`, `↓/j` | 이동 |
| `Enter/→/l` | 디렉터리 진입 |
| `←/h/b` | 뒤로(히스토리) |
| `Esc` | 필터 해제 → large 뷰 닫기 → 뒤로 |
| `r` | refresh (overview: 전 행 캐시 무효화+재측정+스냅샷 재조회; dir: `invalidateCacheTree` + 캐시 우회 재스캔) (`update.go:789-830`) |
| `t` | Top large files 토글 (스캔 완료 후) |
| `/` | 필터 입력 (Enter 적용, Esc 해제) |
| `s` | live sort 모드 토글 (스캔 중) |
| `o` | 열기 (`open`, 다중 최대 20) |
| `f` | Finder에서 보기 (`open -R`, 최대 20) |
| `p` | Quick Look/기본 앱 미리보기 (`open`) |
| `Space` | 다중 선택 토글 (상태줄 "N selected, size") |
| `⌫/Delete` | 휴지통 이동 확인 |
| `q`, `Ctrl+C` | 종료 (삭제 중에도 q/r만 허용) |
- 행: 이름, 크기, 비율 막대(`barWidth=24`, 8분할 블록), 퍼센트, 힌트(🧹/미사용기간). 크기 표기 `units.BytesSI`(1000 기반, `"%.1f kB/MB…"`, `internal/units/bytes.go:18-43`).

---

## Part B. STATUS (시스템 모니터)

### B1. 실행 모드 / 주기

| 모드 | 동작 | 근거 |
|---|---|---|
| TUI | 기본(stdout이 TTY일 때) | `status/main.go:300-306`, `392-396` |
| `--json` 또는 stdout 비-TTY | Full 수집 1회, indent JSON; 핵심 지표(CPU logical>0 / mem total>0 / 프로세스 / 디스크) 없으면 exit 1 | `main.go:36-48`, `253-297` |
| `--watch [--interval 1s]` | NDJSON 스트림, 스케줄러로 fast/process/full 혼합 | `watch.go:22-40` |
| 플래그 | `--proc-cpu-alerts`(true) `--proc-cpu-threshold`(100%) `--proc-cpu-window`(5m) | `main.go:24-34` |

수집 스케줄 (`collection.go:37-71`, `main.go:18-22`):

| 모드 | 조건 | 내용 |
|---|---|---|
| fast | 첫 수집 / 기본 | CPU(비샘플), 메모리(gopsutil만), 디스크(보정 없음), 디스크IO, 네트워크 |
| process | 마지막 process 시도 후 ≥1s | fast + `ps` 프로세스 |
| full | 마지막 full 후 ≥30s (`slowRefreshInterval`) | 전부 + 보정/enrichment 캐시 갱신 |
| 간격 | 완료 후 1s (첫 fast 직후엔 0 → 즉시 full) | |
| enrichment | full 결과(하드웨어, P/E코어, cached/pressure, 보정 디스크, GPU, 휴지통, 프록시, 배터리, thermal, BT)를 이후 fast 스냅샷에 덮어쓰고 health score 재계산 | `metrics.go:658-715` |
| 프로세스 stale | fast 스냅샷엔 직전 프로세스 데이터 + `process_stale=true` | `metrics.go:703-715` |
| 애니메이션 | 고양이 프레임 `max(300 - cpu*2.5, 50)` ms | `main.go:246-250` |

### B2. 지표별 수집 방법

#### CPU — `metrics_cpu.go`

| 지표 | 방법 | 주기/캐시 | 근거 |
|---|---|---|---|
| 물리/논리 코어 | gopsutil `cpu.Counts(false/true)` (내부 sysctl `hw.physicalcpu`/`hw.logicalcpu`, 추정) → 실패 시 `runtime.NumCPU` | 매 수집 | `:29-40` |
| 사용률(full) | `cpu.Times(true)` 두 번, 100ms 간격 → busy=user+system+nice+irq+softirq+steal; core% = busy/max(busy+Δidle, elapsed)×100; total = Σbusy/Σwindow (gopsutil darwin 내부는 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, 추정) | full | `:300-368` |
| 사용률(fast) | `cpu.Percent(0, true)` (직전 호출 대비 델타) 평균; 실패 시 0 배열 + `per_core_estimated` | fast | `:58-85` |
| fallback | `ps -Aceo pcpu` 합 / logical (500ms) | full 실패 시 | `:240-292` |
| Load avg | gopsutil `load.Avg()` (sysctl `vm.loadavg`, 추정) → 0이면 `uptime` 파싱 | 매 수집 | `:87-96`, `188-238` |
| P/E 코어 | `/usr/sbin/sysctl -n hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu` (500ms) | 10분 캐시, full만 | `:122-186` |
| 온도 | **수집 안 함** (`CPUTemp` 항상 0; 의도적으로 합성 금지) | — | `metrics_battery.go:390-392` |

#### Memory — `metrics_memory.go`

| 지표 | 방법 | 근거 |
|---|---|---|
| Total/Used/Available/UsedPercent | gopsutil `mem.VirtualMemory()` (darwin: `hw.memsize` + `host_statistics64(HOST_VM_INFO64)`; v4 기준 Available≈free+inactive, Used=Total−Available — 추정) | `:22-25` |
| Swap | `mem.SwapMemory()` (sysctl `vm.swapusage`, 추정) | `:27-30` |
| Cached | `vm.Cached`, 0이면(full) `vm_stat`의 `File-backed pages` × page size(헤더 파싱, 기본 4096) | `:37-40`, `54-91` |
| Pressure | (full) `memory_pressure` 출력에 critical/warn/normal 포함 여부 (500ms) | `:93-114` |

#### Disk — `metrics_disk.go`

| 지표 | 방법 | 근거 |
|---|---|---|
| 파티션 | gopsutil `disk.Partitions(false)` (getfsstat) | `:68` |
| 제외 | `/dev/loop*`, `/System/Volumes/*`(VM,Preboot,Update,xarts,Hardware,Data 포함), `/private/*`, `/dev`, fstype ∈ {afpfs autofs cifs devfs fuse* macfuse nfs osxfuse procfs smbfs tmpfs webdav}, device가 `/dev/`로 시작 안 함 | `:20-45`, `149-175` |
| 중복 제거 | base device(`disk3s1`→`disk3`)당 1개 | `:83-89`, `238-249` |
| 사용량 | `disk.Usage(mount)` (statfs) | `:90` |
| Total 보정(full) | `diskutil info -plist <mount>` (3s, mount당 1회 공유)의 `TotalSize/DiskSize/Size`가 statfs와 1GiB 이상 차이면 교체 | `:308-369` |
| 1GiB 미만 | 제외 | `:104` |
| APFS Used 보정(full) | `/`: `osascript 'tell application "Finder" to return {free space of startup disk, capacity of startup disk}'` (5s, 2분 캐시, 실패도 캐시) → used=cap−free, **purgeable = finderFree − statfsFree**. 그 외 APFS: `APFSContainerFree`로 used=total−containerFree (raw보다 1GiB+ 작을 때만) | `:382-475` |
| External/SMART(full) | `diskutil info <baseDevice>` (1s, 2분 캐시) `Internal:` / `Device Location:` / `SMART Status:` → verified/failing/unsupported/unknown | `:204-301` |
| 정렬/개수 | 내부 먼저, 용량 큰 순, 최대 3개 | `:133-146` |
| Disk IO | gopsutil `disk.IOCounters()` 전 디스크 ReadBytes/WriteBytes 합 델타 / 경과초 → MB/s (MiB). 첫 샘플 0 (darwin 내부: IOKit `IOBlockStorageDriver` Statistics, 추정) | `:512-556` |
| Trash 크기(full) | `~/.Trash` WalkDir 논리 크기 합, 2s 타임아웃(초과 시 `trash_approx=true`), 5s 캐시 | `:560-608` |

#### Network — `metrics_network.go`

| 지표 | 방법 | 근거 |
|---|---|---|
| 카운터 | gopsutil `net.IOCounters(true)` (pernic). Collector 생성 시 prime | `:17`, `35-44` |
| 기본 경로 IF(full) | `route -n get default` → `interface:` (500ms) | `:144-158` |
| 필터 | noise 접두 `lo awdl utun llw bridge gif stf xhc anpi ap` 및 터널(`utun tun ipsec ppp`) 제외, 단 기본 경로 IF는 유지 | `:24`, `88-92`, `160-167` |
| 속도 | Δbytes / 1024² / max(elapsed, 0.1s) → MB/s | `:83-98` |
| 정렬 | 기본 경로 터널 우선, rx+tx 큰 순, 최대 3개(기본 IF 강제 포함) | `:114-131` |
| 히스토리 | Ring buffer 120개, 합계(기본 터널 있으면 그것만) rx/tx | `:133-137`, `metrics.go:19-60, 190` |
| IP | gopsutil `net.Interfaces()` 첫 IPv4(비-127), 10s 캐시 | `:182-208` |
| Proxy(full) | ① env `https_proxy/HTTPS_PROXY/http_proxy/HTTP_PROXY/all_proxy/ALL_PROXY` ② `scutil --proxy` (SOCKS→HTTPS→HTTP→PAC→WPAD 우선순위) ③ 트래픽 있는 `utun*/tun*` → `TUN` | `:220-349` |

#### Battery / Power / Thermal — `metrics_battery.go`

| 지표 | 방법 | 주기 | 근거 |
|---|---|---|---|
| %/상태/남은시간 | `pmset -g batt` (1s): `%` 토큰, 다음 토큰=상태(`charging;` 등), `remaining` 앞 토큰=시간 | full | `:37-47`, `76-127` |
| Health/Cycle/Capacity | `system_profiler SPPowerDataType -json` (`sppower_battery_health`, `_cycle_count`, `_health_maximum_capacity`) → 실패 시 텍스트(`Cycle Count`, `Condition`, `Maximum Capacity`) | 30s 캐시, 3s 타임아웃 | `:130-219`, `298-344` |
| ioreg 보정 | `ioreg -rn AppleSmartBattery`: `CycleCount`(우선), capacity = round((`AppleRawMaxCapacity` or `NominalChargeCapacity`)/`DesignCapacity`×100) clamp 0–100 (system_profiler 값 없을 때만) | full, 500ms | `:150-160`, `221-296` |
| 배터리 온도 | 같은 ioreg `Temperature` (<1000이면 그대로, 아니면 /100 °C); 0이면 `ioreg -rc AppleSmartBatteryPack -l` (macOS 27) | full | `:371-388`, `406-413` |
| 시스템 전력 | `SystemPowerIn` → 없으면 `SystemPower` (mW→W, 0–1000W) | full | `:426-433`, `465-470` |
| 배터리 전력 | `BatteryPower`(mW, 부호) → 없으면 −(Voltage|AppleRawBatteryVoltage mV × InstantAmperage|Amperage mA)/1e6, ±200W | full | `:436-461` |
| 어댑터 W | `"AdapterDetails"` 줄의 `Watts` (AppleRaw 제외) | full | `:418-423` |
| 팬 속도 | `system_profiler SPPowerDataType` 텍스트에 "fan…speed" 줄 (대부분 기기에서 없음 → 0, 추정) | full | `:354-366` |
| 음수 처리 | ioreg의 uint64 2의 보수 → 음수 | | `:503-520` |
| 라벨 | capacity<60 "Service Soon"(danger); cycles>1000 또는 cap<80 "Fair"(warn); cap 미상 → unknown(사이클만으로 Healthy 금지); else "Healthy" | | `metrics_health.go:230-241` |

#### GPU — `metrics_gpu.go`

| 지표 | 방법 | 주기 | 근거 |
|---|---|---|---|
| 이름/코어/VRAM/Metal/Vendor | `system_profiler -json SPDisplaysDataType` (`_name`, `sppci_cores`, `spdisplays_vram`, `spdisplays_metal`, `spdisplays_vendor`) | 10분 캐시, 4s | `:94-153` |
| 사용률 | `powermetrics --samplers gpu_power -i 500 -n 1` → `GPU HW active residency: X%` 또는 100−idle. **root 필요** → 일반 실행 시 실패 → `-1` | 5s 캐시, 2s | `:155-196` |
| 비-mac | `nvidia-smi` | | `:50-91` |

#### Bluetooth — `metrics_bluetooth.go`

| 지표 | 방법 | 주기 | 근거 |
|---|---|---|---|
| 기기/연결/배터리 | `system_profiler SPBluetoothDataType` 텍스트(들여쓰기 8칸 `Name:` 블록, `Connected: Yes`, `Battery Level:`) → fallback `bluetoothctl info` | 30s 캐시, 4s | `:16-111`, `metrics.go:488-498` |
| 표시 | TUI 카드에는 없음, JSON만 | | `view.go:721-733` |

#### Hardware — `metrics_hardware.go` (10분 캐시, `metrics.go:504-518`)

| 지표 | 방법 | 근거 |
|---|---|---|
| Model | `system_profiler SPHardwareDataType` `Model Name:` (3s) | `:30-40` |
| CPU 모델 | 같은 출력 `Chip:` → 없으면 `Processor Name:` | `:41-52` |
| OS | `sw_vers -productVersion` → `"macOS X.Y"` | `:56-61` |
| 주사율 | `system_profiler -detailLevel mini SPDisplaysDataType` 의 최대 `NNHz` (<500) | `:64-69`, `89-120` |
| RAM/Disk 크기 | mem total, disks[0].total 의 `units.BytesBin`(1024 기반) | `:79-86` |

#### Host / Processes

| 지표 | 방법 | 근거 |
|---|---|---|
| hostname/platform/uptime/procs | gopsutil `host.Info()` (sysctl `kern.boottime` 등, 추정) | `metrics.go:331-337`, `587-596` |
| 프로세스 | `ps -Aceo pid=,ppid=,state=,pcpu=,pmem=,rss=,comm= -r` (3s); 엄격 파싱 실패 시 `ps aux` (ppid 없음) | `metrics_process.go:24-119` |
| Top 5 | CPU desc → MEM desc → PID asc 힙 | `metrics_process.go:221-261`, `metrics.go:561` |
| Zombie | state `Z*` 개수, 부모별 상위 3 (`zombie_parents_complete`) | `metrics_process.go:139-200` |
| pcpu 의미 | `ps`의 %CPU는 감쇠 평균(순간값 아님), 멀티코어 100% 초과 가능 | (ps 동작) |

#### Process Watch (고CPU 알림) — `process_watch.go`

- 키 = `(pid, ppid, command)`; `cpu ≥ threshold`가 연속 `window` 이상이면 `triggered_at` 기록, `status:"active"`. 임계 미만이 한 번이라도 나오면 리셋; 사라진 프로세스는 추적 해제 (`:64-111`).
- 정렬: triggered_at 오름차순 → CPU desc → PID (`:136-147`).
- TUI 상단 alert bar (`main.go:174-179`).

#### Health Score — `metrics_health.go:64-214`

시작 100점에서 감점 후 [0,100] clamp, `int()` 절삭.

| 항목 | 가중치 | 규칙 |
|---|---|---|
| CPU | 30 | u≤50: 0; 50<u≤85: 15×(u−50)/35; u>85: 30×(u−50)/50, 이슈 "High CPU" |
| Memory | 25 | p≤70: 0; 70<p≤88: 12.5×(p−70)/18; p>88: 25×(p−70)/30, "High Memory" |
| Mem pressure | — | warn −5 "Memory Pressure"; critical −15 "Critical Memory" |
| Disk (disks[0]) | 20 | d≤80: 0; 80<d≤93: 10×(d−80)/13; d>93: 20×(d−80)/20. used≥90% && free<30GB → "Disk Almost Full" |
| SMART failing | — | 점수 상한 44, "Disk SMART Failing" |
| Thermal (CPUTemp>0일 때만) | 15 | 65<t≤85: 15×(t−65)/20; t>85: 15 "Overheating" — **현재 CPUTemp 미수집이라 사실상 비활성** |
| Disk IO (R+W MB/s) | 10 | 50<io≤150: 10×(io−50)/100; >150: 10 "Heavy Disk IO" |
| Battery[0] | — | danger −5 "Battery Service Soon"; warn −2 |
| Uptime | — | >14일 −3 "Restart Recommended"; >7일 −1 |
| 메시지 | | ≥85 Excellent, ≥65 Good, ≥45 Fair, else Needs Attention; 이슈 있으면 `": a, b"` 접미 |

#### Diagnosis 한 줄 — `diagnosis.go:8-55` (우선순위 순)

1. SMART failing → "SMART failing, back up now"
2. CPU>85 → (신선한 프로세스 중 CPU≥50 최고) "`<name>` high CPU" / "CPU load high"
3. pressure warn/critical 또는 mem>88 → "`<name>` memory pressure" / "Memory pressure high"
4. 루트(또는 첫) 디스크 critical → "Disk low, X free"
5. 배터리 cap<80 "Battery health low" / cycles>1000 "Battery cycles high"
6. CPUTemp>65 "CPU temperature high"
7. IO>150 "Disk I/O busy"
8. HealthScoreMsg에 `:` 있으면 그 메시지, 아니면 "All clear"

### B3. Prefs 파일 — `prefs.go`

| 항목 | 내용 |
|---|---|
| 경로 | `~/.config/mole/status_prefs` (`:23-29`) |
| 포맷 | `key=value` 줄, `#` 주석, 키 정렬 저장 (`:34-58`, `89-106`) |
| 동시성 | `status_prefs.lock` 에 `flock(LOCK_EX)`, temp+fsync+rename 원자 쓰기 (`:63-139`) |
| 키 | `cat_hidden=true|false` (키 `k`), `cpu_cores` ∈ {2,4,8,0(=전체)} 순환 (키 `c`); 화면 높이 부족 시 자동 축소 (`:144-201`, `main.go:220-225`) |
| TUI 키 | `q/Esc/Ctrl+C` 종료, `k` 고양이, `c` 코어 수 (`main.go:116-129`) |
| 카드 | CPU, Memory, Disk, Power(배터리), Processes, Network (≤80열 1열, 그 외 2열). Sensors 카드 비활성 (`view.go:721-733`) |
| 바이트 표기 | `units.BytesBin`/`BytesBinShort`/`BytesBinCompact` (1024 기반) (`view.go:1095-1103`) |

### B4. JSON / NDJSON 스키마 (`MetricsSnapshot`, `metrics.go:62-234`, `process_watch.go:14-29`)

```jsonc
{
  "collected_at": "RFC3339Nano", "host": "", "platform": "darwin 15.x",
  "uptime": "3d 4h", "uptime_seconds": 0, "procs": 0,
  "hardware": {"model":"","cpu_model":"","total_ram":"16.0 GB","disk_size":"","os_version":"macOS 15.1","refresh_rate":"120Hz"},
  "health_score": 0, "health_score_msg": "Good: High CPU",
  "cpu": {"usage":0,"per_core":[0],"per_core_estimated":false,"load1":0,"load5":0,"load15":0,
          "core_count":0,"logical_cpu":0,"p_core_count":0,"e_core_count":0},
  "gpu": [{"name":"","usage":-1,"memory_used":0,"memory_total":0,"core_count":0,"note":""}],
  "memory": {"used":0,"total":0,"available":0,"used_percent":0,"swap_used":0,"swap_total":0,"cached":0,"pressure":"normal|warn|critical|"},
  "disks": [{"mount":"/","device":"/dev/disk3s1","used":0,"total":0,"used_percent":0,"fstype":"apfs",
             "external":false,"smart_status":"verified|failing|unsupported|unknown","purgeable":0 /*omitempty*/}],
  "trash_size": 0, "trash_approx": false,
  "disk_io": {"read_rate":0,"write_rate":0},            // MB/s
  "network": [{"name":"en0","rx_rate_mbs":0,"tx_rate_mbs":0,"ip":""}],
  "network_history": {"rx_history":[],"tx_history":[]}, // ≤120
  "proxy": {"enabled":false,"type":"HTTP|HTTPS|SOCKS|PAC|WPAD|TUN","host":""},
  "batteries": [{"percent":0,"status":"charging","time_left":"2:10","health":"Normal","cycle_count":0,"capacity":0}],
  "thermal": {"cpu_temp":0,"gpu_temp":0,"battery_temp":0,"fan_speed":0,"fan_count":0,
              "system_power":0,"adapter_power":0,"battery_power":0},
  "sensors": null,                                       // 수집 비활성 (metrics.go:480)
  "bluetooth": [{"name":"","connected":false,"battery":""}],
  "top_processes": [{"pid":0,"ppid":0,"name":"","command":"","cpu":0,"memory":0,"memory_bytes":0}],
  "process_collected_at": "…", "process_stale": false,  // omitempty 포인터
  "zombie_count": 0, "zombie_parents": [{"pid":0,"name":"","count":0}], "zombie_parents_complete": true,
  "process_watch": {"enabled":true,"cpu_threshold":100,"window":"5m0s"},
  "process_alerts": [{"pid":0,"name":"","command":"","cpu":0,"threshold":100,"window":"5m0s","triggered_at":"…","status":"active"}]
}
```
- `--watch`: 위 객체를 한 줄씩(인덴트 없음) 출력, stdout 닫히면 종료 (`watch.go:22-40`).
- 모든 shell-out은 `LC_ALL=C` 강제(LANG/LC_* 제거) (`metrics.go:717-742`).
- `MOLE_TEST_MODE=1`/`MOLE_TEST_NO_AUTH=1`이면 Finder osascript 생략 (`metrics_disk.go:425-437`).

---

## Part C. Swift 포팅 노트

### C1. Status 데이터 소스 매핑

| 지표 | Mole 소스 | Swift/Darwin 대체 | shell/root 필요 |
|---|---|---|---|
| CPU 틱/코어% | gopsutil cpu.Times | `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO)` → `cpu_ticks[USER,SYSTEM,NICE,IDLE]` 델타; 끝나면 `vm_deallocate` | 아니오 |
| 코어 수/P·E | gopsutil, `sysctl` CLI | `sysctlbyname("hw.physicalcpu"/"hw.logicalcpu"/"hw.perflevel0.logicalcpu"/"hw.perflevel1.logicalcpu")` | 아니오 |
| Load avg | gopsutil load / `uptime` | `getloadavg(&arr, 3)` | 아니오 |
| 메모리 | gopsutil mem, `vm_stat` | `sysctlbyname("hw.memsize")`, `host_statistics64(HOST_VM_INFO64)` → `vm_statistics64`(free, active, inactive, wire, compressor_page_count, external_page_count=file-backed, purgeable), `vm_kernel_page_size`. Mole 호환: Available=free+inactive (추정치 재현 시 검증) | 아니오 |
| Swap | gopsutil | `sysctlbyname("vm.swapusage")` → `xsw_usage` | 아니오 |
| Memory pressure | `memory_pressure` CLI | `sysctlbyname("kern.memorystatus_vm_pressure_level")` (1=normal, 2=warn, 4=critical) 또는 `DispatchSource.makeMemoryPressureSource` | 아니오 |
| 볼륨 목록/용량 | gopsutil partitions/usage | `getfsstat(MNT_NOWAIT)` 또는 `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options:[.skipHiddenVolumes])` + `URLResourceValues.volumeTotalCapacity/.volumeAvailableCapacity/.volumeIsInternal/.volumeIsLocal/.volumeIsBrowsable/.volumeLocalizedFormatDescription` | 아니오 |
| Finder 여유/purgeable | `osascript` Finder | `volumeAvailableCapacityForImportantUsage` (purgeable 포함, Finder 값과 유사) − `volumeAvailableCapacity` = purgeable 근사. AppleScript 자동화 TCC 불필요해짐 | 아니오 |
| APFSContainerFree / TotalSize | `diskutil info -plist` | DiskArbitration `DADiskCopyDescription`(`kDADiskDescriptionMediaSizeKey`, `…DeviceInternalKey`) / APFS container free는 공개 API 없음 → `diskutil info -plist` shell + `PropertyListSerialization` 유지 권장 | shell(무권한) |
| SMART | `diskutil info` | IOKit: NVMe `IONVMeSMARTUserClient`(비공개 성격) → 실용적으로 `diskutil info -plist` 의 `SMARTStatus` 키 | shell(무권한) |
| Disk IO | gopsutil disk.IOCounters | IOKit `IOServiceGetMatchingServices(IOServiceMatching("IOBlockStorageDriver"))` → `Statistics` dict `"Bytes (Read)"`/`"Bytes (Write)"` | 아니오 |
| 휴지통 크기 | WalkDir `~/.Trash` | `FileManager.enumerator` + `.totalFileAllocatedSizeKey` — **Full Disk Access 없으면 `~/.Trash` 읽기 EPERM** (TCC) | FDA |
| NIC 카운터 | gopsutil net.IOCounters | `sysctl([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0])` → `if_msghdr2.ifm_data`(`if_data64`, 64bit). `getifaddrs`의 `AF_LINK if_data`는 32bit라 4GB wrap 주의 | 아니오 |
| IP | gopsutil Interfaces | `getifaddrs` AF_INET | 아니오 |
| 기본 경로 IF | `route -n get default` | `SCDynamicStoreCopyValue("State:/Network/Global/IPv4")["PrimaryInterface"]` 또는 `NWPathMonitor` | 아니오 |
| Proxy | `scutil --proxy` | `CFNetworkCopySystemProxySettings()` (HTTPEnable/HTTPSEnable/SOCKSEnable/ProxyAutoConfigEnable…) | 아니오 |
| 배터리 %/상태/시간 | `pmset -g batt` | `IOPSCopyPowerSourcesInfo` + `IOPSCopyPowerSourcesList` + `IOPSGetPowerSourceDescription` (`kIOPSCurrentCapacityKey`, `kIOPSMaxCapacityKey`, `kIOPSIsChargingKey`, `kIOPSTimeToEmptyKey`, `kIOPSPowerSourceStateKey`, `kIOPSBatteryHealthKey`); 변화 알림 `IOPSNotificationCreateRunLoopSource` | 아니오 |
| Cycle/Design/RawMax/온도/전력 | `ioreg -rn AppleSmartBattery`, `system_profiler` | `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))` + `IORegistryEntryCreateCFProperties`: `CycleCount`, `DesignCapacity`, `NominalChargeCapacity`, `AppleRawMaxCapacity`, `Temperature`(centi-°C), `Voltage`, `InstantAmperage`, `Amperage`, `AdapterDetails.Watts`, `PowerTelemetryData`(`SystemPowerIn`, `BatteryPower`). macOS 27은 `AppleSmartBatteryPack` 자식 확인 (`IORegistryEntrySearchCFProperty` with `kIORegistryIterateRecursively`) | 아니오 |
| 어댑터 W | ioreg | `IOPSCopyExternalPowerAdapterDetails()` `Watts` | 아니오 |
| 팬/CPU 온도 | (없음/불완전) | AppleSMC `IOServiceOpen` + `IOConnectCallStructMethod`(키 `F0Ac`, `TC0P`/Apple Silicon `Tp*`) — 비공개, 무root 동작하나 키가 기종별. 선택 기능으로 | 아니오(비공개 API) |
| GPU 정적 정보 | `system_profiler SPDisplaysDataType` | IOKit `IOAccelerator` 서비스 `model`, `gpu-core-count`; 또는 `MTLCopyAllDevices()` 이름 | 아니오 |
| GPU 사용률 | `powermetrics` (**root**) | IOKit `IOAccelerator` → `PerformanceStatistics["Device Utilization %"]` — root 불필요, Mole보다 개선 | 아니오 |
| Bluetooth | `system_profiler SPBluetoothDataType` | `IOBluetoothDevice.pairedDevices()` + `isConnected()`; 배터리는 IORegistry `BatteryPercent`(HID 기기) 또는 system_profiler 유지. `NSBluetoothAlwaysUsageDescription` TCC 필요 | TCC |
| 모델명/칩 | `system_profiler SPHardwareDataType` | `sysctlbyname("hw.model")`(식별자), `machdep.cpu.brand_string`(칩명). 마케팅명은 공개 API 없음 → system_profiler 1회 shell 후 캐시 | shell(1회) |
| OS 버전 | `sw_vers` | `ProcessInfo.processInfo.operatingSystemVersion(String)` | 아니오 |
| 주사율 | system_profiler | `NSScreen.screens.map(\.maximumFramesPerSecond)` 최댓값 | 아니오 |
| 호스트/업타임 | gopsutil host | `ProcessInfo.hostName`/`gethostname`, `sysctl kern.boottime`, `ProcessInfo.systemUptime` | 아니오 |
| 프로세스 목록 | `ps -Aceo …` | `proc_listallpids` + `proc_pidinfo(PROC_PIDTBSDINFO)`(ppid, `pbi_status==SZOMB`, comm) + `proc_pidinfo(PROC_PIDTASKINFO)`(pti_total_user/system 델타 → CPU%, `pti_resident_size`). 타 사용자/root 프로세스의 TASKINFO는 EPERM 가능 → 커버리지 검증 필요, 부족하면 `ps` shell 유지 | 부분(검증) |
| 로컬 스냅샷 | `tmutil listlocalsnapshots /` | 공개 API 없음 → shell 유지 | shell(무권한) |

- 수집 스레드: Swift `actor StatusCollector` + `Task` 그룹으로 지표 병렬 수집 (Mole `collectConcurrently`, `metrics.go:339-374` 대응). fast/process/full 스케줄과 enrichment 덮어쓰기 로직은 그대로 이식.
- 1s 주기 UI: 델타 기반 지표(CPU, IO, NIC)는 이전 샘플 보관 필요. Mole full은 100ms 슬립 샘플링 → Swift에서는 1s tick 델타만 사용하면 슬립 불필요.
- 모든 `Process` shell-out에 타임아웃 + `LC_ALL=C` 환경 강제 유지.

### C2. Analyze 포팅 매핑

| Mole | Swift 대체 | 비고 |
|---|---|---|
| `os.ReadDir` + `lstat` | `getattrlistbulk(2)` (ATTR_CMN_NAME/OBJTYPE/FILEID/DEVID, ATTR_FILE_LINKCOUNT/ALLOCSIZE/DATALENGTH, ATTR_CMN_ACCTIME) — 디렉터리당 syscall 수 최소, 가장 빠름 | `FileManager.enumerator`는 NSURL 객체 생성 비용으로 수 배 느림 |
| (대안) | `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.fileAllocatedSizeKey,.totalFileAllocatedSizeKey,.fileSizeKey,.linkCountKey,.fileResourceIdentifierKey,.contentAccessDateKey])` prefetch | 키 prefetch 필수 |
| `getActualFileSize` = min(blocks×512, size) | `min(fileAllocatedSize, fileSize)` 로 동일 재현 (du 시맨틱 원하면 `totalFileAllocatedSize`) | 캐시 스키마에 시맨틱 버전 기록 |
| 하드링크 dedupe `(dev, ino)` | `linkCount>1` 일 때 `Set<(dev_t, ino_t)>` (스캔 단위, lock 또는 actor) | |
| APFS clone dedupe | Darwin `getattrlist` 직접 호출, `attrlist.forkattr = ATTR_CMNEXT_CLONEID|ATTR_CMNEXT_EXT_FLAGS`, opts `FSOPT_NOFOLLOW|FSOPT_ATTR_CMN_EXTENDED`; `EF_SHARES_ALL_BLOCKS(0x40)` | getattrlistbulk에서도 같은 attr 요청 가능 → 파일당 추가 syscall 제거 |
| `/usr/bin/du -skPx` | 외부 du 유지 가능(비샌드박스) 또는 자체 walker. 자체 walker 시 `-x`(볼륨 경계: `st_dev` 비교), `-P`(symlink 미추적), 하드링크 1회 계수 재현 | du는 할당 블록 기준이라 자체 walker 값과 다를 수 있음 |
| `mdfind -onlyin` | `NSMetadataQuery`(predicate `kMDItemFSSize >= 104857600`, `searchScopes=[root]`) 또는 `MDQueryCreate` | 5s 타임아웃 유지 |
| `tmutil listlocalsnapshots /` | shell 유지 | |
| `getfsstat` 볼륨 | `getfsstat` 동일 사용 또는 `mountedVolumeURLs` + `.volumeIsLocal/.volumeIsReadOnly/.volumeIsBrowsable` | |
| `statfs` free | `URLResourceValues.volumeAvailableCapacityForImportantUsage` | |
| 휴지통 이동 체인 | `FileManager.trashItem(at:resultingItemURL:)` 1개로 대체 (볼륨별 `.Trashes` 처리 포함, "되돌리기" 메타데이터 유지) | 실패 시에만 rename fallback |
| `open`, `open -R`, Quick Look | `NSWorkspace.shared.open(url)`, `activateFileViewerSelecting([url])`, `QLPreviewPanel` | |
| gob 캐시 | `Codable` + `PropertyListEncoder(.binary)` 또는 JSON; 위치 `~/Library/Caches/<bundleID>/analyzer/` | 파일명 해시는 SHA256/xxhash 아무거나, 스키마 버전 필드 필수 |
| `scanPublication` | Swift `Task` 취소 + 결과 반영 전 `scanID` 비교(모델은 `@MainActor`) | rules의 "superseded/canceled 결과 거부" 동일 적용 |
| 로그 | `~/Library/Logs/<app>/operations.log` 동일 포맷 유지 권장 (Mole과 공존 시 경로 분리) | |

### C3. 권한 / 배포 제약

| 항목 | 영향 |
|---|---|
| App Sandbox | 임의 경로 스캔·`du`/`diskutil`/`tmutil` 실행·IOKit 일부 접근 불가 → **비샌드박스 + Developer ID 배포** 필요 |
| Full Disk Access (TCC) | `~/Library/Mail`, `~/Library/Safari`, `~/.Trash`, Time Machine, 타 앱 컨테이너 등 EPERM. 미허용 시 partial(권한 실패) 처리 + FDA 안내 UI. Mole의 "권한 실패=영구, 캐시 가능" 분류를 그대로 이식 |
| root | Mole 기준 필요한 곳은 `powermetrics`(GPU%)뿐 → IOAccelerator로 대체하여 **root 불필요** 목표. SMC 온도는 무root 가능(비공개 API) |
| Automation TCC | Mole의 Finder osascript(디스크 free, 휴지통 fallback)는 Apple Events 권한 프롬프트 유발 → `volumeAvailableCapacityForImportantUsage` / `trashItem`으로 제거 |
| Bluetooth TCC | IOBluetooth 사용 시 Info.plist 사용 설명 필요 |

### C4. 대용량 트리 스캔 성능 주의

| 위험 | 대책 |
|---|---|
| 스레드 폭증 (Mole #765: 블로킹 syscall마다 OS 스레드) | GCD에 블로킹 I/O를 무제한 dispatch 금지. 고정 크기 워커(≈`clamp(NCPU,2,12)`) + 작업 큐(DFS 스택) 사용. Swift Concurrency 협력 풀에서 블로킹 syscall 장시간 수행 금지 → 전용 `Thread`/`DispatchQueue` 풀 |
| 세마포어 포화 시 deadlock | Mole처럼 "획득 실패 시 현재 스레드에서 인라인 재귀" 또는 work-stealing 큐 |
| 객체 할당 비용 | URL/NSString 대신 `getattrlistbulk` 버퍼 직접 파싱, 경로는 부모 인덱스+이름으로 보관, 디렉터리별 합계만 유지(파일 개별 객체 미보관). Top-N은 힙 |
| UI 업데이트 폭주 | 이벤트는 누적, 100ms tick에서 1회 정렬/diff (Mole `uiTickInterval`) ; SwiftUI `List` 대량 행 → 표시 행 30개 수준 유지 |
| iCloud/FileProvider 블록 | `Mobile Documents` 기본 skip(overview), dataless 파일(`SF_DATALESS`, `ATTR_CMNEXT_*`)은 다운로드 유발 API(`contents`) 호출 금지 |
| 네트워크/가상 마운트 | `defaultSkipDirs`, `MNT_LOCAL` 필터, `st_dev` 경계 유지 |
| 하드링크 Set 메모리 | `linkCount>1`인 파일만 Set에 삽입 (Mole 동일) |
| 캐시 폭증 (Mole 1.88M 파일 사건) | 서브트리 캐시 admission(≥100 파일 또는 ≥10MB), 최대 5000개/50MB, 단일 DB(SQLite) 사용도 고려 |
| 캐시 정합성 | dir mtime 비교는 **직속 변경만 감지** → 깊은 하위 변경은 놓침(Mole도 동일 한계; 하위 캐시 각각이 자기 mtime 검사로 보완). FSEvents(`FSEventStreamCreate`, `kFSEventStreamEventIdSinceNow` + 저장된 event ID)로 증분 무효화 시 정확도·속도 개선 가능 |
| 기준 비교 | 동일 트리에서 `du -skPx`와 결과 비교하는 회귀 테스트(하드링크/클론/sparse/권한거부 픽스처) 권장 |
