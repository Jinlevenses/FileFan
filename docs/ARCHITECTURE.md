# FileFan 아키텍처

## 구성

| 경로 | 역할 |
|---|---|
| `Sources/FileFan` | AppKit/SwiftUI 앱, 메뉴 막대, 선반, 드래그 휠, 도구 옵션 |
| `Sources/FileFanCore` | 파일 모델, 제스처 상태, 도킹 좌표, 세션 저장, 변환·도구 실행 |
| `Sources/FileFanCore/Resources/formats.json` | 형식 카탈로그와 확장자 정보 |
| `Tests` | core 모델과 앱 동작 시험 |
| `Resources` | 앱 메타데이터, 아이콘 생성기, 의존성 허가문 |
| `scripts` | 빌드, backend 패키징, capability 조회, 변환 검증 |

## 입력과 화면

`GlobalGestureController`는 파일 드래그와 modifier 입력을 감지하고 순수 `GestureState` 모델로 휠의 전이를 판단합니다. `DragWheelView`의 구역은 실제 파일 URL 드롭을 받습니다. `AppModel`이 선반의 선택·도구·변환 상태를 연결하고 `ShelfDockController`는 화면 가장자리 도킹과 핸들을 관리합니다.

`ConversionPresentation`은 입력 종류를 우선해 형식을 묶고 정렬합니다. `ConversionBackend`가 제공한 공통 가용성을 화면에서 유지하며 형식 카탈로그에 있다는 이유만으로 변환을 활성화하지 않습니다.

## 변환과 도구

PNG/JPEG 변환에는 ImageIO를 사용합니다. 다른 형식은 별도 CLI 프로세스로 실행하고 capability bridge로 현재 엔진과 입력별 경로를 조회합니다. CLI가 없는 경우 해당 변환을 비활성화하며 이유를 표시합니다.

backend는 `Filee.Cli` 1.12.0과 `Filee.Core`·`Filee.Engines` DLL을 사용하는 실행 의존성입니다. capability bridge는 `scripts/backend-capabilities`에서 빌드합니다. 프로세스 인수는 배열로 전달하며 `FILEE_DATA_DIR`로 작업 데이터를 격리합니다. 엔진 버전·아카이브 해시·파일 목록은 패키징 manifest에 기록합니다. 의존성의 허가문과 고지는 `Resources/BackendLicenses`에 보존합니다.

변환 결과는 임시 디렉터리에서 검사한 뒤 출력 폴더에 충돌 없이 게시합니다. 프로세스 종료 코드와 JSON의 파일별 성공·실패를 함께 확인합니다. timeout·취소·잘못된 결과·부분 실패를 구분하고 원본 파일을 덮어쓰지 않습니다.

`NativeImageTools`, `NativeTextTools`, `MediaTools`, `LocalFileTools`는 파일 종류별 도구를 담당합니다. 명시적인 Move를 제외하면 새 출력이나 참조를 만들며 선반 제거는 디스크 파일 삭제로 연결하지 않습니다.

## 저장과 검증

`SessionState`는 항목·선택·창 위치·도킹·옵션을 versioned JSON으로 원자적으로 저장합니다. 손상 상태와 미래 schema를 처리하고 누락 파일을 별도로 알립니다. 기본 경로는 `~/Library/Application Support/FileFan/session.json`이며 `FILEFAN_DATA_DIR`로 시험 상태를 분리합니다.

순수 모델, 프로세스 오류 경계, 실제 backend 변환, 실제 macOS 상호작용은 서로 다른 검증 범위입니다. 자세한 실행 방법은 [TESTING.md](TESTING.md)를 따릅니다.
