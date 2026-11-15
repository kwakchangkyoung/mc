# 04. `mo optimize` / `mo touchid` / `mo history` / status·analyze 래퍼 — 포팅 명세

> 원본: Mole (GPL-3.0), 읽기 전용 분석. 경로는 저장소 루트 기준. `file:line` 인용.
> 범위: `bin/optimize.sh`, `lib/optimize/{catalog,diagnostics,maintenance,outcomes,tasks}.sh`, `bin/touchid.sh`(+`lib/core/sudo.sh` PAM 헬퍼), `bin/history.sh`(+`lib/core/history.sh` 렌더러), `bin/status.sh`, `bin/analyze.sh`, 규칙 문서 `.claude/rules/optimize.md`.

---

## 0. 실행 흐름 개요 (`bin/optimize.sh`)

| 단계 | 내용 | 위치 |
|---|---|---|
| root 거부 | `EUID==0`이면 "Run Mole without sudo…" 후 exit 1. 관리자 권한은 개별 작업이 요청 | optimize.sh:10-13 |
| 로케일 | `LC_ALL=C`, `LANG=C` | :16-17 |
| 인자 | `--help/-h`, `--debug`(MO_DEBUG=1), `--dry-run/-n`(MOLE_DRY_RUN=1), `--whitelist`(관리 UI 후 종료), 그 외 exit 1 | :213-235 |
| 세션 로그 시작 | `log_operation_session_start optimize` | :237 |
| 의존성 | `bc` 없으면 `brew install bc` 안내 후 exit 1 | :252-256 |
| 시스템 정보 | `generate_health_json`(메모리/디스크/업타임 + 카탈로그) → 키 검증 실패 시 exit 1 | :262-279, lib/check/health_json.sh:111 |
| 화이트리스트 로드 | `~/.config/mole/whitelist_optimize`, 3개 이하일 때 "Active Whitelist:" 출력 | :285-295, lib/manage/whitelist.sh:22 |
| 헬스 라인 | `System  {memUsed}/{memTotal} GB RAM \| {diskUsed}/{diskTotal} GB Disk \| Uptime {n}d` (C-locale awk 반올림, #1220) | :128-155 |
| 성능 진단 | `run_optimize_diagnostics` (읽기 전용 + 선택적 DMG detach) | :299, diagnostics.sh:342 |
| sudo 1회 획득 | dry-run이면 `MOLE_OPTIMIZE_SUDO_AVAILABLE=true`, 아니면 `ensure_sudo_session "System optimization requires admin access"`; 거부 시 false 후 "Skipping sudo-required optimizations" | :306-313 |
| 작업 루프 | 카탈로그 순서대로 `announce_action(health_name)` → `execute_optimization(action)` | :318-323 |
| 무결성 | 기록된 outcome 수 ≠ 카탈로그 수 → "Optimize task outcomes are incomplete", return 1 | :325-328 |
| 요약 | `show_optimization_summary` | :330, :55-126 |
| 종료코드 | failed outcome 0개면 0 | :333, outcomes.sh:178 |
| EXIT trap | spinner/sudo keepalive 정지, temp 정리, `TASK_FAILED`(failed 작업), dry-run 아니면 `REBUILT`(applied 작업) 로그, 비정상 종료 시 `session`/`interrupted`(130) 로그, 세션 종료 마커 | :168-206 |

**`generate_health_json` 수치 산출** (lib/check/health_json.sh): 총메모리 `sysctl -n hw.memsize`; 사용 메모리 = (active + wired + compressor pages) × page size (`vm_stat` 헤더의 page size, 없으면 `hw.pagesize`, 없으면 4096) (:23-54); 디스크 `df -k $HOME` (:57-80); 업타임 `sysctl -n kern.boottime` (:83-100).

---

## 1. 작업 카탈로그 (실행 순서 = 등록 순서, catalog.sh:31-87)

모든 작업은 `safe=true`로 등록되어야 하며 검증 실패 시 로드 중단 (catalog.sh:113-161). ID 규칙 `^[a-z0-9_]+$`, 핸들러 `^opt_[a-z0-9_]+$`, 중복 금지.

공통 규칙:
- 화이트리스트에 action id가 있으면 핸들러 호출 없이 `Skipped (whitelisted): <name>` → **skipped** (tasks.sh:2117-2126). `network_optimization`은 레거시 id `system_maintenance`도 인정 (:2118).
- "sudo 필요" 작업은 `optimize_sudo_available`로 판정 (tasks.sh:39-44): 테스트 모드면 항상 false, 그 외 `MOLE_OPTIMIZE_SUDO_AVAILABLE==true`.
- 타임아웃 상수 (lib/core/timeouts.sh:61-67): QUICK_DETECT=2s, SHORT_QUERY=3s, MEDIUM_PROBE=5s, PKG_LIST=10s, PKG_CLEANUP=20s, DISK_VERIFY=30s, HINT_SCAN=15s.
- `safe_remove`(lib/core/file_ops.sh:1473)는 보호경로/화이트리스트 검사 및 삭제 로그를 담당(타 문서 범위).

### 1.1 요약표

| # | id / 표시명 | 하는 일 | 실행 명령 (정확히) | admin | 실행 조건 / 결정 로직 | 위험·비고 | 소스 |
|---|---|---|---|---|---|---|---|
| 1 | `cache_refresh` / Finder Cache Refresh | QuickLook·아이콘 캐시 리셋 + 캐시 디렉터리 삭제 | `qlmanage -r cache`; `qlmanage -r`; 삭제 대상: `~/Library/Caches/com.apple.QuickLook.thumbnailcache`, `~/Library/Caches/com.apple.iconservices.store`, `~/Library/Caches/com.apple.iconservices` (`safe_remove`) | 아니오 | 항상. 존재·비보호 경로만 삭제. 크기 합계 → `OPTIMIZE_CACHE_CLEANED_KB` | LOW. dry-run이면 qlmanage 미실행; 삭제 루프는 dry-run에서도 `safe_remove`를 호출하지만 `safe_remove`가 dry-run 시 기록만 하고 삭제하지 않음(lib/core/file_ops.sh:1552-). `safe_remove`는 화이트리스트 경로도 SKIPPED 처리(:1532-1536). outcome = counts(removed+ql+icons, fails) | tasks.sh:209-309 |
| 2 | `saved_state_cleanup` / App State Cleanup | 30일 넘은 `*.savedState` 삭제 | `find "~/Library/Saved Application State" -type d -name "*.savedState" -mtime +30 -print0` (5s 타임아웃) → `safe_remove` | 아니오 | 디렉터리 존재 시. `MOLE_SAVED_STATE_AGE_DAYS=30` (lib/core/base.sh:161) | LOW. 보호 경로 skip | tasks.sh:316-373 |
| 3 | `fix_broken_configs` / Broken Config Repair | 손상된 서드파티 plist 삭제 | `find ~/Library/Preferences -maxdepth 1 -name "*.plist" -type f`, `find ~/Library/Preferences/ByHost -name "*.plist" -type f`; `/usr/bin/plutil -lint <512개 배치>` 실패 배치만 파일별 재검사 → `safe_remove` | 아니오 | `com.apple.*`, `.GlobalPreferences*` 제외; 최상위에서 `loginwindow.plist` 제외(ByHost는 미제외). 읽기 불가 파일은 **유지**+`SKIPPED unreadable preference` 로그. 보호/화이트리스트 skip. 15s 예산 초과 시 partial→failed | 반드시 절대경로 `/usr/bin/plutil` (PATH shim 방지). 결과 수 → `OPTIMIZE_CONFIGS_REPAIRED` | tasks.sh:381-421, maintenance.sh:7-129, rules/optimize.md:12-13 |
| 4 | `network_optimization` / Network Cache Refresh | DNS 캐시 플러시 | ① VPN 검사(아래) ② `/usr/bin/plutil -extract Label raw -o - /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist` ③ `sudo dscacheutil -flushcache` ④ `sudo /bin/launchctl kill SIGHUP system/<label>` ⑤ ④ stderr가 `Not privileged to signal service`일 때만: `sudo -u _mdnsresponder /usr/bin/killall -u _mdnsresponder -HUP mDNSResponder` | **예** | sudo 없음→skipped. VPN 활성→skipped, VPN 판정불가→failed. Label이 `com.apple.mDNSResponder` 또는 `com.apple.mDNSResponder.reloaded`(macOS 26)가 아니면 failed(캐시 변경 전). ⑤ 실패 → skipped("macOS does not allow signaling mDNSResponder") | **절대 `sudo killall -HUP mDNSResponder`(root) 금지**, PID 기반 금지. macOS 27은 launchctl kill을 root에게도 거부(#1867). SIGHUP은 WireGuard 등 VPN 재연결 유발 → VPN 시 skip | tasks.sh:164-206, 424-462, rules/optimize.md:17 |
| 5 | `sqlite_vacuum` / Database Optimization | Mail/Messages/Safari SQLite VACUUM | `pgrep -x Mail|Safari|Messages`; 대상 glob: `~/Library/Mail/V*/MailData/Envelope Index*`, `~/Library/Messages/chat.db`, `~/Library/Safari/History.db`, `~/Library/Safari/TopSites.db`; `file -b`(SQLite 확인); `sqlite3 db "PRAGMA page_count; PRAGMA freelist_count;"`(5s); `sqlite3 db "PRAGMA integrity_check;"`(10s, 결과 `ok` 필요); `sqlite3 db "VACUUM;"`(20s) | 아니오 | 앱 실행 중이면 skipped("Close these apps…"). pgrep 없음→unavailable; pgrep 오류(rc≠0,1)→failed; sqlite3 없음→unavailable. `-wal/-shm` 제외, >100MB(`MOLE_SQLITE_MAX_SIZE=104857600`) skip(정책 skip 목록 출력), freelist < 5% page → already optimal | integrity 실패/timeout → failed 카운트. FDA 필요(Mail/Messages/Safari 경로). 결과 vacuumed → `OPTIMIZE_DATABASES_COUNT`. outcome = counts(vacuumed, timeout+failed, policy_skipped) | tasks.sh:528-712 |
| 6 | `prevent_network_dsstore` / Prevent Finder .DS_Store | 네트워크/USB 볼륨에 .DS_Store 미생성 | `defaults read com.apple.desktopservices DSDontWriteNetworkStores` / `DSDontWriteUSBStores`; 값≠1이면 `defaults write com.apple.desktopservices <key> -bool true` | 아니오 | 각 키 이미 1이면 unchanged | 사용자 설정 영구 변경(되돌리기: `defaults delete com.apple.desktopservices DSDontWrite{Network,USB}Stores`). Finder 재시작 전엔 반영 안 될 수 있음(원본은 재시작 안 함) | tasks.sh:1096-1136 |
| 7 | `legacy_overrides_audit` / Legacy Overrides | 옛 트윅 툴이 남긴 숨은 오버라이드 삭제 | 검사: `defaults read -g NSAppSleepDisabled`; `defaults read com.apple.frameworks.diskimages skip-verify|skip-verify-locked|skip-verify-remote`. 수정: `defaults delete -g NSAppSleepDisabled`, `defaults delete com.apple.frameworks.diskimages <key>` | 아니오 | 값이 `1/true/yes`(대소문자 무시)일 때만 대상. 해당 plist(`~/Library/Preferences/.GlobalPreferences.plist`, `…/com.apple.frameworks.diskimages.plist`)가 화이트리스트면 skip | 키 삭제만, 대체값 쓰기 없음 (#1242, #1243) | tasks.sh:1145-1210 |
| 8 | `network_stack_optimize` / Network Stack Refresh | 라우팅 테이블·ARP 플러시 | VPN 검사; 헬스: `route -n get default`(3s), `dscacheutil -q host -a name example.com`(3s); 문제 있을 때만 `sudo route -n flush`, `sudo arp -a -d` | **예** | VPN 활성→skipped, 판정불가→failed. 두 헬스체크 모두 OK면 unchanged(**실제론 거의 항상 skip**). timeout/rc>1 → failed. sudo 없음→skipped | `route -n flush`는 모든 라우트 삭제 → 연결 일시 단절. 분할 터널 VPN 미검출 시 라우트 손실 가능 | tasks.sh:720-822 |
| 9 | `disk_permissions_repair` / Permission Repair | 홈 권한 리셋 | `stat -f %Su $HOME`; `sudo diskutil resetUserPermissions / <uid>` | **예** | `$HOME` 소유자≠`$USER` 이거나 `$HOME`, `~/Library`, `~/Library/Preferences` 중 쓰기 불가가 있을 때만 (`needs_permissions_repair`) | MEDIUM. 장시간, ACL 일괄 변경 | tasks.sh:69-89, 825-876 |
| 10 | `spotlight_index_optimize` / Spotlight Optimization | 느릴 때만 인덱스 재구축 | `mdutil -s /`(3s); `pmset -g batt`("AC Power" grep); `mdfind "kMDItemFSName == 'Applications'"` ×2 (각 5s, 사이 1s sleep); 조건 충족 시 `sudo mdutil -E /` | **예**(재구축 시) | "Indexing disabled"→skipped. "Indexing enabled"이고 "Indexing and searching disabled" 아님 → 배터리면 skipped; 두 프로브 모두 >3s(`MOLE_OPTIMIZE_SPOTLIGHT_SLOW_SEC`) 또는 timeout → 재구축. 프로브 오류→failed. 그 외 unchanged | 재구축 1-2시간, CPU/배터리 부하 | tasks.sh:879-977 |
| 11 | `spotlight_orphan_rules_cleanup` / Spotlight Orphan Rules | 삭제된 앱의 Spotlight 규칙 항목 제거 | `defaults read com.apple.spotlight EnabledPreferenceRules`; 스냅샷 `/usr/bin/plutil -convert xml1 -o - ~/Library/Preferences/com.apple.spotlight.plist`; `plutil -extract EnabledPreferenceRules raw -expect array`(개수), `…EnabledPreferenceRules.<i> raw -expect string`; 앱 존재 판정 `bundle_has_installed_app`(`mdfind "kMDItemCFBundleIdentifier == '<id>'"` → 앱 루트 Info.plist 스캔, SMJobBless 헬퍼 포함); 쓰기 직전 스냅샷 재비교 후 `defaults write com.apple.spotlight EnabledPreferenceRules -array <keep…>` 또는 전부 제거 시 `defaults delete com.apple.spotlight EnabledPreferenceRules` | 아니오 | `System.*`, `com.apple.*` 항상 유지. 역DNS 형식이 아니거나 첫 라벨이 소문자/숫자가 아니면 유지(`Custom.relatedContents` 등 스위치 보호, #1878). resolver rc=1일 때만 제거, 그 외 유지. 스냅샷 변경 시 failed | 반드시 cfprefsd 경유(`defaults`) — 파일 직접 편집 금지 (#1000) | tasks.sh:984-1090, lib/core/bundle_resolver.sh:41-, lib/core/base.sh:1123-1128, rules/optimize.md:14 |
| 12 | `periodic_maintenance` / Periodic Maintenance | daily/weekly/monthly 스크립트 실행 | `command -v periodic`; `/var/log/daily.out` mtime; `sudo periodic daily weekly monthly` | **예** | `periodic` 없음(macOS 26+)→unavailable. 로그가 7일 미만→unchanged. 로그 없으면 stale 간주 | macOS 26+에서는 사실상 항상 unavailable | tasks.sh:1294-1342 |
| 13 | `shared_file_list_repair` / Shared File Lists | 손상된 `.sfl2/3/4` 삭제 | `find "~/Library/Application Support/com.apple.sharedfilelist" \( -name "*.sfl2" -o -name "*.sfl3" -o -name "*.sfl4" \) -type f ! -path "*ApplicationRecentDocuments*" -print0`(5s); `plutil -lint <f>`(PATH plutil!) 실패 시 `safe_remove` | 아니오 | 디렉터리 없으면 unchanged. find 오류가 권한 오류뿐이면 unavailable("check … Full Disk Access") | `.sfl*`는 NSKeyedArchiver bplist이므로 lint 통과가 정상. ApplicationRecentDocuments 제외 | tasks.sh:1345-1421 |
| 14 | `disk_verify` / Disk Health | 파일시스템 검증 | `diskutil verifyVolume /`(30s) | 아니오 | **기본 비활성**: `MOLE_ENABLE_DISK_VERIFY=1`일 때만. dry-run이면 skipped. 출력 "appears to be OK"→unchanged, "error/corrupt/invalid"→attention("run: sudo diskutil repairVolume /"), 미인식→failed | APFS 불일치 시 커널 I/O가 SIGKILL로도 안 끊겨 시스템 프리즈 위험 | tasks.sh:1502-1541 |
| 15 | `login_items_audit` / Login Items (whitelist명 "Login Items Audit") | 깨진 로그인 항목 **보고만** | `osascript` (System Events `login items`의 name + POSIX path); `mdfind "kMDItemFSName == '<name>.app'"` (이름, 공백제거, `Client|Helper|Agent|Launcher|Service` 접미사 제거 변형); `find ~/Applications /Applications -maxdepth 6 -type d -iname "*.app"` + `/usr/bin/plutil -lint/-extract CFBundleDisplayName|CFBundleName|CFBundleExecutable`; sudo 세션 살아있을 때만 `sudo -n true` → `sudo -n sfltool dumpbtm` | 선택(BTM 폴백만) | 테스트 모드 skip. 15s 전체 데드라인. 깨진 항목 있으면 attention("remove via System Settings > General > Login Items"). 프로브 불확실/실패 → failed, 타임아웃 → unavailable | 삭제 안 함. AppleEvents(System Events) 자동화 권한 필요. 비-root `sfltool dumpbtm`은 관리자 대화상자 띄우므로 sudo -n만 사용 | tasks.sh:1618-2098 |
| 16 | `quarantine_cleanup` / Quarantine Database Cleanup | Gatekeeper 다운로드 이력 삭제 | `sqlite3 ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2 "SELECT COUNT(*) FROM LSQuarantineEvent;"`(5s); `… "DELETE FROM LSQuarantineEvent; VACUUM;"`(10s) | 아니오 | sqlite3 없음→unavailable. 파일 없음/보호/0행→unchanged | 파일의 quarantine xattr에는 영향 없음. 개인정보 이력 삭제(사용자 의도 확인 권장) | tasks.sh:465-525 |
| 17 | `launch_agents_cleanup` / Launch Agents Cleanup | 프로그램 없는 LaunchAgent **보고만** | `/usr/libexec/PlistBuddy -c "Print :Program"` → 없으면 `"Print :ProgramArguments:0"`, `"Print :Label"` (각 2s) on `~/Library/LaunchAgents/*.plist` | 아니오 | 절대경로이면서 미존재 + 미마운트 `/Volumes/<disk>` 아님 → 깨짐. 있으면 attention | 삭제·`launchctl unload` 안 함 (#1617). 출력 텍스트는 터미널 이스케이프 제거 | tasks.sh:1215-1289 |
| 18 | `notification_cleanup` / Notifications | 30일 지난 알림 레코드 삭제 | DB 경로: `~/Library/Group Containers/group.com.apple.usernoted/db2/db`(15+) 또는 `$(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db`; `stat -f%z`; `sqlite3 db "DELETE FROM record WHERE delivered_date < strftime('%s','now','-30 days'); VACUUM;"`; 성공 후 `/bin/launchctl kill SIGTERM gui/$UID/com.apple.notificationcenterui.agent`(5s, 실패 무시) | 아니오 | DB 없음→unavailable. <50MB(51200KB)→unchanged. SQL 실패→failed("busy or locked"). dry-run은 신호 미전송 | **`killall NotificationCenter` 금지**, PID kill 금지. 그룹 컨테이너 접근에 FDA 필요 가능 (#1368). 주: `delivered_date`는 Mac epoch(2001) 기준일 수 있어 Unix epoch 비교가 의도대로인지 검증 필요 | tasks.sh:1429-1496, rules/optimize.md:16 |
| 19 | `coreduet_cleanup` / Usage Data | 90일 지난 Knowledge(사용 추적) 레코드 삭제 | `du -skcP knowledgeC.db{,-wal,-shm}`(30s); `sqlite3 "~/Library/Application Support/Knowledge/knowledgeC.db" "DELETE FROM ZOBJECT WHERE ZCREATIONDATE < (strftime('%s','now','-90 days') - strftime('%s','2001-01-01')); VACUUM;"` | 아니오 | DB 없음→unchanged. 합계 <100MB(102400KB)→unchanged. sqlite3 없음→unavailable | **WAL/SHM을 먼저 지우지 말 것**(커밋된 트랜잭션 손실; AGENTS.md Critical Safety Rule). SQLite가 스스로 체크포인트하게 둠. 실행 중 데몬과 경합 → busy | tasks.sh:1544-1612, rules/optimize.md:15 |

### 1.2 VPN 판정 `has_active_vpn_interface` (tasks.sh:97-155)

| 반환 | 의미 | 근거 |
|---|---|---|
| 0 | VPN 활성 | `scutil --nc list`(3s) 출력에 `^\* \(Connected\)` 또는 `route -n get default`(3s)의 `interface:`가 `^utun[0-9]+$` |
| 1 | VPN 없음 | 위 둘 다 아님, 또는 route 출력에 `not in table`(오프라인) |
| 2 | 판정 불가 | scutil/route 명령 없음, scutil rc≠0, route rc≠0(not in table 제외) |
- 단순 utun 존재로 판정하지 않음(iCloud Private Relay/Continuity 등 오탐, #959). 분할 터널 VPN은 미검출.
- 테스트 오버라이드 `MOLE_ASSUME_VPN_ACTIVE`.

### 1.3 제거·금지된 작업 (재구현 금지)

| 항목 | 이유 | 위치 |
|---|---|---|
| LaunchServices 재구축(`lsregister -r`, `launch_services_rebuild`) | 실행 중 Network Extension VPN이 재설치된 것으로 인식됨. 테스트가 `lsregister -r` 호출을 금지 | rules/optimize.md:11, whitelist.sh:7-12 |
| `dock_refresh`, `memory_pressure_relief` | 은퇴(화이트리스트 패턴만 남음) | whitelist.sh:9 |
| `opt_maintenance_scripts` | launchd가 로그 회전 처리 | tasks.sh:311 |
| `opt_radio_refresh` (Wi-Fi/BT 토글) | 사용자 연결 끊김 | tasks.sh:313 |
| `opt_swap_cleanup` | 크래시 위험 | tasks.sh:375 |
| `opt_startup_cache` | 현대 macOS에 없음 | tasks.sh:377 |
| `opt_local_snapshots` (TM 스냅샷 삭제) | 백업 복구 지점 파괴 | tasks.sh:379 |
| `opt_startup_items_cleanup`, `opt_dyld_cache_update`, `opt_system_services_refresh` | 헬퍼 오삭제 / 저효용 / 데이터 손실 | tasks.sh:714-717 |
| `killall NotificationCenter`, root `killall -HUP mDNSResponder`, PID 기반 kill | 동명 서드파티 프로세스 매칭·PID 재사용 | rules/optimize.md:16-17 |

---

## 2. 진단(diagnostics) 및 결과(outcome) 보고

### 2.1 성능 진단 `run_optimize_diagnostics` (diagnostics.sh:342-434) — 읽기 전용

| 체크 | 입력 명령 | 판정 | 출력 |
|---|---|---|---|
| CPU 패밀리 | `ps -Aceo pcpu=,command=` 2회, 1초 간격 (:41, :347) | 각 패밀리 CPU 합이 두 샘플 모두 ≥25% (:6, :367) → sustained. 최대 평균이 primary | `Likely bottleneck: <label> (~N% CPU sustained)` + 노트, 추가 패밀리 목록 (:394-404) |
| 패밀리 분류 (:65-73) | cloudshell(`cloudshell|alientsafe|aliedr`), syspolicyd, windowserver, spotlight(`mds`,`mdworker`,`mds_stores`,`mdbulkimport`), coresim_disk_images(`diskimagesiod|simdiskimaged`) | 소문자 정규식 | 라벨/노트 (:97-129). CloudShell은 "종료하지 않음" 명시 |
| 메모리 압박 | `sysctl -n vm.swapusage`, `memory_pressure`의 "free percentage" (:456-470) | swap ≥50% **또는** free <15% (:446-447, :536) | `Memory pressure: swap X of Y used (P%), F% free` + RSS 상위 4개(>256MB, `ps -Ao rss,comm`, CoreSimulator 제외) (:520-589) |
| 유휴 VM | `ps -Ao rss,command`에서 `Virtualization.framework.*VirtualMachine` RSS 합 (:491-499, :598) | >2GB (:448). 로컬 Docker 엔드포인트일 때만 `docker ps -q`(3s)로 컨테이너 수 확인 (:611-618) | 0개면 "likely Docker Desktop… quitting reclaims", 아니면 정보성 (:621-631) |
| 폭주 프로세스 | `ps -Ao pid,time,etime,comm` 상위 400행 (:487, :653) | 경과 >12h 이고 TIME/ELAPSED ≥25% (:449-450, :666-671). `kernel_task, WindowServer, mds, mds_stores, syspolicyd, mdworker*` 제외 | `<comm> has burned Xh CPU over Yh … kill -TERM <pid>` 제안만 (:650-651) |
| 마운트 이미지 | syspolicyd sustained일 때만: `spctl --status`, `hdiutil info`(8s) (:44-60, :414-433) | `/dev/disk*` 행의 마운트만 파싱(:131-181). 후보: `/Volumes/*` + 확장자 `.dmg .iso .img .cdr .sparseimage .sparsebundle`, 시스템 관리(`/System/*`, `/Library/Apple/*`, cryptexd, CoreSimulator Volumes) 제외, 보호/화이트리스트 제외 (:183-228) | 목록 출력 → TTY면 "Detach now? Enter/Space" → `hdiutil detach <mount>`(15s) (:276, :293-340). dry-run/non-TTY는 안내만 |
| 정상 | — | 위 어느 것도 없음 | `No sustained high-CPU bottleneck detected` (:389-390) |

### 2.2 Outcome 모델 (outcomes.sh)

| outcome | 의미 (outcomes.sh:11-17) |
|---|---|
| `applied` | 변경 완료(또는 dry-run에서 완료 예정) |
| `unchanged` | 검사 완료, 변경 불필요 |
| `skipped` | 정책/컨텍스트(화이트리스트, sudo 없음, VPN, 배터리, 앱 실행 중)로 의도적 미실행 |
| `unavailable` | 호스트가 기능 미제공(sqlite3/periodic 없음, 권한 부족, 타임아웃) |
| `attention` | 검사 완료, 사용자 조치 필요한 문제 발견(로그인 항목, LaunchAgent, 디스크) |
| `failed` | 대상 작업 실패 |

- 상태기계: `optimize_task_start` → 정확히 1회 `optimize_task_result` → `optimize_task_finish(action)`; 중복/누락 시 에러 (:53-136).
- `optimize_task_result_from_counts(applied, failed, skipped)`: failed>0 → failed; applied>0 → applied; skipped>0 → skipped; else unchanged (:82-104). **부분 실패도 failed**.
- 집계: `optimize_outcome_count`, `optimize_actions_with_outcome`, 성공 = failed 0 (:138-180).

### 2.3 요약 블록 (optimize.sh:55-126)

| 모드 | 제목 | 상세 줄 |
|---|---|---|
| dry-run | `Dry Run Complete, No Changes Made` | `Would apply N optimizations` / outcome 줄 / `Run without --dry-run to apply these changes` |
| 실제 | `Optimization Complete` | `Applied N optimizations[, <key_stat>]` — key_stat 우선순위: `<size> cache cleaned`(OPTIMIZE_CACHE_CLEANED_KB) > `N databases optimized` > `N configs repaired` / outcome 줄 / attention·failed>0 이면 `Review the warnings above` 아니면 `Optimization pass complete` |
- outcome 줄: `N unchanged | N skipped | N unavailable | N need attention | N failed` (0인 항목 생략) (:72-86).
- 각 작업 메시지: dry-run `☐`(ICON_DRY_RUN, 노랑) / 실제 `✓`(초록) 접두 (tasks.sh:20-27); 경고는 노랑 ICON_WARNING.

### 2.4 작업 로그 (operations.log)

| 이벤트 | 형식 |
|---|---|
| 세션 시작 | 빈 줄 + `# ========== optimize session started at <ts> ==========` (lib/core/log.sh:313-331) |
| 작업 | `[<ts>] [optimize] TASK_FAILED <action> (task outcome)` / `REBUILT <action> (task outcome)`(dry-run 제외) / `SKIPPED <path> (unreadable preference)` (optimize.sh:180-191, log.sh:288-309) |
| 비정상 종료 | `TASK_FAILED session|interrupted (exit status N)` (optimize.sh:194-198) |

---

## 3. Touch ID for sudo (`bin/touchid.sh`, `lib/core/sudo.sh:15-49`)

### 3.1 파일과 내용

| 항목 | 값 |
|---|---|
| 기본 PAM 파일 | `/etc/pam.d/sudo` (sudo.sh:16). 테스트 모드에서만 `MOLE_PAM_SUDO_FILE` 오버라이드 허용 |
| 로컬 PAM 파일 | `/etc/pam.d/sudo_local` (= sudo 파일 디렉터리 + `/sudo_local`, sudo.sh:21) |
| 삽입 줄 (정확) | `auth       sufficient     pam_tid.so` (touchid.sh:32; `auth` 뒤 공백 7, `sufficient` 뒤 공백 5) |
| 새 sudo_local 생성 내용 | `# sudo_local: local customizations for sudo` + 줄바꿈 + 위 pam_tid 줄 (touchid.sh:144-145) |
| 권한 | `install -m 444 -o root -g wheel` (temp→dst 후 temp 삭제, :34-37) / 신규 생성 시 `sudo tee`, `chmod 444`, `chown root:wheel` (:144-147) |
| 백업 | 레거시 경로에서만 `/etc/pam.d/sudo.mole-backup` (없을 때 1회 생성, :189-194, :273-278) |
| 활성 판정 | `grep -q '^[^#]*pam_tid\.so'` — 주석 처리된 줄은 비활성(macOS `sudo_local.template` 기본이 주석) (sudo.sh:46-49) |

### 3.2 로직

| 명령 | 동작 | 위치 |
|---|---|---|
| `status` | sudo_local에 활성 줄 있으면 enabled, 아니면 sudo 파일 확인 → `Touch ID is enabled for sudo` / `Touch ID is not configured for sudo` | :40-51, :82-88 |
| 지원 여부 | `bioutil -r`에 "Touch ID" → OK; 아니면 `uname -m`==arm64 → OK; 아니면 `system_profiler SPHardwareDataType` Model Identifier의 4자리 연도 ≥2018 (근사, 사실상 Intel 모델ID에 연도 없음 → 대부분 실패) → 미지원 시 `Continue anyway? [y/N]` | :54-75, :106-114 |
| `enable` (Sonoma+ 경로) | 조건: `/etc/pam.d/sudo`에 문자열 `sudo_local` 포함(`include sudo_local`). ① sudo_local 이미 활성 → sudo에도 있으면 `grep -v pam_tid.so`로 sudo 정리("Cleanup legacy configuration") → "already enabled" ② sudo_local 없음 → 생성 ③ 있으나 비활성 → 복사본 끝에 줄 append 후 install ④ sudo 파일에 레거시 줄 있었으면 제거, "migrated to sudo_local" ⑤ 로그 `REBUILT /etc/pam.d/sudo_local (touchid enabled)` | :117-178 |
| `enable` (레거시) | sudo_local 미지원 시: 이미 활성이면 종료; 백업 생성; awk로 **첫 비주석 줄 앞**에 pam_tid 줄 삽입; `cmp`로 변경 확인; install | :183-224 |
| `disable` | 미활성 → 안내. sudo_local 활성 → `grep -v "pam_tid.so"`(주석 줄 포함 모두 제거) 후 install, sudo 파일에도 있으면 함께 제거, `Touch ID disabled, removed from sudo_local`. 아니면 sudo 파일에서 백업 후 제거 | :228-298 |
| 대화형(인자 없음) | 상태 표시 후 Enter=토글, Q/ESC=종료 | :301-348 |
| `--dry-run` | 파일 미수정, 대상 파일 경로만 출력 | :95-103, :232-240, :379-382 |
| 인자 | `enable|disable|status` 중 하나만, `--dry-run/-n`, `--help/-h` | :355-377 |

주의: `disable`은 `grep -v pam_tid.so`라 사용자가 둔 주석 템플릿 줄도 삭제됨. `pam_reattach.so`(tmux용) 등 다른 줄은 보존.

---

## 4. `mo history` 출력 형식 (`bin/history.sh`, 렌더러 `lib/core/history.sh`)

| 항목 | 값 |
|---|---|
| 옵션 | `--json`, `--limit N`(1-200, 선행 0 허용, 0/초과/비숫자 → `Invalid value for --limit`, exit 1), `-h/--help` (history.sh:14-58, history.sh(core):104-113) |
| 기본 limit | 20, 최대 200 (core:17-18) |
| 입력 | `$OPERATIONS_LOG_FILE` 또는 `~/Library/Logs/mole/operations.log`; `$MOLE_DELETE_LOG` 또는 `~/Library/Logs/mole/deletions.log` (core:62-68) |

**텍스트** (core:684-765), 최신순:
```
\nMole History\n\n            (파란색 제목)
Recent sessions
  %-10s %s, %s items, %s          ← command, started_at, items, size
             %s, ended %s         ← counts, ended_at|"not ended"
Deletion audit
  %-24s %-9s %-16s %8s  %s        ← timestamp, mode, status, size(human|unknown), path
Logs
  operations: <path>
  deletions:  <path>
```
- counts: `removed N, trashed N, skipped N, failed N, rebuilt N, other N` 중 >0만 `, ` 결합, 모두 0이면 `no file actions` (core:551-579). 이어서 `, N optimize tasks failed`, `, legacy run attribution uncertain` 추가 (core:722-727).
- 비어 있으면 `  No operation history yet.` / `  No deletion audit entries yet.`
- 로그 값은 제어문자 이스케이프 후 출력(--json은 원값).

**JSON** (core:767-857):
```json
{
  "logs": {"operations": "...", "deletions": "..."},
  "limit": 20,
  "sessions": [ { "command", "run_id", "attribution": "run|command|ambiguous",
                  "started_at", "ended_at", "items": n, "size": "1.2GB",
                  "operation_count": n, "failed_tasks": n,
                  "actions": {"removed","trashed","skipped","failed","rebuilt","other"} } ],
  "deletions": [ { "timestamp", "mode", "status", "size_kb": n|null, "path" } ]
}
```
- 문자열은 수동 JSON 이스케이프, 잘못된 UTF-8 바이트는 `�`로 치환 (core:591-660).

---

## 5. `mo status` / `mo analyze` 셸 래퍼

| 명령 | 동작 | 위치 |
|---|---|---|
| `mo status` | 같은 `bin/` 디렉터리의 `status-go`가 실행 가능하면 `exec "$GO_BIN" "$@"`(인자 그대로 전달). 없으면 stderr `Bundled status binary not found. Please reinstall Mole or run mo update to restore it.` exit 1 | bin/status.sh:8-15 |
| `mo analyze`/`analyse` | 동일 패턴, `analyze-go`, 메시지 `Bundled analyzer binary not found…` | bin/analyze.sh:8-15 |
| 디스패치 | `mole` 메인: `run_mole_command "$SCRIPT_DIR/bin/{analyze,status}.sh" "${args[@]:1}"`; 메뉴 4=analyze, 5=status | mole:267-284, 335-340 |
- 래퍼 자체에는 로직 없음. Go 바이너리 내부(실시간 지표/디스크 트리)는 별도 문서 범위. Swift에서는 네이티브 뷰로 대체되므로 래퍼는 포팅 불필요.

---

## 6. Swift 포팅 노트

### 6.1 작업별 구현 전략

| id | 권한 | Swift 구현 방안 | 앱 컨텍스트 권고 |
|---|---|---|---|
| cache_refresh | 사용자 | `Process("/usr/bin/qlmanage", ["-r","cache"])`, `["-r"]`; 캐시 디렉터리는 `FileManager.trashItem`/`removeItem` | 유지. 샌드박스 불가(타 앱 캐시) → **비샌드박스 배포(Developer ID)** 전제 |
| saved_state_cleanup | 사용자 | `FileManager.enumerator` + `contentModificationDateKey` ≥30일, `.savedState` 디렉터리 | 유지 |
| fix_broken_configs | 사용자 | `PropertyListSerialization.propertyList(from:)` 실패 = 손상(lint 대체). `isReadableFile` false면 유지 | 유지. 삭제 대신 휴지통 이동 권장 |
| network_optimization | **root** | 특권 헬퍼(`SMAppService.daemon`) 내에서 `dscacheutil -flushcache` + `launchctl kill SIGHUP system/<label>`; macOS 27 거부 시 `_mdnsresponder` 계정 재시도 로직 동일하게. Label은 `/System/Library/LaunchDaemons/com.apple.mDNSResponder.plist`에서 `PropertyListSerialization`으로 읽기 | 유지(헬퍼). VPN 검사 선행 필수 |
| VPN 검사 | 사용자 | `SCNetworkConnection`/`NEVPNManager`는 타 앱 VPN 못 봄 → `scutil --nc list` 실행 + 기본 라우트 인터페이스는 `SCDynamicStoreCopyValue("State:/Network/Global/IPv4")`의 `PrimaryInterface` 검사(`utunN`) | 유지 |
| sqlite_vacuum | 사용자(+FDA) | 내장 `SQLite3`(libsqlite3) 직접 사용: `PRAGMA page_count/freelist_count/integrity_check`, `VACUUM`. 실행 확인은 `NSRunningApplication.runningApplications(withBundleIdentifier:)` (`com.apple.mail`, `com.apple.Safari`, `com.apple.MobileSMS`) | 유지, FDA 안내 UI 필요 |
| prevent_network_dsstore | 사용자 | `CFPreferencesSetValue("DSDontWriteNetworkStores", kCFBooleanTrue, "com.apple.desktopservices", kCFPreferencesCurrentUser, kCFPreferencesAnyHost)` + `CFPreferencesSynchronize` (또는 `/usr/bin/defaults`) | 유지. 토글/되돌리기 UI 제공 권장 |
| legacy_overrides_audit | 사용자 | `CFPreferencesCopyAppValue`/`SetAppValue(nil)` (`kCFPreferencesAnyApplication`=`-g`) | 유지 |
| network_stack_optimize | **root** | 헬퍼에서 `route -n flush`, `arp -a -d` | **기본 비활성/고급 옵션 권장** — 연결 단절 위험, 효용 낮음 |
| disk_permissions_repair | **root** | 헬퍼에서 `diskutil resetUserPermissions / <uid>` | 조건 충족 시에만 노출, 명시적 확인 |
| spotlight_index_optimize | 측정=사용자, 재구축=**root** | 측정: `NSMetadataQuery` 또는 `Process("/usr/bin/mdfind")` 시간 측정; 상태: `mdutil -s /`; AC 전원: `IOPSCopyPowerSourcesInfo`/`IOPSGetProvidingPowerSourceType` == `kIOPMACPowerKey`; 재구축: 헬퍼 `mdutil -E /` | 유지, 1-2시간 소요 경고 |
| spotlight_orphan_rules_cleanup | 사용자 | `CFPreferencesCopyAppValue("EnabledPreferenceRules","com.apple.spotlight")` 스냅샷 → 앱 존재: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` + 폴백 스캔 → 쓰기 직전 재읽기 비교 → `CFPreferencesSetAppValue` + Synchronize. **파일 직접 수정 금지** | 유지 |
| periodic_maintenance | **root** | 헬퍼 `periodic daily weekly monthly` | **드롭 권장**: macOS 26+ 미존재, 앱 타깃 OS에서 무의미 |
| shared_file_list_repair | 사용자(+FDA) | `PropertyListSerialization`으로 검사 | 유지(낮은 우선순위) |
| disk_verify | 사용자 | `diskutil verifyVolume /` | **드롭 또는 숨김**: 시스템 프리즈 위험(원본도 기본 off) |
| login_items_audit | 사용자 | macOS 13+ `SMAppService`는 타 앱 항목 조회 불가. AppleScript(System Events) 필요 → `NSAppleScript` + `NSAppleEventsUsageDescription` + Automation 권한. BTM(`sfltool dumpbtm`) 폴백은 root | 보고 전용 유지, BTM 폴백은 드롭 가능. 수정은 시스템 설정으로 딥링크(`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`) |
| quarantine_cleanup | 사용자 | libsqlite3로 `DELETE FROM LSQuarantineEvent; VACUUM;` | 유지, 개인정보 성격 설명 |
| launch_agents_cleanup | 사용자 | `PropertyListSerialization`으로 `Program`/`ProgramArguments[0]`/`Label` 읽기 | 보고 전용 유지; Finder에서 보기 버튼 정도 |
| notification_cleanup | 사용자(+FDA 가능) | libsqlite3 DELETE+VACUUM; 재시작은 `Process("/bin/launchctl", ["kill","SIGTERM","gui/\(getuid())/com.apple.notificationcenterui.agent"])` | 유지. `delivered_date` epoch 기준 확인 후 구현 |
| coreduet_cleanup | 사용자(+FDA 가능) | libsqlite3로 SQL만 수행, **-wal/-shm 절대 직접 삭제 금지**, busy timeout 설정 | 유지(주의) 또는 고급 옵션 |
| 진단: CPU/메모리/폭주 | 사용자 | `proc_listallpids` + `proc_pidinfo(PROC_PIDTASKINFO)`로 CPU 시간/RSS, `sysctl vm.swapusage`(`xsw_usage`), `host_statistics64(HOST_VM_INFO64)`, `kern.boottime` | 유지 — 앱 대시보드와 공유 가능 |
| 진단: DMG detach | 사용자 | `hdiutil info -plist` 파싱(텍스트 대신) → `DADiskUnmount`/`hdiutil detach` | 유지, 확인 다이얼로그 |
| 헬스 라인 | 사용자 | `ProcessInfo.physicalMemory`, `host_statistics64`, `URLResourceValues.volumeTotalCapacity/AvailableCapacity`, `ProcessInfo.systemUptime` | 유지 |

### 6.2 특권 헬퍼(Privileged Helper) 범위

| 필요 작업 | 명령 |
|---|---|
| DNS 플러시 | `dscacheutil -flushcache`, `launchctl kill SIGHUP system/<label>`, (macOS 27) `sudo -u _mdnsresponder killall -u _mdnsresponder -HUP mDNSResponder` → 헬퍼는 root이므로 `posix_spawn` 전 `setuid(_mdnsresponder uid)` 또는 `/usr/bin/sudo -u` 사용 |
| 네트워크 스택 | `route -n flush`, `arp -a -d` |
| 권한 복구 | `diskutil resetUserPermissions / <uid>` |
| Spotlight 재구축 | `mdutil -E /` |
| Touch ID 토글 | `/etc/pam.d/sudo_local`(및 레거시 `/etc/pam.d/sudo`) 쓰기 |
| (선택) periodic, BTM 덤프 | 드롭 권장 |

- 구현: `SMAppService.daemon(plistName:)`(macOS 13+) + XPC(`NSXPCConnection`), 클라이언트 코드서명 요구사항 검증(`setCodeSigningRequirement`). 헬퍼는 **고정된 명령 enum만** 수락(임의 경로/인자 금지).
- 대안: 헬퍼 없이 `AuthorizationExecuteWithPrivileges`(deprecated) 또는 `osascript "do shell script … with administrator privileges"` — 매번 비밀번호 프롬프트, 권장하지 않음.
- 원본의 "sudo 1회 획득 후 실패 시 sudo 작업 전부 skipped" 정책은 앱에서 "헬퍼 미설치/승인 거부 → 해당 작업 skipped(관리자 권한 필요)"로 매핑.

### 6.3 Touch ID 포팅

- `/etc/pam.d/sudo_local` 쓰기는 root 필요 → 헬퍼. 원자적 쓰기: 임시 파일 작성 → `chown root:wheel`, `chmod 0444` → `rename(2)`.
- 활성 판정은 사용자 권한으로 가능(파일 world-readable): 정규식 `^[^#]*pam_tid\.so`.
- 지원 판정은 `LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` + `biometryType == .touchID`로 대체(원본의 연도 휴리스틱 버림).
- `/etc/pam.d/sudo`에 `sudo_local` include가 없으면(Sonoma 이전) 레거시 경로 — 앱 최소 타깃이 macOS 14+면 **레거시 경로 드롭** 가능. 단 기존 레거시 줄 정리(migrate)는 유지 권장.
- disable 시 원본처럼 `pam_tid.so` 포함 모든 줄 삭제 대신, 활성 줄만 제거하는 것을 고려(주석 템플릿 보존). 동작 차이는 문서화.
- macOS 업데이트가 `/etc/pam.d/sudo`를 덮어써도 `sudo_local`은 보존된다는 점이 sudo_local 사용 이유.

### 6.4 드롭/변경 대상 (앱 컨텍스트)

| 항목 | 처리 |
|---|---|
| `bc` 의존성 체크, `LC_ALL=C` | 불필요 (Swift 수치 연산, 로케일 독립 `FormatStyle`) |
| TTY 스피너/키 입력(`read_key`, Enter/Space) | SwiftUI 진행 표시·확인 다이얼로그로 대체 |
| `--debug`의 debug_operation_* 출력 | 작업별 "자세히" 패널(Method/Expected outcome/Risk level)로 전환 — 원본 문자열 재사용 가능 |
| 테스트 시임(`MOLE_OPTIMIZE_PS_SAMPLE_*` 등 env) | 프로토콜 기반 의존성 주입으로 대체 |
| `periodic_maintenance`, `disk_verify` | 드롭(또는 숨김) |
| `network_stack_optimize` | 기본 off |
| LaunchServices 재구축 | 절대 추가 금지 |
| `mo status`/`mo analyze` 래퍼 | 불필요(네이티브 뷰) |
| history 텍스트 렌더 | 리스트 UI. JSON 스키마는 내보내기 포맷으로 재사용 가능 |

### 6.5 Gotchas

1. **화이트리스트 키 = action id** (`cache_refresh` 등) — 사용자 설정 마이그레이션 시 `system_maintenance` → `network_optimization` 레거시 매핑 유지 (tasks.sh:2118).
2. **Outcome 정확히 1개/작업** 불변식 유지 → Swift `enum OptimizeOutcome` + 작업이 반드시 값을 반환하는 `async func run() -> OptimizeOutcome` 시그니처로 강제.
3. 부분 실패는 failed (counts 규칙). UI 배지 계산 동일하게.
4. 시간 예산 초과는 대체로 **unavailable**(login items) 또는 partial→failed(prefs). 작업별 차이 그대로 옮길 것.
5. dry-run에서도 측정(Spotlight 프로브, VPN, sqlite PRAGMA)은 실행; 변경·신호만 생략. 앱의 "미리보기" 모드도 동일 의미로.
6. FDA(Full Disk Access) 없으면 Mail/Messages/Safari DB, sharedfilelist, 알림 DB 접근 실패 → `unavailable`로 분류하고 FDA 안내(원본은 sharedfilelist만 권한 오류를 unavailable로 구분).
7. 파일 삭제는 원본 `safe_remove`의 보호 경로 규칙(타 문서) 준수. `com.apple.*` plist는 절대 삭제 안 함.
8. 서드파티 plist에서 읽은 문자열(Label, Program)은 UI 표시 시 제어문자 제거.
9. `cfprefsd` 캐시 때문에 `~/Library/Preferences/*.plist` 직접 편집 금지 — 항상 CFPreferences API.
10. sqlite 작업은 대상 앱/데몬과 잠금 경합: `sqlite3_busy_timeout` 설정, 실패 시 "busy or locked" → failed.
11. 알림 DB 정리 후 서비스 재시작은 `launchctl kill … gui/<uid>/com.apple.notificationcenterui.agent`만(실패 무시).
12. macOS 버전 분기: mDNSResponder Label(`.reloaded` on 26), macOS 27 launchctl 거부, `periodic` 26+ 없음, 알림 DB 경로 15+ 그룹 컨테이너.
13. 실행 전체가 root로 돌면 안 됨(원본 EUID 거부) — 앱 본체는 사용자 권한, root 작업만 헬퍼.
