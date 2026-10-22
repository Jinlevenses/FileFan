# FileFan 빌드

## Swift 소스와 테스트

macOS에서 Swift 도구 체인과 Command Line Tools 또는 Xcode를 준비합니다. 시험 스크립트는 Swift Testing 프레임워크를 찾으므로 Swift Testing을 제공하는 도구 체인이 필요합니다.

```sh
zsh scripts/test.sh
swift build -c release --product FileFan
```

위 명령은 Swift 소스를 검증하고 실행 파일을 빌드합니다. 메뉴 막대에서 실행하는 완성된 `.app`은 아래의 패키징 단계로 만듭니다.

## 전체 앱에 필요한 별도 입력

`scripts/build-app.sh`의 전체 빌드는 아래 경로를 사용합니다. 이 저장소는 실행 의존성의 바이너리·엔진·SDK를 포함하지 않습니다. backend 버전이나 디렉터리 이름을 바꾸면 패키징 스크립트와 capability bridge의 계약도 함께 검토해야 합니다.

| 입력 | 필요한 경로 |
|---|---|
| .NET 10 SDK 실행 파일 | `artifacts/toolchains/dotnet/dotnet` |
| backend 1.12.0 공식 아카이브 | `artifacts/downloads/Filee-1.12.0-osx-arm64.tar.gz` |
| 아카이브에서 추출한 backend | `artifacts/runtime/Filee/Filee-1.12.0-osx-arm64/Filee.app/Contents/MacOS/` |
| 선택 변환 엔진 | `artifacts/runtime/optional-engines/<engine>/` |

고정 아카이브의 SHA-256은 다음과 같습니다. 패키징 스크립트에서도 이 값을 검사합니다.

```text
7ab779a73a81d36f6867eee10d81b8bd2375d14800673ce31c17aa8c7326e096
```

backend의 공식 프로젝트와 구성요소별 배포 정보는 [의존성 고지](../Resources/BackendLicenses/Filee-THIRD-PARTY-NOTICES.md)에 있습니다. 선택 엔진은 각각의 공식 배포본과 허가문을 준비합니다. `scripts/backend-stage-engines.py`와 `scripts/backend-portable-engine.py`는 로컬에서 준비한 엔진 입력을 다루는 보조 도구이며 모든 입력을 자동으로 내려받는 설치기는 아닙니다.

## 패키징과 서명

```sh
zsh scripts/build-app.sh
plutil -lint dist/FileFan.app/Contents/Info.plist
codesign --verify --deep --strict dist/FileFan.app
open dist/FileFan.app
```

스크립트는 release 앱·리소스·아이콘·capability bridge·backend·허가문을 묶고 로컬 ad-hoc 서명을 적용합니다. 산출물은 `dist/FileFan.app`입니다. 현재 전체 backend 입력은 Apple Silicon용이며 다른 아키텍처는 별도 검증이 필요합니다. Swift 앱의 최소 빌드 대상은 macOS 13, .NET 10 backend의 지원 대상은 macOS 14 이상입니다.

`--native-only`는 **이미 backend가 들어 있는 `dist/FileFan.app`**의 Swift 실행 파일과 리소스만 갱신할 때 사용합니다. 새 checkout에서 backend 없이 앱 번들을 만드는 옵션은 아닙니다.

```sh
zsh scripts/build-app.sh --native-only
```

이미 실행 중인 앱이 있으면 메뉴 막대의 **Quit FileFan**으로 종료한 뒤 새 번들을 엽니다. Developer ID 서명·공증과 엔진을 포함한 바이너리 배포는 별도의 배포 절차입니다.
