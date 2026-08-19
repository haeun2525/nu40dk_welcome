# 작업 규칙

Welcome은 **한 세션이 펌웨어·맥 데몬·아이폰 앱을 모두** 맡는다.
다만 **NU40DK 보드는 한 대뿐이고 다른 프로젝트들과 공유한다.**

## 보드는 한 번에 한 프로젝트만

이 펌웨어를 구우면 `nu40dk_launcher`, `nu40dk_together`, `nu40dk_music_led`,
`nu40dk_metronome`이 **전부 멈춘다.** 보드를 굽기 전에 사용자에게 먼저 알린다.

지금 뭐가 올라가 있는지는 시리얼을 몇 초 읽으면 바로 안다.

| 출력 | 펌웨어 |
|---|---|
| `[welcome]` | 이 프로젝트 |
| `BTN1`~`BTN4` | 런처 |
| `[together]` | Together |
| 아무것도 안 나옴 | 다른 펌웨어이거나 부트로더 (`ls /Volumes/`에 `NRF52BOOT`) |

## 동시에 하나만 되는 자원 둘

**시리얼 포트** — 업로드 전에 `lsof /dev/cu.usbmodem11101`로 확인한다.
잡혀 있으면 누구 것인지 먼저 본다. 사용자의 다른 프로그램일 수 있고, 그건 임의로 죽이면 안 된다.

**BLE 연결 (동시에 1개)** — 보드는 페리페럴이라 센트럴 하나만 붙는다.
맥에서 붙어 있으면 아이폰이 못 붙고, 반대도 마찬가지다.
"앱이 보드를 못 찾는다"의 첫 번째 용의자다.
(`beacon_check.py`는 스캔만 하고 연결하지 않으므로 앱과 같이 써도 된다.)

## 두 군데에 같이 있는 값 (한쪽만 고치면 조용히 깨진다)

| 값 | 펌웨어 | 앱 |
|---|---|---|
| iBeacon UUID | `BEACON_UUID` | `BoardIDs.beaconUUID` |
| major / minor | `BEACON_MAJOR` `BEACON_MINOR` | `BoardIDs.beaconMajor` `beaconMinor` |
| 서비스/캐릭터리스틱 UUID | 파일 상단 `UUID_*` | `BoardIDs.service` `status` `command` |
| 명령 값 0x00~0x03 | `enum Cmd` | `BoardIDs.Command` |
| 상태 값 0~2 | `enum State` | `BoardIDs.BoardState` |
| 환영 연출 길이 | `WELCOME_MS` | `ArrivalManager.celebrationSeconds` |
| status 페이로드 4바이트 | `loop()`의 `payload[4]` | `didUpdateValueFor` |

**비콘 UUID가 어긋나면 앱은 리전에 영영 못 들어간다.** 에러도 로그도 없이
"아무 일도 안 일어남"이 증상이라 원인 찾는 데 오래 걸린다.

## 검증 명령

```bash
# 보드가 iBeacon 광고 중인지 (연결하지 않으므로 앱 테스트 중에도 안전)
cd host && ~/Documents/Arduino/nu40dk_together/host/.venv/bin/python beacon_check.py

# 펌웨어 컴파일
CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
"$CLI" compile --fqbn nucode:nrf52:nu40dk .

# 아이폰 앱 빌드 (실기기·서명 없이)
cd ios && xcodebuild -project NU40DKWelcome.xcodeproj -scheme NU40DKWelcome \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

**빌드 로그를 `tail`로 파이프하지 말 것.** 에러는 앞쪽에 나오는데 잘려서 안 보인다.
파일로 받은 뒤 `grep -E "error:|warning:"` 한다.

**Swift 경고를 무시하지 말 것.** 델리게이트 메서드는 이름이 조금만 달라도
"nearly matches optional requirement" 경고만 뜨고 **조용히 안 불린다.**
이 프로젝트에서 실제로 한 번 밟았다 (`didRangeBeacons` → `didRange`).

기술적 함정과 설계 배경은 `README.md`에 있다. 먼저 읽을 것.
