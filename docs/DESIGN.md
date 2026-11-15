# 맥클린(MacClean) 설계안

Mole CLI(macOS, GPL-3.0, 분석 기준 커밋 `9a73b55`, 2026-11-09)를 Swift/SwiftUI 네이티브 앱으로 새로 구현하기 위한 설계 문서입니다.
명령별 상세 스펙은 `docs/analysis/`에 있습니다.

| 문서 | 범위 |
|---|---|
| [01-clean.md](analysis/01-clean.md) | `mo clean` 흐름, 정리 대상 카탈로그(15개 섹션), clean 전용 가드 |
| [02-core-safety.md](analysis/02-core-safety.md) | 삭제 깔때기, 보호 목록, 화이트리스트, 권한 모델, 기록, 라우터 |
| [03-uninstall-purge-installer-slim.md](analysis/03-uninstall-purge-installer-slim.md) | 앱 삭제와 잔여물, 프로젝트 산출물, 설치 파일, Intel 슬라이스 제거 |
| [04-optimize-touchid.md](analysis/04-optimize-touchid.md) | 최적화 작업 19개, 진단, Touch ID PAM |
| [05-analyze-status.md](analysis/05-analyze-status.md) | 디스크 분석기, 시스템 모니터, health score |

## 1. 원칙

1. **라이선스**: GPL-3.0으로 소스를 공개하고 README에 Mole 출처(tw93/Mole)를 밝힌다. "Mole" 이름과 로고는 쓰지 않는다(`TRADEMARK.md`).
2. **안전 우선**: Mole의 불변식(02 문서 §7.3)을 그대로 지킨다. 모든 삭제는 `SafeDeleter` 하나를 거치고, 판단할 수 없으면 거부하며, 휴지통 이동이 실패해도 영구 삭제로 넘어가지 않는다.
3. **미리보기 후 실행**: 모든 파괴적 기능은 스캔(= dry-run)으로 대상 목록을 먼저 보여주고, 사용자가 선택한 뒤 실행한다. 스캔과 실행은 같은 검증 경로를 탄다.
4. **셸 호출 최소화**: Apple API로 가능한 것은 API로 한다(05 §C1, 02 §7.2). 공개 API가 없는 것만 `Process`로 호출하고 timeout을 둔다.
5. **앱은 root로 실행하지 않는다**: 관리자 작업은 고정된 enum 명령만 받는 특권 헬퍼가 처리하고, 헬퍼가 경로를 다시 검증한다.

## 2. 배포 제약

| 항목 | 결정 |
|---|---|
| 샌드박스 | 사용 불가(다른 앱의 Library 접근 필요) → **Mac App Store 불가** |
| 배포 | Developer ID 서명 + 공증(notarization), DMG 또는 Homebrew cask |
| 권한 | Full Disk Access 안내 화면(접근 시도로 감지), App Management(TCC)는 앱 번들 휴지통 이동 시 |
| 최소 macOS | macOS 14 Sonoma 제안(SwiftUI Observation, `SMAppService` 13+) |
| 특권 헬퍼 | `SMAppService.daemon` + `NSXPCConnection`, 클라이언트 코드서명 요구사항 검증 |

## 3. 구조

```
MacClean.xcodeproj
├─ MacClean (App, SwiftUI)          화면, 뷰모델. Core만 의존
├─ MacCleanCore (Swift Package)      로직 전부. 단위 테스트 대상
│   ├─ Safety/      PathPolicy, ProtectionPolicy, Whitelist, SafeDeleter(actor), FileIdentity
│   ├─ System/      ProcessProbe, ShellRunner(timeout), SizeCalculator, FullDiskAccess
│   ├─ Log/         OperationLog, HistoryStore
│   ├─ Clean/       CleanCatalog(규칙 데이터), CleanScanner, CleanExecutor
│   ├─ Uninstall/   AppInventory, LeftoverFinder, UninstallExecutor
│   ├─ Purge/       ArtifactScanner
│   ├─ Installer/   InstallerScanner
│   ├─ Slim/        FatBinary, SlimExecutor
│   ├─ Optimize/    OptimizeTask enum, Diagnostics, Outcome
│   ├─ Analyze/     DiskScanner(병렬, clone/hardlink dedupe), ScanCache
│   └─ Status/      CPU, Memory, Disk, Network, Battery, GPU, HealthScore
├─ MacCleanHelper (launchd daemon)   XPC 서버. 허용 목록에 있는 작업만 실행
└─ Shared/                           XPC 프로토콜, 명령 enum
```

- 정리 규칙(경로, 조건, 권한 필요 여부)은 코드에 흩지 않고 `CleanCatalog`에 **데이터로** 모은다. 01 문서의 카탈로그 표를 그대로 옮기는 형태다.
- 설정과 기록은 `~/Library/Application Support/MacClean/`, 로그는 `~/Library/Logs/MacClean/`에 둔다. Mole 화이트리스트(`~/.config/mole/whitelist`)는 읽기 전용으로 가져오기 옵션만 제공한다.

## 4. 화면

| 화면 | 대응 명령 | 비고 |
|---|---|---|
| 대시보드 | `status` | 1초 갱신, health score, 메뉴바 항목 |
| 정리 | `clean` | 섹션별 체크리스트, 예상 확보 용량 |
| 앱 삭제 | `uninstall` | 앱 목록 → 잔여물 검토 → 휴지통 |
| 디스크 분석 | `analyze` | 트리맵 또는 목록, 휴지통 이동 |
| 개발 산출물 | `purge` | 프로젝트별 그룹 |
| 설치 파일 | `installer` | |
| 최적화 | `optimize` | 작업별 결과 6종 표시 |
| 기록 | `history` | |
| 설정 | whitelist, Touch ID, 헬퍼 설치, FDA 안내 | Touch ID PAM 편집은 선택 기능 |

`slim`은 앱 번들을 교체하는 위험한 작업이라 후순위로 둔다.

## 5. 단계별 계획

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| M0 | Xcode 프로젝트, Core 패키지, 테스트 타깃 골격 | `swift test`, 빌드 통과 |
| M1 | Safety 계층(PathPolicy, ProtectionPolicy, Whitelist, SafeDeleter, OperationLog) | Mole deny list와 보호 목록 기준 단위 테스트 통과 |
| M2 | 대시보드(status) | Mole `status --json`과 지표 비교 |
| M3 | 정리(clean) 사용자 영역만(헬퍼 없이) | 스캔 결과가 `mo clean --dry-run` 목록과 일치 |
| M4 | 디스크 분석(analyze) | 홈 폴더 스캔 크기가 `mo analyze --json`과 오차 범위 내 |
| M5 | 앱 삭제, purge, installer | 각 명령의 `--dry-run`/`--list` 결과와 비교 |
| M6 | 특권 헬퍼 + 시스템 영역 clean + optimize | 헬퍼가 허용 목록 외 요청을 거부하는 테스트 |
| M7 | slim, Touch ID, 서명·공증, 배포 | |

Mole CLI를 같은 Mac에 설치해 두고, 각 단계에서 **Mole의 dry-run/JSON 출력과 맥클린 스캔 결과를 비교**하는 것을 검증 방법으로 쓴다.

## 6. 정해야 할 것

1. 첫 버전(MVP) 범위: M0~M3(대시보드 + 사용자 영역 정리)을 제안.
2. 최소 macOS 버전: 14 제안.
3. clean 삭제 방식: Mole은 캐시를 영구 삭제(`rm -rf`)한다. 맥클린도 동일하게 할지, 휴지통 이동을 기본으로 할지.
4. Apple Developer 계정 유무: 특권 헬퍼(M6)와 공증 배포(M7)에 필요.

## 7. 분석 문서의 미확인 사항

- 04: 알림 정리의 `delivered_date`가 Unix epoch인지 Mac epoch(2001)인지 실제 DB로 확인.
- 05: `proc_pidinfo`로 다른 사용자 프로세스를 읽을 수 있는지, gopsutil 내부 동작(“추정” 표시 항목).
- 03: 앱 삭제 후 `killall Dock` 호출 여부, slim의 서명 오류 분기.
- 02, 03: file:line 인용은 일부만 재확인했고 ±수 줄 오차가 있을 수 있음. 구현 시 원문을 다시 연다.
