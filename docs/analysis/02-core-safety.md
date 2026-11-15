# 02. Core 안전·인프라 포팅 스펙 (Mole → 맥클린)

> 분석 대상: Mole V1.70.0 (`mole:115`). 출처 경로는 모두 Mole 저장소 기준 상대경로이며 `file:line`으로 표기합니다.
> 범위: `lib/core/{file_ops,app_protection,app_protection_data,sudo,history,common,base,bundle_resolver,browser_clones,pkg_receipts,timeout,timeouts,log}.sh`, `lib/manage/{whitelist,purge_paths}.sh`, `lib/check/health_json.sh`, `mole` 라우터.
> UI(`lib/core/ui.sh`, `lib/ui/menu_paginated.sh`)는 Bash 3.2 TUI 스피너/페이지 메뉴이므로 SwiftUI에서 대체합니다. 포팅할 대상이 아닙니다.

---

## 0. 모듈 로드 순서와 역할

`lib/core/common.sh:12-27`이 `base → (prepare_mole_tmpdir) → log → timeout → timeouts → file_ops → help → ui → app_protection → bundle_resolver → pkg_receipts → sudo` 순서로 로드합니다.

| 파일 | 역할 | Swift 대응 |
|---|---|---|
| `base.sh` | 상수, 색상, `mole_pgrep_any`, whitelist 기본값과 로더, BSD 도구 경로 고정(`STAT_BSD=/usr/bin/stat` `base.sh:564`, `FIND_BSD`, `SYSCTL_CMD`), PATH에 `/usr/sbin:/sbin` 추가, 임시파일 레지스트리, 프로세스 가드 | `Constants`, `ProcessProbe`, `WhitelistStore` |
| `log.sh` | `mole.log`, debug log, `operations.log`, 세션 마커 | `OperationLog` |
| `timeout.sh` / `timeouts.sh` | `run_with_timeout`(gtimeout→timeout→perl→shell 순 fallback), 표준 timeout 상수, deadline 계산 | `Task` + `withTimeout`, `Deadline` |
| `file_ops.sh` | **삭제 깔때기**(검증, Trash/영구 삭제, sudo 삭제, 크기 측정, 삭제 로그) | `SafeDeleter`, `PathPolicy`, `SizeCalculator` |
| `app_protection(_data).sh` | 보호 번들/경로 목록과 매칭, 앱 종료(`force_kill_app`), uninstall 대상 파일 탐색 | `ProtectionPolicy`, `AppTerminator` |
| `sudo.sh` | sudo 세션, Touch ID 감지, keepalive | `PrivilegedHelper`(SMAppService + XPC) |
| `history.sh` | `operations.log`/`deletions.log` 파싱 후 text/JSON 출력 | `HistoryStore` |
| `bundle_resolver.sh` | bundle id가 설치된 앱(또는 SMJobBless helper)에 속하는지 파일시스템으로 확인 | `InstalledAppIndex` |
| `browser_clones.sh` | Chromium 계열 `code_sign_clone`(/private/var/folders/../X) 식별과 idle 확인 | `BrowserCloneScanner` |
| `pkg_receipts.sh` | `pkgutil --pkgs/--files`로 비표준 위치 앱 탐색(캐시 `~/.cache/mole/pkg_receipt_apps_v1`, TTL 3600s) | `PkgReceiptIndex` |
| `health_json.sh` | optimize용 상태 JSON(메모리, 디스크, uptime, 최적화 작업 목록) | `HealthSnapshot: Codable` |

### 표준 timeout 상수 (`lib/core/timeouts.sh`)

| 상수 | 기본값(초) |
|---|---|
| `MOLE_TIMEOUT_QUICK_DETECT_SEC` | 2 |
| `MOLE_TIMEOUT_SHORT_QUERY_SEC` | 3 |
| `MOLE_TIMEOUT_MEDIUM_PROBE_SEC` | 5 |
| `MOLE_TIMEOUT_PKG_LIST_SEC` | 10 |
| `MOLE_TIMEOUT_PKG_CLEANUP_SEC` | 20 |
| `MOLE_TIMEOUT_DISK_VERIFY_SEC` | 30 (du, rm, mv, trash, osascript 1회당) |
| `MOLE_TIMEOUT_HINT_SCAN_SEC` | 15 |
| `MOLE_CLOUD_OFFICE_SECTION_BUDGET_SEC` | 300 |

`_mole_timeout_with_deadline`(`timeouts.sh`)는 `min(requested, deadline-SECONDS)`를 돌려주고, 이미 deadline이 지났으면 124를 반환합니다. 종료코드 규약은 `124`=timeout, `>=128`=signal(취소)입니다(`timeout.sh:104-108`).

### 전역 보존 기간 상수 (`base.sh:152-165`)

`MOLE_TEMP_FILE_AGE_DAYS=7`, `MOLE_ORPHAN_AGE_DAYS=30`, `MOLE_MAX_PARALLEL_JOBS=15`, `MOLE_MAIL_DOWNLOADS_MIN_KB=5120`, `MOLE_MAIL_AGE_DAYS=30`, `MOLE_LOG_AGE_DAYS=7`, `MOLE_CRASH_REPORT_AGE_DAYS=7`, `MOLE_SAVED_STATE_AGE_DAYS=30`, `MOLE_GPU_CACHE_AGE_DAYS=1`, `MOLE_TM_BACKUP_SAFE_HOURS=48`, `MOLE_MAX_DS_STORE_FILES=500`, `MOLE_MAX_ORPHAN_ITERATIONS=100`.

---

## 1. 삭제 깔때기 (Deletion Funnel)

### 1.1 진입점(sink)

| Sink | 위치 | 사용처 | 방식 |
|---|---|---|---|
| `safe_remove` | `file_ops.sh:1473` | clean, optimize, purge(캐시류) | 검증 후 `rm -rf`. **Trash를 쓰지 않습니다** |
| `safe_remove_symlink` | `file_ops.sh:1862` | 검증된 symlink | `rm` 또는 `sudo -n rm`(링크 자체만 삭제) |
| `safe_sudo_remove` | `file_ops.sh:2004` | 시스템 캐시/로그(`lib/clean/system.sh` 등) | `sudo -n rm -rf`. 상위 경로가 변경 가능하면 일반 `safe_remove`로 강등 |
| `safe_find_delete` | `file_ops.sh:3447` | 패턴+나이 기반 sweep | `find -maxdepth 5 -name P -type f\|d -mtime +N`의 결과가 **완료된 경우에만** 항목마다 `safe_remove` 호출 |
| `safe_sudo_find_delete` | `file_ops.sh:3578` | `/Library/Caches`, `/private/var/log`, DiagnosticReports, powerlog 등 | sudo find 후 배치(`_mole_privileged_batch_max_items`) |
| `mole_delete` | `file_ops.sh:2396` | uninstall, slim(앱 번들) | **Trash/영구 라우팅**과 `deletions.log` 포렌식 기록 |

모드: `MOLE_DELETE_MODE`는 `permanent`(함수 기본값) 또는 `trash`만 허용하고, 그 밖의 값이면 거부합니다(`file_ops.sh:2404-2416`). `mo uninstall`은 기본값을 `trash`로 두고(`bin/uninstall.sh:2028`) `--permanent`일 때만 `permanent`를 씁니다(`bin/uninstall.sh:2048`). `mo slim`은 항상 `trash`입니다(`bin/slim.sh:692`).

### 1.2 `validate_path_for_deletion` 단계 (`file_ops.sh:1160-1379`)

각 단계는 순서대로 적용되고, 거부 시 `_MOLE_VALIDATION_REASON`에 이유를 남깁니다(oplog의 SKIPPED 사유로 사용).

| # | 검사 | 라인 | 결과 |
|---|---|---|---|
| 1 | 빈 문자열 | 1165 | 거부 |
| 2 | 절대경로(`/`로 시작) | 1171 | 거부 |
| 3 | `..`가 **경로 컴포넌트 전체**일 때만 거부(`(^\|/)\.\.(/\|$)`). `name..files`는 허용 | 1179 | 거부 |
| 4 | 제어문자(`[[:cntrl:]]`, `\n`) | 1185 | 거부 |
| 5 | 정책 경로 정규화: `//`→`/`, `/./`→`/`, 끝의 `/.`와 `/` 제거, `/System/Volumes/Data/<top>`이 firmlink로 `/<top>`과 같은 inode면 `/<top>`으로 환원 | 117-160 | - |
| 6 | **leaf symlink**: `readlink`로 대상을 읽고 상대경로면 절대경로로 바꾼 뒤 critical deny list와 비교 | 1195-1218 | 거부 |
| 7 | **조상 symlink**: 부모 경로를 따라 올라가며 `-L`을 검사하고, 하나라도 링크면 `cd -P`로 물리 경로를 구해 leaf를 붙인 뒤 critical deny와 `should_protect_path`를 다시 적용. 거부 전용(허용 근거로는 쓰지 않음) | 1236-1267 | 거부 |
| 8 | 허용 예외: `/System/Library/Caches/com.apple.coresymbolicationd/data(/*)` | 1270-1274 | **즉시 허용** |
| 9 | 활성 powerlog DB(`/private/var/db/powerlog/Library/PerfPowerTelemetry/**/Current*` + WAL) | 1279, 165-205 | 거부 |
| 10 | **실행 중인 앱의 reverse-DNS 사용자 캐시** (`~/Library/Caches/<a.b>`, `~/Library/Containers/<id>/Data/Library/Caches`, `~/Library/Group Containers/<id>/{Caches,Library/Caches}`): 소유 프로세스가 실행 중이거나 SQLite/열린 핸들이 있으면 거부. 판단 불가(2)도 거부 | 1287-1299, 206-250, 904-1018 | 거부 |
| 11 | SQLite 계열(`*.db\|*.sqlite\|*.sqlite3` + `-wal/-shm/-journal`, 대소문자 무시): `lsof`로 사용 중(0)이거나 판단 불가(2)면 거부 | 1301-1315, 253-275, 641 | 거부 |
| 12 | 다운로드 중인 파일(`~/Downloads/*.{download,crdownload,part}` 1단계, `~/Library/Caches/Homebrew/downloads/*.incomplete`): 열린 핸들이 있거나 판단 불가면 거부 | 1318-1331, 289-302 | 거부 |
| 13 | EDR/MDM 캐시(`/private/var/folders/**`에 `ENDPOINT_SECURITY_BUNDLE_PREFIXES` 포함) | 1337 | 거부 |
| 14 | `/private` 아래 허용 목록(아래 표). 일치하면 이후 검사를 건너뜀 | 1345-1357 | **즉시 허용** |
| 15 | `_mole_is_critical_deletion_path` (아래 deny list) | 1360 | 거부 |
| 16 | `~/.Trash/<top>`(Trash 1단계 자식)이면 보호 검사 생략, 아니면 `should_protect_path`(§2.3) | 1366-1376 | 거부 |

**`/private` 허용 목록** (`file_ops.sh:1345-1357`)
```
/private/tmp/*            /private/var/tmp/*         /private/var/log(/*)
/private/var/folders/*    /private/var/db/diagnostics(/*)
/private/var/db/DiagnosticPipeline(/*)   /private/var/db/powerlog(/*)
/private/var/db/reportmemoryexception(/*)
/private/var/db/receipts/*.bom           /private/var/db/receipts/*.plist
```

### 1.3 Critical deny list: `_mole_is_critical_deletion_path` (`file_ops.sh:1044-1129`)

**1단계: 문자열 case 매칭 (`file_ops.sh:1047-1084`)**

| 분류 | 패턴 |
|---|---|
| 예외(먼저 허용) | `/usr/local/*`, `/opt/homebrew/*` (하위 항목만 허용하고, 루트 자체는 아래에서 거부) |
| 루트·시스템 | `/`, `/bin(/*)`, `/dev(/*)`, `/sbin(/*)`, `/usr(/*)`, `/System(/*)` |
| /Library | `/Library`(정확히), `/Library/Apple(/*)`, `/Library/Application Support`(정확히), `/Library/Extensions(/*)`, `/Library/Keychains(/*)` |
| /Applications | `/Applications`(정확히), `/Applications/Finder.app(/*)`, `/Applications/Safari.app(/*)` |
| 볼륨·opt | `/Volumes`(정확히), `/opt`, `/opt/homebrew` |
| 사용자 | `/Users`, `/Users/Shared`, `/Users/Guest(/*)`, **`/Users/<name>` (정확히 한 단계, 1088-1090)** |
| private | `/private`, `/private/tmp`(정확히), `/etc(/*)`, `/private/etc(/*)` |
| var | `/var`, `/var/db(/*)`, `/var/audit(/*)`, `/var/root`, `/private/var`, `/private/var/tmp`, `/private/var/folders`(정확히), `/private/var/db(/*)`, `/private/var/audit(/*)`, `/private/var/root` |

**2단계: inode 동일성 (APFS 대소문자 무시 별칭 대응, `file_ops.sh:1095-1128`)**
- `exact_roots`와 같은 파일(`-ef`)이면 거부: `/ /Applications /Library /Volumes /Network /cores /etc /home /net /tmp /var /private /private/tmp /private/var /private/var/tmp /private/var/folders /Users /opt /opt/homebrew`
- `protected_trees`의 **조상 중 하나와 같은 파일**이면 거부: `/bin /dev /sbin /usr /System /private/etc /private/var/audit /private/var/db /private/var/root /Library/Apple /Library/Extensions /Library/Keychains /Applications/Finder.app /Applications/Safari.app`
- 부모가 `/Users`와 같은 inode이면 거부합니다(`/USERS/SHARED` 같은 대소문자 변형).

### 1.4 `safe_remove` 마지막 구간 검사 (`file_ops.sh:1473-1859`)

| 순서 | 동작 | 라인 |
|---|---|---|
| a | clean에서 이미 취소 신호(`MOLE_CLEAN_CANCEL_STATUS`)가 있으면 즉시 반환 | 1491 |
| b | `validate_path_for_deletion`. 실패 시 `SKIPPED (<reason>)`를 기록. signal/timeout이면 취소 상태를 전파 | 1513-1524 |
| c | **사용자 whitelist** `is_path_whitelisted` → `SKIPPED (whitelist)` | 1533 |
| d | 존재하지 않으면 성공(0) | 1539 |
| e | `holds_compiled_model_cache`(경로가 `com.apple.e5rt.e5bundlecache`이거나 그것을 직계로 포함) → 거부 | 1546 |
| f | **dry-run**: 크기를 측정해 preview ledger에 기록하고 종료(삭제 안 함) | 1553 |
| g | oplog용 크기 측정(`get_path_size_kb ... readable`, deadline 적용). timeout이면 크기 0으로 두고 삭제는 계속하며 `MOLE_CLEAN_SIZING_TIMEOUTS++` | 1610-1640 |
| h | 크기를 재는 동안 상태가 바뀌었을 수 있으므로 e를 다시 검사 | 1651 |
| i | 프로세스 스냅샷을 리셋한 뒤 live user cache를 다시 검사 | 1660-1672 |
| j | SQLite/다운로드 파일: identity를 스냅샷 → `lsof` 재검사 → identity 재확인 | 1680-1740 |
| k | 호출자 `expected_parent/parent_id/target_id`(dev:inode)를 재확인 | 1741 |
| l | 호출자 정의 최종 가드 `_MOLE_SAFE_REMOVE_FINAL_GUARD`(함수명) → 이후 identity를 한 번 더 재확인 | 1750-1790 |
| m | `_mole_owned_path_still_valid`(sha256, 다시 나타난 앱 경로, UUID 컨테이너 소유권) | 1806, 2323 |
| n | `rm -rf` (timeout은 `DISK_VERIFY` 값과 섹션 deadline 중 작은 값) | 1811-1813 |
| o | 결과 분류: 0이면 `REMOVED (size)`, 124면 `FAILED (removal timed out)` 또는 `SKIPPED (section time limit reached)`, >=128이면 취소, "Permission denied/Operation not permitted"면 `FAILED (permission denied)`와 `MOLE_PERMISSION_DENIED_COUNT++`(FDA 안내용) | 1815-1858 |

**Identity 모델**: `_mole_snapshot_path_identity`(`file_ops.sh:3260`)는 `cd -P`로 얻은 물리 부모 경로, `stat -f %d:%i parent`, `stat -f %d:%i target`을 기록합니다. `mole_deletion_identity`(`file_ops.sh:2295`)는 `dev:inode:mtime`입니다. 원칙은 "프로브를 거친 뒤에는 반드시 다시 바인딩하고, 교체된 객체가 이전 승인을 이어받지 못하게 한다"입니다.

### 1.5 Symlink 처리 요약

| 상황 | 처리 |
|---|---|
| leaf가 symlink | 대상이 critical이면 거부(1195). 삭제는 링크 자체만 함(`safe_remove_symlink`의 `rm`, `rm -rf`도 링크를 따라가지 않음) |
| 조상이 symlink | 물리 경로로 critical/protect 재검사(1236) |
| `safe_sudo_remove`의 대상이 symlink | **무조건 거부**(`file_ops.sh:2034`) |
| `safe_find_delete`의 base가 symlink | 거부(`file_ops.sh:3465`, sudo 판 3698) |
| 크기 측정 | `du -skP`(링크를 따라가지 않음), 파일/링크는 `stat -f %b` |

### 1.6 특권 삭제 안전성: `_mole_privileged_path_has_mutable_ancestor` (`file_ops.sh:1949-2002`)

sudo로 `rm`/`mv`를 하려면 **모든 조상 디렉터리가 불변**이어야 합니다.
- 다음 중 하나라도 해당하면 mutable로 판정합니다: 조상이 symlink, owner uid≠0, mode에 `0022` 비트, stat 실패, 호출 사용자가 `-w`(ACL 포함) 가능.
- `sudo mo` 상황에서는 `sudo -n -u #uid /bin/test -w`로 확인하고, 종료코드 1 외의 결과는 mutable로 봅니다(fail closed).
- mutable이면 `safe_sudo_remove`는 비root일 때 `safe_remove`(사용자 권한)로 강등하고, `mole_delete`는 `MOLE_ERR_MUTABLE_PARENT(15)`로 거부합니다.

### 1.7 Trash 라우팅 (`mole_delete` → `_mole_move_to_trash`, `file_ops.sh:2822-2909`)

| 우선순위 | 조건 | 방법 |
|---|---|---|
| 0 | 테스트 모드와 `MOLE_TEST_TRASH_DIR` | `mv` |
| 1 | `needs_sudo=true` | `_mole_move_path_to_user_trash`의 **특권 staging** 경로 |
| 2 | 직접 Trash 대상: `/Applications/*.app`(1단계), `~/Library/{Containers,Group Containers,Application Scripts}/*`(1단계) (`file_ops.sh:2717`) | `_mole_move_path_to_user_trash`(사용자 `mv`). `.app`이 TCC로 거부(14)되면 Finder AppleScript `delete`로 fallback(2772) |
| 3 | `trash` CLI(Homebrew)가 있음 | `trash <path>` |
| 4 | 그 외 | `osascript`에 argv로 경로를 넘겨 `tell application "Finder" to delete` |

- Trash 실패 시 **영구 삭제로 fallback하지 않습니다**: "Trash unavailable; refusing permanent delete" (`file_ops.sh:2622-2634`).
- 각 이동 직전에 `_mole_trash_target_still_safe`(live cache와 identity 재검사)와 `_mole_owned_path_still_valid`를 실행합니다.
- 목적지 이름 규칙(`file_ops.sh:3048-3070`): basename에서 `:`와 `/`를 `__`로 바꾸고, 충돌하면 `<base>.<epoch>.<pid>.<n>` 형식으로 최대 100회 시도합니다. `~/.Trash`가 symlink이거나 일반 디렉터리가 아니거나 소유자가 다르면 거부합니다.
- **특권 staging**(`file_ops.sh:2917-2970`, 3070-3250): `/Library/MoleTrashStaging`(root:wheel 0711, ACL 제거, 영구 보존)에 `mktemp -d item.XXXXXX`로 디렉터리를 만든 뒤 다음 순서로 진행합니다.
  1. 같은 볼륨인지 확인(`stat -f %d`). 다르면 거부
  2. `sudo mv src stage/item`
  3. `chmod 700 stage`
  4. `chown -Rhx uid:gid stage/item`(링크 미추적, 다른 FS 미진입)
  5. `chown stage`
  6. 사용자 권한으로 `mv -n stage/item ~/.Trash/<dest>`
  중간에 실패하면 "item preserved for recovery at: <stage>"를 남기고 payload를 보존합니다.

### 1.8 Dry-run

| 항목 | 동작 |
|---|---|
| 플래그 | `--dry-run`/`-n` → `MOLE_DRY_RUN=1`(clean은 `DRY_RUN=true`도 설정) |
| 검증 | **실제 실행과 같은 검증**(validate, whitelist, compiled model)을 거친 뒤 반환 → preview와 실제 실행의 대상 집합이 일치 |
| 기록 | `record_dry_run_cleanup_target`(bin/clean.sh:245)이 ledger를 만들고, 최종 목록은 `~/.config/mole/clean-list.txt`(`bin/clean.sh:49`)에 저장 |
| oplog | 세션 명령이 `<cmd>-dry-run`으로 기록되어 실제 실행과 구분(`log.sh:273`) |
| deletions.log | `mole_delete`는 status `dry-run`으로 기록 |
| sudo | dry-run에서도 sudo 검증(`sudo -n test -e` 등)은 수행하지만 테스트 모드에서는 sudo를 막음 |

### 1.9 크기 측정 (`get_path_size_kb`, `file_ops.sh:4045-4140`)

| 대상 | 방법 |
|---|---|
| `*.app` | `mdls -name kMDItemPhysicalSize -raw` → KB 올림(`(b+1023)/1024`) |
| 파일 또는 symlink | `stat -f %b`(512B 블록) → `(blocks+1)/2` KB |
| 디렉터리 | `du -skP`(timeout 적용). 종료코드 1과 `readable` 모드면 부분 합계를 인정(읽을 수 있는 바이트), 그 외 오류는 실패로 처리 |
| 원칙 | 물리(할당) 크기 기준이고, 논리 크기와 섞지 않음(#1404). timeout만 "하한값(`3.27GB+`)"으로 표시. **디렉터리 크기 캐시 금지**(APFS는 부모 mtime이 갱신되지 않음, `.claude/rules/core.md`) |
| clean 전용 | `_cleanup_path_sizes_kb`(lib/clean 쪽): hardlink는 후보 내부에서만 한 번 집계, APFS private 바이트, sparse/clone은 논리 크기로 세지 않음 |
| 브라우저 clone | APFS extent를 공유하므로 크기 `unknown`(`browser_clones.sh:2`) |

### 1.10 오류 코드 (`file_ops.sh:13-20`)와 사용자 안내 (`diagnose_removal_failure`, `file_ops.sh:4199`)

| 코드 | 이름 | 판정 근거 | 안내 |
|---|---|---|---|
| 10 | `SIP_PROTECTED` | sudo rm 출력에 "Operation not permitted" | "protected by macOS (SIP/MDM)" |
| 11 | `AUTH_FAILED` | "a password is required", "Sorry, try again" 등 | Touch ID 설정 권유 |
| 12 | `READONLY_FS` | "Read-only file system" | 디스크 복구 |
| 13 | `PROTECTED_PATH` | 정책 거부 | "protected by Mole safety rules" |
| 14 | `PRIVACY_DENIED` | Trash 접근 TCC 거부 | Finder로 직접 이동 |
| 15 | `MUTABLE_PARENT` | 특권 삭제의 조상이 변경 가능 | Finder로 이동 |
| 16 | `OWNER_UNVERIFIED` | sha256 또는 identity 불일치 | plist 재검토 |
| 17 | `APP_REAPPEARED` | 삭제한 앱 경로가 다시 존재 | 재선택 |

SIP는 **사전 검사(csrutil)를 하지 않습니다**. `/System`, `/usr` 등은 deny list로 막고, 그 밖은 실패 메시지로 사후 분류합니다.

---

## 2. 앱 보호 (App Protection)

### 2.1 데이터 목록 (`lib/core/app_protection_data.sh`)

| 배열 | 라인 | 개수 | 용도 |
|---|---|---|---|
| `SYSTEM_CRITICAL_BUNDLES` | 19-160 | ~135 | **uninstall 금지**, clean 보호 |
| `APPLE_UNINSTALLABLE_APPS` | 163-175 | 11 | 위 목록의 예외(Apple 앱 중 삭제 허용) |
| `OFFICIAL_UNINSTALLER_RULES` | 179-203 | 17 | 공식 uninstaller로 안내(`vendor\|bundle-prefix,...\|name-fragment,...`) |
| `ENDPOINT_SECURITY_BUNDLE_PREFIXES` | 215-226 | 10 | var/folders 캐시 삭제 금지(EDR tamper 탐지 회피) |
| `DATA_PROTECTED_BUNDLES` | 229-642 | ~353 | clean 시 데이터 보호(uninstall은 허용) |
| `LAUNCH_AGENT_NAME_COMMON_WORDS` | 650 | 40단어 | 앱 이름이 일반 단어(Music, Helper, Agent, Update, Sync 등)면 이름 기반 LaunchAgent 매칭을 하지 않음 |

**`SYSTEM_CRITICAL_BUNDLES` 주요 항목**
- 시스템 앱: `com.apple.{finder,dock,Safari,mail,systempreferences,SystemSettings,Spotlight,loginwindow,Preview,TextEdit,Notes,reminders,iCal,AddressBook,Photos,AppStore,calculator,Terminal,ActivityMonitor,Console,DiskUtility,KeychainAccess,...}`, `com.apple.Settings*`, `com.apple.controlcenter*`
- macOS 26 추가 항목(대소문자 구분 정확값): `com.apple.{apps.launcher,clock,FaceTime,findmy,freeform,games,journal,Maps,MobileSMS,Passwords,shortcuts,TV,VoiceMemos,weather,...}`
- 서비스(glob): `com.apple.{CoreServices*,backgroundtaskmanagement*,loginitems*,sharedfilelist*,sfl*,metadata*,SoftwareUpdate*,installer*,security*,keychain*,trustd*,iCloud*,WiFi*,Bluetooth*}`
- 입력기: `com.apple.inputmethod.*`, `com.apple.inputsource*`, `com.apple.TextInput*`
- 레거시 토큰: `loginwindow dock finder safari tcc keychain* security* bluetooth* wifi* network* notification* accessibility* universalaccess* HIToolbox* textinput* keyboard* inputsource* keylayout* GlobalPreferences .GlobalPreferences`

**`APPLE_UNINSTALLABLE_APPS`**: `com.apple.dt.*`(Xcode), `com.apple.FinalCut*`, `Motion`, `Compressor`, `com.apple.logic*`, `com.apple.garageband*`, `iMovie`, `com.apple.iWork.*`, `MainStage*`, `com.apple.server.*`, `Playgrounds`

**`OFFICIAL_UNINSTALLER_RULES`**: ESET, Jamf, CrowdStrike, SentinelOne, GlobalProtect(paloaltonetworks), Cisco(anyconnect/secureclient), Alibaba Cloud Security, Adobe Genuine Service, Avast, AVG, Malwarebytes, TeamViewer, Bitdefender, Intego, Kaspersky, Norton, Trend Micro

**`ENDPOINT_SECURITY_BUNDLE_PREFIXES`**: `com.crowdstrike. com.sentinelone. com.sentinel-labs. com.eset. com.jamf. com.jamfsoftware. com.paloaltonetworks. com.cisco.anyconnect com.cisco.secureclient com.alibaba.security.`

**`DATA_PROTECTED_BUNDLES` 카테고리(개수)와 대표 항목**

| 카테고리 | n | 예시 |
|---|---|---|
| Input Methods | 8 | `com.sogou.inputmethod.*`, `im.rime.*`, `*.inputmethod`, `*IME` |
| System Utilities & Cleanup | 8 | `com.macpaw.*`, `com.nektony.*`, `com.daisydiskapp.*` |
| Password Managers | 10 | `com.1password.*`, `com.agilebits.*`, `com.bitwarden.*`, `org.keepassxc.*`, `com.yubico.*` |
| IDEs & Editors | 13 | `com.jetbrains.*`, `com.microsoft.VSCode`, `com.apple.dt.Xcode`, `com.panic.Nova` |
| AI & LLM Tools | 23 | `com.todesktop.*`(Cursor), `com.anthropic.claude*`, `com.openai.chat*`, `Codex`, `com.ollama.ollama`, `com.lmstudio.lmstudio` |
| Database Clients | 11 | `com.sequel-ace.*`, `com.dbeaver.*`, `com.navicat.*`, `com.mongodb.compass` |
| API & Network Tools | 9 | `com.postmanlabs.mac`, `com.proxyman.*`, `com.charlesproxy.charles` |
| Network Proxy & VPN (Clash) | 20 | `com.clash.*`, `ClashX*`, `*clash-verge*` |
| Proxy Clients | 14 | `*ShadowsocksX-NG*`, `*v2ray*`, `*sing-box*`, `*hiddify*` |
| Mesh & Corporate VPNs | 12 | `io.tailscale.*`, `com.zerotier.*`, `*cloudflare*warp*`, `com.wireguard.*` |
| Commercial VPNs | 7 | `*nordvpn*`, `*expressvpn*`, `*mullvad*` |
| Screensaver & Wallpaper | 4 | `*Aerial.saver*`, `*Fliqlo*` |
| Git & Version Control | 8 | `com.github.GitHubDesktop`, `com.fork.Fork`, `com.axosoft.gitkraken` |
| Terminal & Shell | 9 | `com.googlecode.iterm2`, `net.kovidgoyal.kitty`, `dev.warp.Warp-Stable` |
| Docker & Virtualization | 10 | `com.docker.docker`, `dev.orbstack.*`, `com.utmapp.UTM`, `com.parallels.desktop.*` |
| System Monitoring | 7 | `com.bjango.istatmenus*`, `eu.exelban.Stats` |
| Window Management | 16 | `com.knollsoft.Rectangle`, `com.lwouis.alt-tab-macos`, `com.manytricks.*` |
| Launcher & Automation | 10 | `com.raycast.*`, `com.runningwithcrayons.Alfred`, `org.pqrs.Karabiner-Elements` |
| Note-Taking | 17 | `md.obsidian`, `notion.id`, `com.logseq.logseq`, `net.shinyfrog.bear` |
| Design & Creative | 24 | `com.adobe.*`, `com.figma.*`, `com.bohemiancoding.*`(Sketch) |
| Communication | 21 | `com.tencent.xinWeChat`, `us.zoom.xos`, `com.slack.Slack`, `com.hnc.Discord` |
| Task Management | 13 | `com.culturedcode.*`, `com.todoist.*`, `com.ticktick.*` |
| File Transfer & Sync | 7 | `com.panic.transmit*`, `com.cyberduck.Cyberduck`, `com.synology.*` |
| Cloud Storage & Backup | 26 | `com.dropbox.*`, `*OneDrive*`, `com.google.GoogleDrive`, `com.backblaze.*` |
| Remote Desktop | 6 | `com.teamviewer.*`, `com.anydesk.*`, `com.realvnc.*` |
| Screenshot & Recording | 12 | `com.cleanshot.*`, `com.techsmith.snagit*` |
| Media & Entertainment | 12 | `com.spotify.client`, `com.apple.Music`, `org.videolan.vlc` |
| Web Browsers | 2 | `Firefox`, `org.mozilla.*` |
| Scientific & Professional | 9 | `com.mathworks.*`, `com.wolfram.*`, `com.crowdstrike.*` |
| License & App Stores | 5 | `com.paddle.Paddle*`, `com.setapp.DesktopClient`, `org.sparkle-project.Sparkle*` |

### 2.2 매칭 방식

| 함수 | 위치 | 방식 |
|---|---|---|
| `_mole_build_protected_globs` | `app_protection.sh:40` | 목록을 bash extglob `@(a\|b\|...)` 하나로 합쳐 한 번에 매칭. clean 모드는 SYSTEM_CRITICAL과 DATA_PROTECTED를 합집합으로 사용 |
| `_mole_matches_protected_glob` | `:52` | `LC_ALL=C` 바이트 매칭(성능). 패턴의 `*`는 경로 전체 문자열에 대해 glob으로 동작(`/`도 넘음) |
| `should_protect_from_uninstall` | `:143` | 패턴을 regex로 변환(`.`→`\.`, `*`→`.*`, `^…$` 앵커). UNINSTALLABLE에 맞으면 허용, SYSTEM_CRITICAL에 맞으면 금지. **대소문자 구분** |
| `official_uninstaller_vendor` | `:161` | 소문자화한 bundle id의 prefix 일치 **또는** 소문자화한 표시이름/`.app` 이름에 fragment 포함 |
| `should_protect_data` | `:199` | 빠른 case 분기(`com.apple.*`, `org.cups.*`, `com.microsoft.*`, `com.docker.*` 등) 후 DATA glob으로 fallback |
| `is_critical_system_component` | `:70` | 토큰에 `backgroundtaskmanagement\|loginitems\|systempreferences\|systemsettings\|settings\|preferences\|controlcenter\|biometrickit\|sfl\|tcc` 포함(대소문자 무시) |
| `is_endpoint_security_cache_path` | `:271` | `/private/var/folders/*` 또는 `/var/folders/*` 아래 경로에 EDR prefix가 부분 문자열로 포함(대소문자 무시) |
| `holds_compiled_model_cache` | `:330` | `*/com.apple.e5rt.e5bundlecache`이거나 그 디렉터리를 직계로 포함 |

### 2.3 `should_protect_path` (`app_protection.sh:406-681`): 경로 단위 보호, 평가 순서

`MOLE_UNINSTALL_MODE=1`이면 SYSTEM_CRITICAL만 보호하고 DATA_PROTECTED는 사용자가 명시적으로 선택했으므로 허용합니다.

| 단계 | 내용 |
|---|---|
| 0 (clean만) | `~/.prometheus/data`, `~/.jupyter/runtime`, `~/.yarn/berry/cache`, `~/.gitconfig.lock`, `~/.gitconfig.bak*`, 셸 history `.bak*` |
| 0' | 공유 루트(대소문자 변형 포함): `~/.cache`, `~/.config`, `~/.local{,/bin,/lib,/share,/state}`, `~/Library/Unity`, `~/Library/Application Support/Epic` (`:347`) |
| 0'' (uninstall만) | Steam 라이브러리 `~/Library/Application Support/Steam(/*)` (`:370`) |
| 예외 | Codex 캐시 leaf(`~/Library/Caches/Codex/**/{Cache,Code Cache}/*`)는 재생성 가능 캐시로 표시 |
| OrbStack | `*/Group Containers/*dev.orbstack(/*)`, `*/.orbstack(/*)` |
| 1 | `*SystemSettings*`, `*SystemPreferences*`, `*ControlCenter*`, `*com.apple.Settings*`, `*com.apple.Notes*` |
| 2 | UI 렌더링 캐시: `*com.apple.{systempreferences,Settings,controlcenter,finder,dock}.cache*`, Settings/controlcenter 컨테이너, sharedfilelist의 Settings 관련 항목 |
| 3 | `/Library/(Group )Containers/<id>`에서 id를 추출. `Data/Library/Caches/*`, `Data/tmp/*`, WeChat 로그/WMPF/웹 프로필 Cache는 허용. 그 밖에서 clean 모드면 `should_protect_data(id)` |
| 4 | `*com.apple.{Settings,SystemSettings,controlcenter,finder,dock}*` |
| 4b | EDR 캐시 |
| 5 | `Preferences/com.apple.{dock,finder}.plist`, **`*/Library/Logs/mole(/*)`(자기 로그)**, Codex 상태(`Application Support/Codex`, `.codex/sessions`, `auth.json`, `history.jsonl`, `state_*.sqlite` 등. 단 `Crashpad/pending/<1단계>`는 허용), `ByHost/com.apple.{bluetooth,wifi}.*`, `com.apple.networkextension*.plist`, **`*Mobile Documents*`(iCloud)**, `Library/{Accounts,Keychains,Mail,Calendars,Contacts}(/*)`, 오디오 플러그인(`/Library/Audio/Plug-Ins/{Components,VST,VST3}`, iZotope), 라이선스 prefs(native-instruments, avid, fabfilter, paceap/iLok), `Caches/{ms-playwright,camoufox,Cypress,Adobe *,com.apple.containermanagerd,com.apple.homed,FamilyCircle,com.apple.HomeKit,GIPPseudonymousID,CCTClearcutLogger,...}`, 배경화면 자산(`com.apple.idleassetsd`, `com.apple.wallpaper`), `*com.apple.coreaudio*`, `*com.apple.audio.*`, `*coreaudiod*` |
| 6 | 컨테이너 캐시나 알려진 재생성 캐시가 아니면: uninstall 모드는 UNINSTALLABLE이면 허용, CRITICAL이면 보호. clean 모드는 **경로 전체 문자열**을 CLEAN glob에 매칭 |
| 7 (clean만) | basename을 `should_protect_data`로 검사 |

### 2.4 실행 중인 앱 감지

| 메커니즘 | 위치 | 내용 |
|---|---|---|
| `mole_pgrep_any -x name... -f pattern...` | `base.sh:75` | 같은 selector의 패턴을 `\|`로 묶어 `pgrep -x`와 `pgrep -f`를 각각 1회 호출. **3상태**: 0=실행 중, 1=확실히 없음, 2=판단 불가 |
| `mole_clean_process_guard` | `base.sh:1927` | 3상태를 해석하는 **유일한** 함수. 2(unknown)면 **삭제 거부** |
| `xcode_build_tooling_process_state` | `app_protection.sh:62` | Xcode, xcodebuild, xctest, XCTRunner, XCBBuildService, swift-frontend |
| `_mole_load_process_table` | `file_ops.sh:336` | `ps -axo pid,ppid,comm,args`와 `ps -axo pid=,comm=`(전체 실행 경로). `LC_ALL=C`로 처리. 캐시 소유자 판정에 사용. 실패하면 unavailable(→ unknown → 거부) |
| 열린 핸들 | `file_ops.sh:706-830` | `lsof`(direct 또는 sudo 모드). 실패하거나 확인 불가면 2 → 거부 |
| `force_kill_app` | `app_protection.sh:2732` | `Info.plist`의 `CFBundleExecutable`과 `CFBundleIdentifier`를 읽음 → 시스템 프로세스명(Finder, Dock, loginwindow, WindowServer, SystemUIServer, launchd, coreaudiod, NotificationCenter, ControlCenter, Spotlight)이면 거부 → 공유 런타임(Electron 등)이면 bundle id AppleEvent만 사용 → `pgrep -x <escaped>` → `osascript "tell application id \"<bid>\" to quit"` → 2초 동안 폴링 → SIGTERM → SIGKILL → (sudo 캐시가 있으면) sudo 재시도 |

---

## 3. Whitelist

### 3.1 파일

| 파일 | 용도 |
|---|---|
| `~/.config/mole/whitelist` | clean과 purge 보호 경로(`base.sh:482`, `whitelist.sh:21`) |
| `~/.config/mole/whitelist_optimize` | optimize 작업 ID 또는 진단 경로 제외(`whitelist.sh:22`) |
| `~/.config/mole/whitelist_checks` | 레거시 optimize 파일. 읽으면 새 경로로 자동 이전(`whitelist.sh:23, 302`) |

`sudo` 실행 시에도 `get_invoking_home`(`base.sh:906`)으로 **호출 사용자 홈**의 파일을 사용합니다.

### 3.2 형식

```
# Mole Whitelist - Protected paths won't be deleted
# Saved selections replace optional defaults; built-in safety protections still apply.
# Add one pattern per line to keep items safe.

~/Library/Caches/JetBrains*
/Users/me/.gradle/caches/*
FINDER_METADATA
```
- 한 줄에 한 패턴을 쓰고, 앞뒤 공백을 trim하며, 빈 줄과 `#`로 시작하는 줄은 무시합니다.
- 맨 앞의 `~`, `$HOME`, `${HOME}`은 사용자 홈으로 치환합니다.
- 특수 토큰 `FINDER_METADATA`는 `.DS_Store` 정리를 비활성화합니다(`base.sh:169`, `bin/clean.sh:124`).
- 저장 시(`save_whitelist_patterns`, `whitelist.sh:31`) 헤더를 덮어쓰고 중복을 제거하며, 홈은 `~`로 되돌려 저장합니다.

### 3.3 로드와 검증 (`load_mole_whitelist`, `base.sh:469-560`)

| 규칙 | 결과 |
|---|---|
| 파일 상태 판별(`mole_whitelist_file_state`, perl `lstat`): 0=읽을 수 있음, 1=ENOENT, 2=판단 불가(EACCES, 깨진 링크, 일반 파일 아님 등) | **2면 명령 전체 중단**(fail closed: 보호 목록을 못 읽은 상태에서 정리하지 않음) |
| 파일 없음(1) | `DEFAULT_WHITELIST_PATTERNS` 사용 |
| 파일 있음 | 파일 내용이 기본값을 **대체**함(V1.7.5+) |
| 항상 | `SAFETY_WHITELIST_PATTERNS`를 **강제 병합**(`ensure_safety_whitelist_patterns`, `base.sh:344`) |
| 거부 → 경고 | `..` 포함, 제어문자, 비절대경로, `//`, 그리고 `/ /System(/*) /bin(/*) /sbin(/*) /usr/bin(/*) /usr/sbin(/*) /etc(/*) /var/db(/*)` |

**DEFAULT_WHITELIST_PATTERNS** (`base.sh:170-187`): `~/Library/Caches/{ms-playwright*,camoufox*,Cypress*}`, `~/.gradle/{caches,daemon}/*`, `~/.ollama/models/*`, `~/Library/{Caches,Application Support}/com.nssurge.surge-mac/*`, `~/Library/Caches/org.R-project.R/R/renv/*`, `~/Library/Caches/{JetBrains*,com.jetbrains.toolbox*}`, `~/Library/Caches/tealdeer/tldr-pages`, `~/Library/Application Support/JetBrains*`, `~/Library/Caches/com.apple.finder`, `~/Library/Mobile Documents*`, `FINDER_METADATA`

**SAFETY_WHITELIST_PATTERNS(강제)** (`base.sh:195-225`): `FINDER_METADATA`, `~/Library/Caches/{com.apple.FontRegistry*,com.apple.spotlight*,com.apple.Spotlight*,CloudKit*,kitty,pypoetry/virtualenvs*,pnpm/dlx*,llama.cpp}`, `~/Library/Caches/org.R-project.R/R/renv/*`

### 3.4 매칭 의미 (`is_path_whitelisted`, `app_protection.sh:684-740`)

대상과 패턴 모두 끝의 `/`를 제거하고 `//`를 `/`로 줄인 뒤 다음 중 하나가 참이면 보호합니다.
1. **정확히 일치**하거나 **glob 일치**(bash `[[ == ]]`, `*`는 `/`도 넘음).
2. 대상이 패턴의 **조상**인 경우(`pattern == target/*`): 보호된 자식이 있으므로 부모도 삭제 금지.
3. 패턴에 glob이 없고 대상이 패턴의 **자손**인 경우(`target == pattern/*`).

적용 지점: `safe_remove`(1533), `safe_remove_symlink`, `safe_sudo_remove`, `safe_find_delete`의 항목별 검사(구조적으로 강제됨, #710/#724), clean의 `_safe_clean_impl`(bin/clean.sh:948). **uninstall에는 whitelist를 적용하지 않습니다**(`mo uninstall --whitelist`는 오류).

메뉴 UI용 인벤토리(`get_all_cache_items`, `whitelist.sh:91-187`)는 `표시명|패턴|카테고리` 형식이며, 카테고리는 `system_cache, ide_cache, ai_ml_cache, compiler_cache, package_manager, browser_cache, network_tools, container_cache`입니다. 메뉴 비교는 **정확한 문자열 비교**만 합니다(`patterns_equivalent`).

### 3.5 Purge paths (`lib/manage/purge_paths.sh`)

`~/.config/mole/purge_paths`는 한 줄에 경로 하나를 쓰고 `~`를 허용하며 `#`는 주석입니다. 비어 있으면 `DEFAULT_PURGE_SEARCH_PATHS`(lib/clean/project.sh)를 사용합니다. `mo purge --paths`는 `$EDITOR`(없으면 `$VISUAL`, 그다음 vim)로 파일을 엽니다. → Swift에서는 설정 화면의 폴더 목록(NSOpenPanel)으로 대체합니다.

---

## 4. Sudo/권한 모델

### 4.1 원칙
- **root로 실행하는 것을 거부합니다**: `mole:10-13`("Run Mole without sudo"). 필요한 작업만 개별적으로 권한을 상승합니다.
- 모든 특권 호출은 `sudo -n`(비대화식)이며 `_mole_bounded_sudo`(timeout)로 감쌉니다(`file_ops.sh:56`).
- 테스트 모드(`MOLE_TEST_MODE`/`MOLE_TEST_NO_AUTH`)에서는 sudo를 전면 차단합니다.

### 4.2 관리자 권한이 필요한 작업

| 명령 | 작업 | 위치 |
|---|---|---|
| clean | 시스템 정리 여부를 묻는 프롬프트(Enter=인증, Space=건너뜀, 문자 입력=비밀번호 직접 입력) | `bin/clean.sh:579-596` |
| clean | `/Library/Caches` `*.cache` 및 `*.log`, `/Library/Logs/DiagnosticReports`, `/private/var/log/*.log`, 서드파티 로그, `/private/var/db/{diagnostics,DiagnosticPipeline,powerlog}`, 메모리 리포트, `/Library` 설치 앱(installer), rebuildable/GPU 시스템 캐시, CFNetworkDownload tmp | `lib/clean/system.sh:281-886` |
| clean(dev) | Xcode 문서 캐시, Simulator 시스템 캐시 | `lib/clean/dev.sh:1837, 2281` |
| clean(apps) | 고아 시스템 LaunchDaemon/서비스 파일 | `lib/clean/apps.sh:1965` |
| optimize | `dscacheutil -flushcache`, mDNSResponder HUP, `route -n flush`, `arp -a -d`, `mdutil -E /`, `periodic daily weekly monthly`, `diskutil resetUserPermissions`, `diskutil repairVolume`, `launchctl kill SIGHUP system/<svc>`, `sfltool dumpbtm` | `bin/optimize.sh:309`, `lib/optimize/tasks.sh` |
| uninstall | root 소유 앱이나 시스템 파일(LaunchDaemons, PrivilegedHelperTools, receipts) | `lib/uninstall/batch.sh:2537` |
| touchid | `/etc/pam.d/sudo_local` 쓰기(`sudo install -m 444 -o root -g wheel`) | `bin/touchid.sh:32-35` |
| update | 설치 위치 쓰기 | `lib/manage/update.sh:1440` |

### 4.3 획득과 유지 (`lib/core/sudo.sh`)

| 함수 | 동작 |
|---|---|
| `request_sudo_access` (`:120`) | `sudo -n true`가 성공하면 그대로 사용 → TTY가 없으면 **GUI 모드**(`osascript display dialog ... with hidden answer`로 비밀번호를 받아 `sudo -S -v`) → 덮개가 닫혀 있으면(`ioreg AppleClamshellState`) 비밀번호만 → Touch ID가 설정돼 있으면 `sudo -v` 하나로 Touch ID 또는 비밀번호(시스템 다이얼로그) |
| `request_sudo_access_with_password` (`:220`) | 입력받은 비밀번호를 `sudo -S -p "" -v`로 전달 |
| `_start_sudo_keepalive` (`:255`) | 백그라운드 루프에서 `sudo -n -v`를 실행. 성공하면 30초, 실패하면 5초 후 재시도. 부모가 종료되면 함께 종료 |
| `ensure_sudo_session` / `adopt_sudo_session` / `stop_sudo_session` | 세션 수립, 기존 ticket 채택, 종료 |
| Touch ID 감지 | `/etc/pam.d/sudo_local`(Sonoma+) 또는 `/etc/pam.d/sudo`에 주석이 아닌 `pam_tid.so` 줄이 있음(`grep '^[^#]*pam_tid\.so'`, `:47`) |
| 힌트 | 비밀번호로 인증했고 `bioutil -c`에 지문 템플릿이 있으면 "mo touchid" 안내(`:90`). **PAM을 자동으로 수정하지 않습니다** |
| touchid 명령 | `mo touchid [enable\|disable\|status] [--dry-run]`. 추가하는 줄은 `auth       sufficient     pam_tid.so`(`bin/touchid.sh:32`) |

---

## 5. History와 Oplog

### 5.1 로그 파일 (`lib/core/log.sh:24-28`)

| 파일 | 내용 | 회전 |
|---|---|---|
| `~/Library/Logs/mole/mole.log` | `[YYYY-MM-DD HH:MM:SS] INFO\|SUCCESS\|WARNING\|ERROR: msg` | 1MB → `.old` |
| `~/Library/Logs/mole/mole_debug_session.log` | `--debug`(`MO_DEBUG=1`)일 때 상세 기록 | - |
| `~/Library/Logs/mole/operations.log` | 작업 로그(아래) | 5MB → `.old`(`log.sh:112-121`) |
| `~/Library/Logs/mole/deletions.log` | `mole_delete` 포렌식(TSV) | 없음 |

`mo remove`도 `~/Library/Logs/mole`은 지우지 않습니다. `MO_NO_OPLOG=1`이면 oplog를 끕니다(`log.sh:256`). 로그 쓰기에 실패하면 세션당 1회 경고합니다(`_mole_warn_log_broken`).

### 5.2 `operations.log` 형식

```

# ========== clean run=20261109153000-12345-9876-5432 session started at 2026-11-09 15:30:00 ==========
[2026-11-09 15:30:01] [clean run=20261109153000-12345-9876-5432] REMOVED /Users/me/Library/Caches/foo (15.2MB)
[2026-11-09 15:30:01] [clean run=...] SKIPPED /Users/me/Library/Caches/bar (whitelist)
[2026-11-09 15:30:02] [clean run=...] FAILED /Library/Caches/x (sip/mdm protected)
# ========== clean run=... session ended at 2026-11-09 15:31:00, 42 items, 1.2GB ==========
```
- 명령: `clean | uninstall | optimize | purge | installer | slim | remove ...`. dry-run이면 `clean-dry-run`.
- `run=<digits>-<pid>-<RANDOM>-<RANDOM>`(`log.sh:310`).
- action: `REMOVED | TRASHED | SKIPPED | FAILED | REBUILT | TASK_FAILED | 기타`.
- detail(괄호 안): 크기 또는 사유. 사유 어휘 예시: `whitelist, protected, live user cache, active or unknown SQLite database, active or unknown download, compiled model cache, identity changed, sink guard denied, section time limit reached, removal timed out, permission denied, error, sudo error, auth required, auth failed, sip/mdm protected, readonly filesystem, privacy permission denied, mutable-parent, trash-failed, symlink, symlink removal failed`.
- 제어문자는 `\n \r \t \xHH`로 escape합니다(`base.sh:807`).

### 5.3 `deletions.log` 형식 (`_mole_delete_log`, `file_ops.sh:3408`)

`<ISO8601 %Y-%m-%dT%H:%M:%S%z>\t<mode>\t<size_kb|unknown>\t<status>\t<path>`
- mode: `trash | permanent | <invalid>`
- status: `ok, dry-run, rejected, invalid-mode, mutable-parent, identity-changed, ownership-unverified, app-reappeared, privacy-denied, trash-failed, sudo-blocked-test-mode, timed-out, interrupted, error`
- size는 측정 실패 시 0이 아니라 `unknown`으로 기록합니다(0KB와 측정 실패를 구분하기 위함).

### 5.4 `mo history [--json] [--limit N]` (`bin/history.sh`, `lib/core/history.sh`)

- `--limit`: 기본 20, 최대 200, 1~200 범위가 아니면 오류(`history.sh:13-14, 104`).
- 라우터가 `history`는 common.sh를 로드하기 전에 **바로 exec**합니다(`mole:94-107`).
- 파싱: 세션 시작/끝 마커와 작업 줄. 마커가 없는 레거시 줄도 명령 단위로 묶어 세션으로 만듭니다. `.old` 회전 파일은 **읽지 않습니다**.

```json
{
  "logs": {"operations": "/Users/me/Library/Logs/mole/operations.log", "deletions": ".../deletions.log"},
  "limit": 20,
  "sessions": [
    {"command": "clean", "run_id": "...", "attribution": "run|command|ambiguous",
     "started_at": "...", "ended_at": "...", "items": 42, "size": "1.2GB",
     "operation_count": 50, "failed_tasks": 0,
     "actions": {"removed": 40, "trashed": 0, "skipped": 8, "failed": 2, "rebuilt": 0, "other": 0}}
  ],
  "deletions": [
    {"timestamp": "...", "mode": "trash", "status": "ok", "size_kb": 1024, "path": "/Applications/Foo.app"}
  ]
}
```
배열은 최신 항목이 먼저 옵니다(`history.sh:767-856`). `size_kb`를 모르면 `null`입니다.

---

## 6. 라우터 (`mole`)

### 6.1 시작 시 검사
1. EUID가 0이면 종료(`mole:10`).
2. cwd에 접근할 수 없으면 종료. 단 `--version/--help`는 `/`로 이동해 응답(`mole:21-31`).
3. 전역 플래그 `--debug`는 위치와 관계없이 제거되고 `MO_DEBUG=1`로 설정(`mole:77-92`).
4. `trap cleanup_temp_files EXIT INT TERM`.

### 6.2 서브커맨드 (`mole:325-431`, `lib/core/commands.sh:4-20`)

| 명령 | 별칭 | 실행 | 플래그 |
|---|---|---|---|
| (없음) | - | `check_for_updates` 후 대화형 메뉴(1 Clean, 2 Uninstall, 3 Optimize, 4 Analyze, 5 Status, M More, V Version, T TouchID, U Update, Q Quit) | - |
| `clean` | - | `bin/clean.sh` | `--dry-run/-n`, `--external PATH`(외장 볼륨 메타데이터), `--whitelist`, `--debug`, `-h`. 폐지: `--select/--categories/--exclude` |
| `uninstall` | - | `bin/uninstall.sh` | `[APP_NAME...]`, `--list`(파이프로 출력하면 JSON), `--dry-run/-n`, `--permanent`, `--with-data`, `--debug`, `-h`. `--whitelist`는 오류 |
| `optimize` | `optimise` | `bin/optimize.sh` | `--dry-run/-n`, `--whitelist`, `--debug`, `-h` |
| `analyze` | `analyse` | `bin/analyze-go`(Go) | `[PATH]`, `--json` |
| `status` | - | `bin/status-go`(Go) | `--json`, `--watch`, `--interval D`, `--proc-cpu-alerts` |
| `history` | - | `bin/history.sh`(먼저 exec) | `--json`, `--limit N`, `-h` |
| `purge` | - | `bin/purge.sh` | `--paths`, `--dry-run/-n`, `--yes`, `--include-empty`, `--debug`, `-h` |
| `installer` | - | `bin/installer.sh` | `--dry-run/-n`, `--debug`, `-h` |
| `slim` | - | `bin/slim.sh` | `--dry-run/-n`, `--debug`, `-h` |
| `touchid` | - | exec `bin/touchid.sh` | `enable\|disable\|status`, `--dry-run/-n`, `-h` |
| `completion` | - | exec `bin/completion.sh` | `bash\|zsh\|fish`, `--dry-run/-n`, `-h` |
| `update` | - | `update_mole` | `--force/-f`, `--nightly`, `-h` |
| `remove` | - | `remove_mole` | `--dry-run/-n`, `-h` |
| `help` | `--help`, `-h` | `show_help` | - |
| `version` | `--version`, `-V` | `show_version` | - |

알 수 없는 명령은 stderr에 출력하고 exit 1입니다.

### 6.3 설정과 상태 파일 위치

| 경로 | 내용 |
|---|---|
| `~/.config/mole/whitelist` / `whitelist_optimize` / `whitelist_checks`(레거시) | §3 |
| `~/.config/mole/purge_paths` | purge 검색 경로 |
| `~/.config/mole/clean-list.txt` | dry-run 최종 목록 |
| `~/.config/mole/install_channel` | 설치 채널 receipt(stable/nightly) |
| `~/.cache/mole/update_message`, `version_check` | 업데이트 알림 캐시(성공 1일, 실패 1시간) |
| `~/.cache/mole/tmp` | Mole 임시 루트(하루 지난 항목 prune) |
| `~/.cache/mole/pkg_receipt_apps_v1` | pkgutil 캐시 |
| `~/.cache/mole/installed_apps_cache`, `brew_last_cleanup`, `permissions_granted` | 기타 캐시 |
| `~/Library/Logs/mole/*` | §5 |
| `/Library/MoleTrashStaging` | 특권 Trash staging(root 0711, 영구 보존) |
| `$TMPDIR/mole.registry.<pid>`, `mole.XXXXXX` | 임시파일 레지스트리(`base.sh:1362-1500`) |

---

## 7. Swift 포팅 노트

### 7.1 권장 타입

```swift
enum DeleteMode { case trash, permanent }
enum ProbeState { case running, notRunning, unknown }          // unknown은 항상 deny
enum RefusalReason: String { case invalidPath, critical, protected, whitelist, liveCache,
    sqliteInUse, downloadInUse, compiledModelCache, identityChanged, mutableParent,
    ownerUnverified, appReappeared, privacyDenied, trashUnavailable, timedOut, cancelled }
enum DeleteError: Error { case sip, authFailed, readOnlyFS, protectedPath, privacyDenied,
    mutableParent, ownerUnverified, appReappeared, timedOut, cancelled, other(errno: Int32) }

struct FileIdentity: Equatable { let parentPath: String; let parentDevIno: (dev_t, ino_t); let devIno: (dev_t, ino_t); let mtime: timespec? }

struct PathPolicy {                 // file_ops.sh 1044-1379 이식
    func normalize(_ p: String) -> String            // //, /./, 끝의 /, Data 볼륨 firmlink
    func isCritical(_ p: String) -> Bool             // 문자열 deny + inode 비교(stat st_dev/st_ino)
    func validate(_ url: URL) async -> Result<Void, RefusalReason>
}
struct ProtectionPolicy {           // app_protection(_data).sh
    let systemCritical, appleUninstallable, dataProtected: [GlobPattern]
    let officialUninstallers: [VendorRule]; let edrPrefixes: [String]
    func shouldProtect(path: String, mode: Mode /* .clean | .uninstall */) -> Bool
    func canUninstall(bundleID: String) -> Bool
    func officialUninstallerVendor(bundleID:name:appURL:) -> String?
}
struct Whitelist {                  // ~/.config/mole/whitelist와 호환
    var userPatterns: [String]; static let defaults: [String]; static let safety: [String]
    func isWhitelisted(_ p: String) -> Bool          // 정확/glob, 조상, 자손(glob이 없을 때)
}
actor SafeDeleter {
    func remove(_ url: URL, expected: FileIdentity?, dryRun: Bool) async -> Outcome   // safe_remove
    func delete(_ url: URL, mode: DeleteMode, needsPrivilege: Bool) async -> Outcome   // mole_delete
}
protocol PrivilegedHelperProtocol { // XPC
    func remove(path: String, expectedDevIno: [UInt64], reply: @escaping (Int32, String?) -> Void)
    func stageForTrash(path: String, uid: uid_t, reply: @escaping (String?, Int32) -> Void)
    func runMaintenance(task: String, reply: @escaping (Int32) -> Void)              // 허용 목록에 있는 작업만
}
actor OperationLog { func session(_ cmd: String, dryRun: Bool) -> RunID; func record(_ action: Action, path: String, detail: String?) }
struct HistoryStore { func load(limit: Int) -> HistoryJSON }  // Mole JSON 스키마 호환
```

### 7.2 매핑과 주의점

| 주제 | Mole 방식 | Swift 권장 | 주의 |
|---|---|---|---|
| glob 매칭 | bash `[[ == ]]`(`*`가 `/`도 넘음) | `fnmatch(pattern, path, 0)`(**`FNM_PATHNAME` 없이**). 성능을 위해 패턴을 미리 `NSRegularExpression` 하나로 합침 | `*IME`, `*dropbox*`처럼 부분 문자열 패턴이 많으므로 `FNM_PATHNAME`을 쓰면 의미가 달라짐. uninstall regex는 대소문자 구분이고, should_protect_data의 일부는 case 분기 |
| 대소문자 | `nocasematch`와 inode 비교를 함께 사용 | `URLResourceKey.fileResourceIdentifierKey` 또는 `stat` 비교 | APFS는 대소문자를 구분하지 않음. 문자열 비교만으로는 `/SYSTEM`을 놓침 |
| symlink | `-L`, `cd -P`, `readlink` | `lstat`, `realpath`, `URL.resolvingSymlinksInPath()`(주의: `/private` 처리) | `resolvingSymlinksInPath`는 `/private/var`를 `/var`로 바꿈. deny list는 두 형태를 모두 포함해야 함 |
| TOCTOU | 스냅샷 후 프로브, 그다음 재바인딩 | `open(O_NOFOLLOW\|O_DIRECTORY)`로 부모 fd를 잡고 `unlinkat`/`renameatx_np`, `fstat`으로 dev:ino 확인 | bash보다 더 강하게 만들 수 있음. 재귀 삭제는 `removefile(3)`이나 fd 기반 walk(`FTS_PHYSICAL`) 사용 |
| 영구 삭제 | `rm -rf` | `removefile(path, nil, REMOVEFILE_RECURSIVE)` 또는 `FileManager.removeItem` | 링크를 따라가지 않는지 확인. 취소는 `removefile_state` 콜백 |
| Trash | trash CLI, Finder AppleScript, 직접 mv | `FileManager.trashItem(at:resultingItemURL:)`(NSWorkspace.recycle) | 실패 시 영구 삭제로 **fallback 금지**. App Management(TCC)가 `/Applications/*.app` 이동을 막을 수 있음 → `NSWorkspace.shared.recycle` 사용, 그래도 실패하면 사용자에게 Finder 안내 |
| 특권 | `sudo -n`과 keepalive | `SMAppService.daemon(plistName:)`과 XPC(`NSXPCConnection`, code-signing requirement로 클라이언트 검증) | helper는 **경로 문자열을 신뢰하지 말고** 자체적으로 `PathPolicy`와 mutable-ancestor 검사를 다시 수행. 작업은 enum 허용 목록만. 앱 자체는 root로 실행하지 않음 |
| 인증 | sudo PAM 또는 Touch ID | `LAContext`(`.deviceOwnerAuthentication`)로 사용자를 확인한 뒤 helper 호출, 또는 Authorization Services | Touch ID PAM 편집(`mo touchid`)은 GUI 앱 범위 밖으로 둘 것을 권장. 포함한다면 `sudo_local`만 수정 |
| 특권 Trash | `/Library/MoleTrashStaging` 경유 | helper가 rename으로 staging 디렉터리(root 0711)에 옮기고 `chown -Rhx` 후 앱이 사용자 Trash로 이동 | 같은 볼륨만 허용. 실패하면 payload 보존 |
| 프로세스 | `pgrep`, `ps`, `lsof` | `NSWorkspace.runningApplications`(bundle id), `proc_listpids`, `proc_pidpath`, `proc_pidfdinfo`(열린 파일) | **unknown(권한 부족 등)은 deny**. 다른 사용자의 프로세스 fd는 helper가 필요할 수 있음 |
| 앱 종료 | AppleEvent quit, SIGTERM, SIGKILL | `NSRunningApplication.terminate()` → 대기 → `forceTerminate()` | Finder, Dock 등의 이름 차단 목록을 유지. Electron 같은 공유 실행 파일명은 bundle id로만 다룸 |
| 크기 | `du -skP`, `stat %b`, `mdls` | `URLResourceKey.totalFileAllocatedSizeKey`(또는 `fileAllocatedSize`) 열거, hardlink는 inode 집합으로 한 번만 계산 | APFS clone과 sparse 파일은 할당 크기로 계산. 측정을 timeout하면 "+" 하한값. 디렉터리 크기 **캐시 금지** |
| timeout | `run_with_timeout`과 deadline | `Task`와 `withThrowingTaskGroup`의 sleep race, `ContinuousClock.Instant` deadline | 124(timeout)와 취소를 구분. 취소하면 이후 작업 전체 중단, timeout이면 해당 항목만 건너뜀 |
| 로그 | 텍스트 oplog와 TSV | 같은 형식을 유지하면 `mo history`와 호환. 또는 JSONL + export | 경로의 제어문자 escape. 쓰기 실패 시 경고 1회. 동기 append |
| FDA | Permission denied 카운트로 안내 | `~/Library/Safari` 같은 TCC 경로 접근을 시도해 Full Disk Access 여부를 감지하고 안내 | sandbox 앱이면 불가 → **비샌드박스 배포(Developer ID)** 필요 |
| whitelist 파일 | 읽을 수 없으면 중단 | 동일하게 fail closed | `~/.config/mole/whitelist`를 공유하면 CLI 사용자의 설정을 이어받을 수 있음(선택) |

### 7.3 반드시 지킬 불변식 (체크리스트)
1. 모든 삭제는 **하나의 깔때기**(`SafeDeleter`)를 거칩니다. 우회 경로를 두지 않습니다.
2. 검증 순서: 형식 → 정규화 → leaf/조상 symlink → 명시적 허용 예외 → live process/SQLite/다운로드 → EDR → `/private` 허용 목록 → critical deny → protection → whitelist → existence → dry-run 분기 → 크기 측정 → **재검사**(model cache, live cache, identity, 최종 가드) → 삭제.
3. 판단 불가(unknown)는 **항상 거부**합니다(프로세스, lsof, whitelist 파일, sudo ACL probe).
4. Trash 모드에서 실패해도 영구 삭제로 바꾸지 않습니다.
5. dry-run은 실제 실행과 같은 대상 집합이 나와야 합니다(같은 검증을 거친 뒤 분기).
6. 특권 작업: 모든 조상이 root 소유이고 0022 비트가 없으며 symlink가 아닐 때만 허용합니다. 그 외에는 사용자 권한으로 강등하거나 거부합니다.
7. 크기 측정 timeout은 해당 항목의 크기를 unknown(하한값 표시)으로 처리합니다. 사용자 취소(signal)는 전체를 중단하고 누적된 배치를 폐기합니다.
8. 자기 로그 디렉터리(`~/Library/Logs/mole` → 맥클린 로그 경로)는 보호합니다.
9. 앱은 root로 실행하지 않고, 특권 helper는 경로를 다시 검증합니다.
