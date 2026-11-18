# 맥클린 (MacClean) 릴리즈 가이드

이 문서는 맥클린(MacClean)의 새 버전을 빌드하고 GitHub Releases에 배포하는 방법을 정리한 가이드입니다.

---

## 1. 사전 준비 및 버전 규칙

맥클린의 앱 내 자동 업데이트기(`ReleaseUpdater`)가 새 릴리즈를 정상적으로 감지하고 설치하려면 다음 규칙을 지켜야 합니다.

1. **시맨틱 버전 태그 (`vX.Y.Z`)**
   - Git 태그와 릴리즈 버전은 반드시 `v0.2.4`, `v0.3.0`, `v1.0.0`과 같은 `v<Major>.<Minor>.<Patch>` 형식을 사용합니다.
   - 앱은 실행 중인 번들의 `CFBundleShortVersionString`(`Info.plist`)보다 GitHub의 최신 Release 태그 버전이 더 높을 때만 업데이트 알림을 띄웁니다.
2. **필수 첨부 파일 3종**
   - `./scripts/package-release.sh <버전>` 실행 시 `build/release/` 폴더에 생성되는 아래 3개 파일을 릴리즈에 첨부합니다:
     - `MacClean-v<버전>-macos.dmg` (신규 설치자용 디스크 이미지)
     - `MacClean-v<버전>-macos.zip` (자동 업데이트 및 압축 해제용 패키지)
     - `SHA256SUMS.txt` (자동 업데이트 시 파일 변조 검증용 SHA-256 체크섬)

---

## 2. 릴리즈 방법 (3가지 중 선택)

### 방법 A: Git 태그 푸시로 자동 릴리즈 (GitHub Actions 권장)

로컬 Mac에서 직접 패키징하지 않아도, `v*` 태그를 원격 저장소에 푸시하면 GitHub Actions([`.github/workflows/release.yml`](../.github/workflows/release.yml))가 자동으로 테스트(`swift test`) → 유니버설 바이너리 빌드 → `.dmg` / `.zip` / `SHA256SUMS.txt` 생성 → GitHub Release 게시까지 수행합니다.

```bash
# 1. 변경 사항 커밋 및 master 브랜치 푸시
git add -A
git commit -m "작업 내용 요약"
git push origin master

# 2. 새 버전 태그 생성 및 원격 푸시
git tag v0.2.4
git push origin v0.2.4
```

- 푸시 후 GitHub 저장소의 **Actions** 탭에서 빌드 진행 상황을 확인할 수 있습니다.
- 또한 GitHub 웹페이지의 **Actions → Release → Run workflow** 버튼에서 버전 번호를 직접 입력해 수동으로 워크플로를 실행할 수도 있습니다.

---

### 방법 B: 로컬에서 직접 빌드 후 GitHub CLI(`gh`)로 즉시 배포

GitHub Actions 대기 시간 없이 로컬 Mac에서 바로 유니버설 앱을 빌드하고 배포하는 방식입니다.

#### 1단계: 단위 테스트 및 릴리즈 패키지 생성

```bash
# 전체 단위 테스트 실행
swift test

# 릴리즈 패키지 빌드 (버전 번호를 인자로 전달)
./scripts/package-release.sh 0.2.4
```

위 스크립트가 수행하는 작업:
- `arm64`(Apple Silicon) + `x86_64`(Intel) 유니버설 바이너리로 `MacClean` Release 빌드
- `build/MacClean.app/Contents/Info.plist`의 `CFBundleShortVersionString`에 `0.2.4` 자동 주입 및 Ad-hoc 코드 서명
- `build/release/` 디렉터리에 아래 3개 파일 생성:
  - `build/release/MacClean-v0.2.4-macos.dmg`
  - `build/release/MacClean-v0.2.4-macos.zip`
  - `build/release/SHA256SUMS.txt`

#### 2단계: 커밋 및 태그 푸시

```bash
git add -A
git commit -m "Bump version to v0.2.4"
git push origin master

git tag v0.2.4
git push origin v0.2.4
```

#### 3단계: `gh release create`로 릴리즈 발행

- **커밋 로그 기반 자동 릴리즈 노트 생성 시**:
  ```bash
  gh release create v0.2.4 \
    build/release/MacClean-v0.2.4-macos.dmg \
    build/release/MacClean-v0.2.4-macos.zip \
    build/release/SHA256SUMS.txt \
    --title "MacClean v0.2.4" \
    --generate-notes
  ```

- **직접 작성한 릴리즈 노트를 넣을 때**:
  ```bash
  gh release create v0.2.4 \
    build/release/MacClean-v0.2.4-macos.dmg \
    build/release/MacClean-v0.2.4-macos.zip \
    build/release/SHA256SUMS.txt \
    --title "MacClean v0.2.4 — 주요 변경 요약" \
    --notes "## 주요 변경 사항
  - 신규 기능 및 개선 내용 1
  - 버그 수정 내용 2"
  ```

---

### 방법 C: 로컬에서 빌드 후 GitHub 웹 UI에서 직접 업로드

터미널에서 패키지만 만들고 GitHub 웹사이트에서 직접 릴리즈 노트를 작성하며 업로드하는 방법입니다.

1. 터미널에서 패키징 스크립트를 실행하고 생성된 폴더를 Finder로 엽니다:
   ```bash
   ./scripts/package-release.sh 0.2.4
   open build/release
   ```
2. 브라우저에서 [GitHub 새 릴리즈 작성 페이지](https://github.com/kwakchangkyoung/mc/releases/new)를 엽니다.
3. **Choose a tag** 드롭다운에 `v0.2.4`를 입력하고 **Create new tag: v0.2.4 on publish**를 선택합니다.
4. **Release title**과 본문 설명을 작성합니다.
5. 하단 **Attach binaries by dropping them here** 영역에 Finder의 `build/release/` 안에 있는 파일 3개(`.dmg`, `.zip`, `SHA256SUMS.txt`)를 드래그 앤 드롭합니다.
6. **Publish release** 버튼을 클릭합니다.

---

## 3. 자주 쓰는 관리 명령어 (수정 및 재배포)

### 이미 올린 릴리즈의 첨부 파일을 다시 빌드해서 교체하고 싶을 때

```bash
./scripts/package-release.sh 0.2.4
gh release upload v0.2.4 \
  build/release/MacClean-v0.2.4-macos.dmg \
  build/release/MacClean-v0.2.4-macos.zip \
  build/release/SHA256SUMS.txt \
  --clobber
```

### 잘못 만든 릴리즈와 태그를 삭제하고 다시 올리고 싶을 때

```bash
# 1. GitHub Release 삭제
gh release delete v0.2.4 --yes

# 2. 로컬 및 원격 Git 태그 삭제
git tag -d v0.2.4
git push origin :refs/tags/v0.2.4
```
