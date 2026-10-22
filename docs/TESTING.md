# FileFan 검증

## 자동 테스트

```sh
zsh scripts/test.sh
```

파일 추가·중복·누락 처리, 원본 보존, 이미지·텍스트 도구, 제스처 상태, 도킹 좌표, 세션 저장, 변환 목록 정렬, 옵션 검사와 backend 프로세스·JSON 오류를 시험합니다.

실제 변환 엔진과 macOS pasteboard가 필요한 시험은 실행 조건이 다릅니다. 기본 실행은 외부 실행 조건이 필요한 시험을 명시적으로 생략합니다. 기본 실행의 통과를 전체 엔진이나 전역 드래그의 실제 동작 검증으로 해석하지 않습니다.

backend를 포함한 앱을 준비한 후 통합 시험을 활성화할 수 있습니다.

```sh
FILEFAN_BACKEND_EXECUTABLE="$PWD/dist/FileFan.app/Contents/Resources/Backend/filee-cli" zsh scripts/test.sh
```

미디어 통합시험은 앱의 `Backend/engines/ffmpeg`에 있는 `ffmpeg`·`ffprobe`를 사용합니다. 앨범 표지 시험에는 `artifacts/evidence/backend-fixtures/inputs/audio.wav`와 `image.png`도 필요합니다. 입력을 준비한 후 명시적으로 활성화합니다. 활성화한 시험에서 입력이 없으면 실패로 보고합니다.

```sh
FILEFAN_MEDIA_TESTS=1 zsh scripts/test.sh
```

pasteboard 시험은 실제 macOS 세션에서 파일 참조를 써 보므로 해당 조건을 준비한 뒤 실행합니다.

```sh
FILEFAN_LIVE_PASTEBOARD_TESTS=1 zsh scripts/test.sh
```

## backend 검증 도구

| 스크립트 | 범위 |
|---|---|
| `backend-verify.py` | 형식군별 fixture 변환과 결과 검사 |
| `backend-verify-presets.py` | 변환 preset과 특수 작업 |
| `backend-verify-compression.py` | PDF 압축 결과 |
| `backend-verify-integrity.py` | 패키징 manifest와 파일 무결성 |
| `backend-relocation-smoke.py` | 앱 경로를 옮긴 후 실행 |

이 도구들은 준비된 전체 앱과 별도의 `artifacts` 입력을 전제로 합니다. fixture·변환 결과·개인 파일·과거 실행 로그는 저장소에 포함하지 않습니다. 카탈로그 항목 수, 현재 engine graph 경로 수와 실제 fixture 실행 수를 구분합니다.

## 실제 macOS 상호작용

앱 번들을 실행해 다음 동작을 별도로 확인합니다.

- Finder에서 파일을 드래그하며 Shift·Command·Control 휠을 열고 각 구역에 직접 드롭
- 키 해제 후 휠 유지, Escape·드래그 종료 시 취소, 다른 앱의 포커스 유지
- 선반 도킹·해제·핸들 열기, 다중 모니터 이동과 화면 연결 변경
- 정상 종료·강제 종료 후 항목·선택·위치·옵션 복원
- 변환 버튼·검색·비활성 이유·접근성 이름, 실제 출력 폴더 선택과 변환

자동 테스트와 빌드 결과만으로 위 항목의 실제 OS 검증을 대신하지 않습니다. 이번 공개 소스 정리에서는 GUI 상호작용을 새로 시험하지 않습니다.

Core Image가 필요한 이미지 편집 시험은 macOS 렌더링 접근이 제한된 샌드박스에서 실패할 수 있습니다. 해당 경우 같은 시험을 렌더링 접근이 가능한 로컬 환경에서 실행해 환경 제한과 코드 오류를 구분합니다.
