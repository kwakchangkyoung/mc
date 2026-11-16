# 맥클린 (MacClean)

macOS용 네이티브 정리·시스템 모니터 앱입니다. [Mole](https://github.com/tw93/Mole) CLI(GPL-3.0)의
정리 규칙과 안전 장치를 Swift/SwiftUI로 옮겼습니다. Mole 프로젝트와는 관련이 없습니다.

## 현재 범위 (M0–M5 일부)

- **대시보드**: CPU, 메모리, 디스크, 디스크 I/O, 네트워크, GPU, 배터리, 상위 프로세스, 건강 점수(Mole 공식)
- **정리**: 사용자 영역 캐시·로그·개발 도구 캐시 스캔 후 선택 삭제. 관리자 권한이 필요한 시스템 영역과
  도구 자체 명령(`npm cache clean` 등)은 아직 없습니다.
- **디스크 분석**: 폴더별 크기(하드링크 중복 제외, 심볼릭 링크 미추적), 하위 폴더 탐색, 휴지통 이동
- **앱 삭제**: 앱 목록 → 잔여물 검토 → 휴지통 이동. 실행 중인 앱과 전용 삭제 프로그램이 필요한 앱은 거부하고,
  `/Library`의 시스템 영역 잔여물은 표시만 합니다.
- **최적화**: Mole 작업 19개 중 관리자 권한이 필요 없는 작업만 실행합니다. 관리자 작업은 특권 헬퍼(M6) 전까지 미지원입니다.
  purge, installer, slim은 아직 없습니다.
- **안전 장치**: 모든 삭제는 `SafeDeleter` 하나를 거칩니다. 시스템 경로 차단, 보호 앱 데이터, 화이트리스트,
  실행 중인 앱의 캐시 보류, 삭제 직전 재검사(dev:inode)를 Mole과 같은 규칙으로 적용합니다.
  캐시는 Mole처럼 휴지통을 거치지 않고 영구 삭제합니다.

설계와 Mole 분석 문서는 [docs/DESIGN.md](docs/DESIGN.md)와 [docs/analysis/](docs/analysis/)에 있습니다.

## 빌드와 실행

```bash
swift test
./scripts/build-app.sh
open build/MacClean.app
```

헤드리스 비교 모드(삭제 없음): `.build/debug/MacClean --status`, `--clean-dry-run`, `--analyze <경로>`,
`--uninstall-dry-run <앱 이름 또는 번들 ID>`, `--optimize-dry-run`

정리 대상 전체를 보려면 앱에 전체 디스크 접근 권한을 주어야 합니다.

## 라이선스

GPL-3.0. 보호 목록 데이터(`Sources/MacCleanCore/Safety/ProtectionData.swift`)는 Mole의
`lib/core/app_protection_data.sh`에서 `scripts/extract_protection.py`로 생성했습니다.
