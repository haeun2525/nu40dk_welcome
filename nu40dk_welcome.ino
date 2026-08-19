/*
 * NU40DK Welcome — 출근하면 맞이해주는 보드
 *
 * 보드는 회사 책상 위에 USB-C 전원으로 상시 켜져 있다. 사람이 폰을 들고 출근하면
 * 폰이 먼저 알아채고(비콘), 보드가 반짝이고, 맥이 깨어난다.
 *
 * 이 펌웨어가 하는 일은 두 가지다.
 *   1. iBeacon으로 상시 광고한다. **이게 이 프로젝트의 핵심이다.**
 *      아이폰은 앱이 완전히 종료돼 있어도 비콘 리전에 들어가면 OS가 앱을 깨워준다.
 *      일반 BLE 광고로는 안 된다 — 앱이 죽으면 스캔할 주체가 없다.
 *   2. 폰이 도착을 알려오면(또는 버튼1) 환영 연출을 하고, 시리얼로 맥에 알린다.
 *
 * 판정은 폰이 한다. 보드는 "왔다"는 통보를 받고 연출만 한다.
 * 거리 판정을 보드에 두면 촬영장에서 임계값 바꿀 때마다 다시 구워야 한다.
 * 단 하나, **부재로 돌아가는 것만은 보드가 스스로 정한다** — 폰이 떠나면
 * 명령할 주체가 사라지기 때문이다.
 *
 * 시리얼 프로토콜 (한 줄에 하나, \n 종결). 맥의 host/welcome.py가 읽는다.
 *   READY          부팅 완료
 *   EVT WELCOME    환영 시작 → 맥이 화면을 깨우고 앱을 연다
 *   EVT PRESENT    연출 끝, 재실 상태
 *   EVT AWAY       부재로 복귀 (맥은 로그만)
 *   LINK up/down   BLE 연결 상태. 디버깅용
 *
 * BLE
 *   비콘 UUID  6E753430-646B-4E55-C000-000000000001  major=1 minor=1
 *   서비스     6E753430-646B-4E55-C000-000000000010
 *     ├ ..11 status  notify+read  4바이트 [state, rssi, seq, flags]
 *     └ ..12 cmd     write        1바이트 (아래 CMD_* 참고)
 *
 * 업로드:
 *   CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
 *   "$CLI" compile --fqbn nucode:nrf52:nu40dk ~/Documents/Arduino/nu40dk_welcome
 *   "$CLI" upload  --fqbn nucode:nrf52:nu40dk -p /dev/cu.usbmodem11101 ~/Documents/Arduino/nu40dk_welcome
 */

// 이 보드의 Serial은 TinyUSB CDC라 이 헤더가 없으면 링크 에러가 난다
#include <Adafruit_TinyUSB.h>
#include <bluefruit.h>
#include <math.h>

// UUID 문자열은 BLEUuid가 포인터로만 들고 있다가 begin()에서 파싱한다.
// 지역 버퍼를 넘기면 파싱 시점에 이미 날아가 있으므로 반드시 정적 수명이어야 한다.
static const char* UUID_SERVICE = "6e753430-646b-4e55-c000-000000000010";
static const char* UUID_STATUS  = "6e753430-646b-4e55-c000-000000000011";
static const char* UUID_CMD     = "6e753430-646b-4e55-c000-000000000012";

// iBeacon proximity UUID. **아이폰 앱의 BEACON_UUID와 반드시 같아야 한다.**
// 하나라도 다르면 앱은 리전에 영영 못 들어가고, 증상은 "아무 일도 안 일어남"이다.
static uint8_t BEACON_UUID[16] = {
  0x6E, 0x75, 0x34, 0x30, 0x64, 0x6B, 0x4E, 0x55,
  0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
};
const uint16_t BEACON_MAJOR = 1;
const uint16_t BEACON_MINOR = 1;

// 1m 거리에서의 예상 RSSI. iOS가 CLBeacon.accuracy를 계산할 때만 쓴다.
// 우리는 정밀 거리를 안 쓰므로 대략값으로 둔다. 정확히 맞출 필요 없다.
const int8_t BEACON_RSSI_1M = -59;

BLEService        svcWelcome(UUID_SERVICE);
BLECharacteristic chrStatus(UUID_STATUS);
BLECharacteristic chrCmd(UUID_CMD);
BLEBeacon         beacon(BEACON_UUID, BEACON_MAJOR, BEACON_MINOR, BEACON_RSSI_1M);

const uint8_t LEDS[4]    = { PIN_LED1, PIN_LED2, PIN_LED3, PIN_LED4 };
const uint8_t BUTTONS[4] = { PIN_BUTTON1, PIN_BUTTON2, PIN_BUTTON3, PIN_BUTTON4 };

// ---------------------------------------------------------------- 조절값

// 송신 출력. 촬영장에서 제일 먼저 만지는 값이다.
// 이게 사실상 "어디까지 와야 알아보는가"를 정한다.
// 허용값: -40 -20 -16 -12 -8 -4 0 2 3 4 5 6 7 8
//
//   -8  책상 반경 10m 안쪽. 좁은 사무실에서 한 컷에 담을 때
//    0  사무실 문 열고 들어오면 잡힌다 (기본값)
//    8  복도 끝·엘리베이터에서부터 잡힌다. 너무 일찍 터질 수 있다
//
// 비콘 리전 진입은 '신호가 잡히는 순간'이다. 거리 임계값이 따로 없으므로
// **도달 거리 자체가 곧 연출 시점**이다. 이 값이 유일한 조절 손잡이다.
const int8_t TX_POWER = 0;

// 환영 연출 길이.
//
// **촬영 때문에 길다.** 폰을 먼저 찍고 보드로 걸어오면 6초짜리 연출은 이미 끝나 있다.
// 카메라를 옮기고 초점을 잡을 시간까지 담으려면 1분은 되어야 한다.
// 중간 구간이 반복 반짝임이라 이 값만 늘리면 그만큼 더 반짝인다
// (앞 SWEEP_MS 훑기 → 가운데 반짝임 → 뒤 TAIL_MS 착지).
//
// 부재 타이머는 ST_PRESENT에서만 도므로 연출이 중간에 잘리지 않는다.
// 일상용으로 되돌리려면 6000으로 낮춘다.
const uint32_t WELCOME_MS = 60000;
const uint32_t SWEEP_MS   = 900;    // 앞부분: 좌→우로 훑는 '알아봄'
const uint32_t TAIL_MS    = 1400;   // 뒷부분: 재실 밝기로 착지

// 연결이 끊긴 뒤 이만큼 지나야 부재로 친다.
// 짧으면 폰이 잠깐 끊길 때마다 환영이 다시 터진다. 자리에 앉아 있는데
// 보드가 30초마다 축포를 쏘는 것만큼 김빠지는 것도 없다.
// 촬영 모드에서는 리테이크를 빨리 돌려야 하므로 짧게 간다.
const uint32_t AWAY_AFTER_MS      = 60UL * 1000UL;
const uint32_t AWAY_AFTER_FILM_MS = 10UL * 1000UL;

// 이 시간 안에 두 번째 도착 통보가 와도 무시한다.
// 앱이 리전 진입을 중복으로 보고하는 경우가 실제로 있다(레인징이 붙을 때).
const uint32_t WELCOME_COOLDOWN_MS = 8000;

// 버튼1을 누른 뒤 연출이 시작될 때까지의 시간.
// **누르는 손이 화면에 안 들어오게 하려고 있다.** 폰이 실제로 도착했을 때는
// 이 지연을 쓰지 않는다 — 문을 열고 들어왔는데 20초 뒤에 반응하면 이상하다.
const uint32_t PREROLL_MS = 20000;

// 연결해놓고 이 시간 안에 우리 서비스를 안 쓰면 끊는다.
//
// **보드에 붙을 수 있는 센트럴은 하나뿐이다.** 그런데 같은 보드를 쓰는 다른 앱이
// (특히 아이폰의 Together 앱) 저장해둔 주소로 무기한 재연결을 걸어두기 때문에,
// 펌웨어를 바꿔도 링크를 점유해버린다. 그러면 Welcome 앱이 못 붙어서
// **알림과 잠금화면은 뜨는데 LED와 맥만 조용한** 증상이 나온다. 실제로 밟았다.
//
// 우리 앱은 붙자마자 status 알림을 구독하고 cmd를 쓴다. 남의 앱은 우리 서비스를
// 아예 모르므로 아무것도 하지 않는다. 그걸로 구분해서 자리를 비운다.
const uint32_t STRANGER_TIMEOUT_MS = 8000;

const uint32_t NOTIFY_MS = 1000;   // status 알림 주기 = 앱이 깨어나는 주기
const uint32_t FRAME_MS  = 16;     // LED 렌더 주기 (약 60fps)

// 사람이 읽는 로그를 찍는 간격.
// 매초 찍으면 USB CDC 버퍼를 밀어내서 그 틈에 `EVT` 줄이 씹힌다 (실제로 밟았다).
// 맥이 읽어야 하는 건 `EVT`뿐이니 사람용 로그는 뜸해도 된다.
const uint32_t HUMAN_LOG_MS = 5000;

const uint32_t BTN_DEBOUNCE_MS = 220;

// ---------------------------------------------------------------- 상태

enum State : uint8_t {
  ST_AWAY    = 0,   // 부재. 아무도 없다
  ST_WELCOME = 1,   // 환영 연출 중
  ST_PRESENT = 2,   // 재실. 곁에 있다
};

static const char* STATE_NAME[] = { "부재", "환영", "재실" };
static const char* STATE_EVT[]  = { "AWAY", "WELCOME", "PRESENT" };

enum Cmd : uint8_t {
  CMD_AUTO    = 0x00,   // 아무것도 안 함 (하트비트용)
  CMD_ARRIVED = 0x01,   // 도착했다 → 환영 연출
  CMD_QUIET   = 0x02,   // 조용히. 촬영 중 LED가 화면에 끼면 안 될 때
  CMD_AWAY    = 0x03,   // 부재로 리셋 (앱에서 리허설 초기화)
};

static uint16_t gammaLut[256];

static uint16_t connHandle  = BLE_CONN_HANDLE_INVALID;
static int8_t   lastRssi    = 0;
static bool     rssiValid   = false;
static uint8_t  seq         = 0;

static uint8_t  state       = ST_AWAY;
static uint32_t stateSince  = 0;
static uint32_t lastWelcome = 0;      // 마지막 환영 시각. 중복 통보를 막는다
static uint32_t linkLostAt  = 0;      // 끊긴 시각. 0이면 끊긴 적 없음
static bool     quiet       = false;
static bool     filming     = false;
// 버튼1로 예약된 시각. 0이면 예약 없음
static uint32_t armedAt     = 0;

static uint32_t lastNotify  = 0;
static uint32_t lastFrame   = 0;
static uint32_t lastHumanLog = 0;
static uint8_t  lastLogState = 0xFF;
static uint32_t connectedAt  = 0;      // 연결된 시각
static bool     claimed      = false;  // 우리 앱이라는 증거(구독/명령)를 봤나

struct Btn { bool wasDown; uint32_t lastMs; };
static Btn btns[4] = {};

uint32_t awayAfterMs() { return filming ? AWAY_AFTER_FILM_MS : AWAY_AFTER_MS; }

// ---------------------------------------------------------------- LED

void buildGammaLut() {
  for (uint16_t i = 0; i < 256; i++) {
    gammaLut[i] = (uint16_t) lroundf(powf(i / 255.0f, 2.6f) * 4095.0f);
  }
}

void writeLed(uint8_t idx, float level) {
  if (level < 0.0f) level = 0.0f;
  if (level > 1.0f) level = 1.0f;
  analogWrite(LEDS[idx], gammaLut[(uint8_t) lroundf(level * 255.0f)]);
}

float breathe(uint32_t ms, uint32_t period) {
  float t = (ms % period) / (float) period;
  return 0.5f * (1.0f - cosf(2.0f * (float) PI * t));
}

// 두근-두근. 큰 박동에 작은 박동이 붙는다. 0.0~1.0
float heartbeat(uint32_t ms, uint32_t period) {
  float t = (ms % period) / (float) period;
  float a = expf(-powf((t - 0.02f) * 9.0f, 2.0f));
  float b = expf(-powf((t - 0.24f) * 9.0f, 2.0f)) * 0.55f;
  float v = a + b;
  return v > 1.0f ? 1.0f : v;
}

// 재실 밝기. 있는 듯 없는 듯해야 한다. 밝으면 하루 종일 눈에 거슬린다
float presentLevel(uint32_t now) {
  return 0.05f + 0.13f * breathe(now, 5200);
}

void renderLeds(uint32_t now) {
  if (quiet) {
    for (uint8_t i = 0; i < 4; i++) writeLed(i, 0.0f);
    return;
  }

  switch (state) {
    case ST_AWAY: {
      // 아무도 없다. 1번만 아주 어둡게. 꺼진 것과 구분만 되면 된다.
      // 완전히 끄면 책상 위에서 죽은 보드로 보인다
      writeLed(0, 0.02f + 0.05f * breathe(now, 6000));
      for (uint8_t i = 1; i < 4; i++) writeLed(i, 0.0f);
      break;
    }

    case ST_WELCOME: {
      uint32_t t = now - stateSince;

      if (t < SWEEP_MS) {
        // "어, 왔다" — 좌에서 우로 한 번 훑는다. 알아보는 동작이다
        float pos = (t / (float) SWEEP_MS) * 5.0f - 0.5f;
        for (uint8_t i = 0; i < 4; i++) {
          float d = (float) i - pos;
          writeLed(i, expf(-(d * d) / 0.35f));
        }
      } else if (t < WELCOME_MS - TAIL_MS) {
        // 반짝반짝. 네 개가 위상을 달리해 반짝여야 '기뻐서 들뜬' 느낌이 난다.
        // 넷이 같이 깜빡이면 경고등처럼 보인다
        float beat = heartbeat(now, 620);
        for (uint8_t i = 0; i < 4; i++) {
          float ph = ((now + i * 155) % 780) / 780.0f;
          float twinkle = 0.5f * (1.0f - cosf(2.0f * (float) PI * ph));
          writeLed(i, 0.16f + 0.84f * fmaxf(beat * 0.55f, twinkle));
        }
      } else {
        // 착지. 뚝 끊으면 전원이 나간 것처럼 보인다. 재실 밝기로 서서히 내린다
        float k = (t - (WELCOME_MS - TAIL_MS)) / (float) TAIL_MS;
        float from = 0.16f + 0.84f * heartbeat(now, 620);
        float to   = presentLevel(now);
        for (uint8_t i = 0; i < 4; i++) writeLed(i, from * (1.0f - k) + to * k);
      }
      break;
    }

    case ST_PRESENT: {
      float v = presentLevel(now);
      for (uint8_t i = 0; i < 4; i++) writeLed(i, v);
      break;
    }
  }
}

// ---------------------------------------------------------------- 상태 전이

void setState(uint8_t next, uint32_t now) {
  if (state == next) return;
  state = next;
  stateSince = now;
  // 맥이 읽는 줄. 사람이 읽는 로그와 섞이지 않게 EVT로 시작한다
  Serial.printf("EVT %s\n", STATE_EVT[next]);
  Serial.printf("[welcome] 상태 → %s\n", STATE_NAME[next]);
}

// 도착 통보. 폰이 보내거나 버튼1로 직접 부른다
void triggerWelcome(uint32_t now, const char* who) {
  if (state == ST_WELCOME) return;                       // 이미 연출 중
  if (lastWelcome && now - lastWelcome < WELCOME_COOLDOWN_MS) {
    Serial.printf("[welcome] 도착 통보 무시 (쿨다운, %s)\n", who);
    return;
  }
  lastWelcome = now;
  quiet = false;
  Serial.printf("[welcome] 도착! (%s)\n", who);
  setState(ST_WELCOME, now);
}

void updateState(uint32_t now) {
  // 버튼1 예약이 익었는지 본다.
  //
  // 남은 초를 매초 찍으면 안 된다 — EVT 방송도 매초 나가는데, 둘이 겹치면
  // USB CDC 버퍼가 밀려서 EVT가 씹힌다(예전에 실제로 밟은 버그다).
  // 그래서 20·10·5·3·2·1에서만 알린다
  if (armedAt) {
    uint32_t elapsed = now - armedAt;
    if (elapsed >= PREROLL_MS) {
      armedAt     = 0;
      lastWelcome = 0;                    // 리테이크용이라 쿨다운을 무시한다
      triggerWelcome(now, "버튼1 예약");
      return;
    }
    static uint32_t lastLeft = 0;
    uint32_t left = (PREROLL_MS - elapsed + 999) / 1000;
    if (left != lastLeft && (left <= 3 || left == 5 || left == 10 || left == 20)) {
      Serial.printf("[welcome] 시작까지 %lu초\n", (unsigned long) left);
    }
    lastLeft = left;
  }

  if (state == ST_WELCOME && now - stateSince >= WELCOME_MS) {
    setState(ST_PRESENT, now);
    return;
  }

  // 부재 판정만은 보드 몫이다. 폰이 떠난 뒤에는 명령할 주체가 없다.
  // 연결이 살아 있으면 사람이 있는 것이므로 타이머를 돌리지 않는다
  if (state == ST_PRESENT && connHandle == BLE_CONN_HANDLE_INVALID) {
    if (linkLostAt && now - linkLostAt >= awayAfterMs()) {
      setState(ST_AWAY, now);
    }
  }
}

// ---------------------------------------------------------------- BLE

void connect_callback(uint16_t handle) {
  connHandle  = handle;
  rssiValid   = false;
  linkLostAt  = 0;
  connectedAt = millis();
  claimed     = false;   // 우리 앱인지는 아직 모른다. 구독하거나 명령을 보내야 안다

  BLEConnection* conn = Bluefruit.Connection(handle);
  if (conn) {
    // 이걸 켜야 getRssi()가 값을 준다. 안 켜면 계속 0이다
    conn->monitorRssi();
  }
  // **연결되면 Bluefruit이 광고를 멈춘다. 여기서 다시 켜야 한다.**
  //
  // 광고가 멈추면 아이폰이 비콘을 못 본다. 그러면 자리에 앉아 있는데도 30초쯤 뒤
  // iOS가 '리전 이탈'로 판정해서 잠금화면 카드가 걷히고, 다음에 링크가 잠깐
  // 흔들려 재연결될 때 '재입장'으로 환영이 또 터진다.
  // 실측으로 잡은 문제다 — 연결된 상태에서 beacon_check.py를 돌리면 광고가 안 보였다.
  //
  // **연결 불가(non-connectable) 광고로 바꿔서 내보낸다.** 연결 슬롯을 쓰지 않으므로
  // SoftDevice가 거부하지 않는다. 연결 가능한 채로 다시 켜려 하면 슬롯이 없다며
  // 실패한다 (begin(2)로 늘려도 실패했다 — 실측). 어차피 폰이 이미 붙어 있어서
  // 지금은 아무도 연결할 필요가 없다. iBeacon도 원래 연결 불가 광고가 표준이다.
  Bluefruit.Advertising.setType(BLE_GAP_ADV_TYPE_NONCONNECTABLE_SCANNABLE_UNDIRECTED);
  bool advOk = Bluefruit.Advertising.start(0);
  Serial.printf("LINK up (광고 유지: %s)\n", advOk ? "성공" : "실패");

  // **연결됐다고 환영하지 않는다.** 도착 판정은 앱이 비콘으로 하고,
  // 앱이 CMD_ARRIVED를 보내야 연출이 시작된다. 연결만으로 터뜨리면
  // 자리에 앉아 있는 내내 링크가 흔들릴 때마다 축포가 올라간다.
}

void disconnect_callback(uint16_t handle, uint8_t reason) {
  (void) handle;
  connHandle = BLE_CONN_HANDLE_INVALID;
  rssiValid  = false;
  linkLostAt = millis();

  // 다시 연결받을 수 있어야 한다. connect_callback에서 연결 불가로 바꿔놨으므로
  // 여기서 되돌리지 않으면 폰이 영영 못 붙는다.
  // restartOnDisconnect(true)가 곧 광고를 재시작하는데, 그때 이 타입이 쓰인다
  Bluefruit.Advertising.setType(BLE_GAP_ADV_TYPE_CONNECTABLE_SCANNABLE_UNDIRECTED);

  Serial.printf("LINK down (reason 0x%02X)\n", reason);
}

// status 알림을 구독했다 = 우리 서비스를 아는 앱이다. 쫓아내지 않는다
void cccd_callback(uint16_t handle, BLECharacteristic* chr, uint16_t value) {
  (void) handle;
  if (chr->uuid == chrStatus.uuid && value) {
    claimed = true;
    Serial.println("[welcome] 우리 앱 확인 (status 구독)");
  }
}

void cmd_write_callback(uint16_t handle, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void) handle; (void) chr;
  claimed = true;   // 명령을 보냈다는 것 자체가 우리 앱이라는 증거다
  if (len < 1) return;

  switch (data[0]) {
    case CMD_ARRIVED:
      triggerWelcome(millis(), "폰");
      break;
    case CMD_QUIET:
      quiet = true;
      Serial.println("[welcome] 조용히");
      break;
    case CMD_AWAY:
      lastWelcome = 0;   // 리허설을 다시 돌릴 수 있게 쿨다운도 푼다
      quiet = false;
      setState(ST_AWAY, millis());
      break;
    case CMD_AUTO:
    default:
      break;
  }
}

void startAdvertising() {
  // setBeacon()이 광고 패킷을 통째로 iBeacon 형식으로 채운다(clearData + flags 포함).
  // 25바이트 제조사 데이터 + 플래그 3바이트 = 30바이트라 **광고 본문에는 더 들어갈 자리가 없다.**
  // 그래서 서비스 UUID와 이름은 스캔 응답으로 뺀다.
  Bluefruit.Advertising.setBeacon(beacon);

  // 앱이 처음 보드를 등록할 때 이 서비스 UUID로 찾는다.
  // 128비트 UUID가 18바이트를 먹으므로 이름은 짧아야 31바이트 안에 함께 들어간다
  Bluefruit.ScanResponse.addService(svcWelcome);
  Bluefruit.ScanResponse.addName();

  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(160, 244);   // 단위 0.625ms → 100ms ~ 152.5ms
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);                // 0 = 무기한. 출근할 때까지 계속 부른다
}

// ---------------------------------------------------------------- 버튼

// 1 환영 리허설 / 2 부재 리셋 / 3 촬영 모드 / 4 조용히
void pollButtons(uint32_t now) {
  for (uint8_t i = 0; i < 4; i++) {
    bool down = (digitalRead(BUTTONS[i]) == LOW);   // 눌리면 LOW
    if (down && !btns[i].wasDown && now - btns[i].lastMs > BTN_DEBOUNCE_MS) {
      btns[i].lastMs = now;
      switch (i) {
        case 0:
          // 폰 없이 전체 체인(보드 연출 + 맥 깨우기)을 돌려보는 리허설 버튼.
          // 촬영장에서 제일 많이 누르게 된다.
          //
          // **바로 시작하지 않고 PREROLL_MS 뒤에 시작한다.** 누르는 손이 화면에
          // 들어가면 안 되기 때문이다. 누르고 카메라를 들고 자리를 잡으면 된다.
          // 기다리는 동안 LED는 평소 대기 모습 그대로 둔다 — 여기서 뭔가 빛나면
          // 그게 촬영에 찍힌다. 카운트다운은 시리얼로만 알린다.
          if (armedAt) {
            armedAt = 0;
            Serial.println("[welcome] 예약 취소 (버튼1 다시)");
          } else {
            armedAt = now ? now : 1;      // 0은 '예약 없음'이라 부팅 직후를 피한다
            Serial.printf("[welcome] %lu초 뒤 시작 (버튼1) — 취소는 다시 누르기\n",
                          (unsigned long)(PREROLL_MS / 1000));
          }
          break;
        case 1:
          lastWelcome = 0;
          armedAt     = 0;                // 예약도 함께 지운다. 리셋은 리셋이어야 한다
          setState(ST_AWAY, now);
          Serial.println("[welcome] 부재로 리셋 (버튼2)");
          break;
        case 2:
          filming = !filming;
          Serial.printf("[welcome] 촬영 모드 %s (부재까지 %lus)\n",
                        filming ? "켬" : "끔",
                        (unsigned long)(awayAfterMs() / 1000));
          break;
        case 3:
          quiet = !quiet;
          Serial.printf("[welcome] 조용히 %s\n", quiet ? "켬" : "끔");
          break;
      }
    }
    btns[i].wasDown = down;
  }
}

// ---------------------------------------------------------------- 본체

void setup() {
  Serial.begin(115200);

  for (uint8_t i = 0; i < 4; i++) pinMode(BUTTONS[i], INPUT_PULLUP);

  analogWriteResolution(12);
  buildGammaLut();
  for (uint8_t i = 0; i < 4; i++) {
    pinMode(LEDS[i], OUTPUT);
    writeLed(i, 0.0f);
  }

  // 연결 슬롯은 하나면 된다. 폰이 붙어 있는 동안에도 광고를 이어가야 하지만,
  // 슬롯을 늘리는 방법(begin(2))으로는 해결되지 않았다 — 실측에서 광고 재시작이
  // 그대로 실패했다. 연결 불가 광고로 바꾸는 쪽이 답이다 (connect_callback 참고)
  Bluefruit.begin();
  Bluefruit.setTxPower(TX_POWER);
  // 스캔 응답에 서비스 UUID(18바이트)와 함께 들어가야 해서 이름이 짧다.
  // 길면 Bluefruit이 조용히 잘라내거나 아예 못 넣는다
  Bluefruit.setName("NUWELCOME");

  // LED_CONN이 이 보드에서는 PIN_LED2다. 끄지 않으면 Bluefruit이 2번 LED를
  // 제멋대로 깜빡여서 연출과 싸운다
  Bluefruit.autoConnLed(false);

  // iOS가 받아주는 범위 안에서 잡는다 (최소 15ms, min+10ms <= max)
  Bluefruit.Periph.setConnInterval(24, 48);     // 단위 1.25ms → 30ms ~ 60ms
  Bluefruit.Periph.setConnectCallback(connect_callback);
  Bluefruit.Periph.setDisconnectCallback(disconnect_callback);

  svcWelcome.begin();   // 서비스가 먼저 begin()이어야 캐릭터리스틱이 여기 붙는다

  chrStatus.setProperties(CHR_PROPS_NOTIFY | CHR_PROPS_READ);
  chrStatus.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  chrStatus.setFixedLen(4);
  chrStatus.setCccdWriteCallback(cccd_callback);   // 남의 앱을 가려내는 데 쓴다
  chrStatus.begin();

  uint8_t initial[4] = { ST_AWAY, 0, 0, 0 };
  chrStatus.write(initial, sizeof(initial));

  chrCmd.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  chrCmd.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  chrCmd.setFixedLen(1);
  chrCmd.setWriteCallback(cmd_write_callback);
  chrCmd.begin();

  stateSince = millis();
  startAdvertising();

  Serial.println("READY");
  Serial.printf("[welcome] iBeacon 광고 시작 (major=%u minor=%u tx=%d)\n",
                BEACON_MAJOR, BEACON_MINOR, TX_POWER);
}

void loop() {
  uint32_t now = millis();

  pollButtons(now);

  if (now - lastFrame >= FRAME_MS) {
    lastFrame = now;
    renderLeds(now);
  }

  if (now - lastNotify >= NOTIFY_MS) {
    lastNotify = now;
    updateState(now);

    // 남의 앱이 자리를 차지하고 있으면 비운다. 우리 앱은 붙자마자 구독하므로
    // 여기 걸리지 않는다 (백그라운드에서 깨어나도 8초면 충분하다)
    if (connHandle != BLE_CONN_HANDLE_INVALID && !claimed
        && now - connectedAt >= STRANGER_TIMEOUT_MS) {
      Serial.println("[welcome] 우리 앱이 아닌 연결 — 자리를 비웁니다");
      BLEConnection* conn = Bluefruit.Connection(connHandle);
      if (conn) conn->disconnect();
    }

    // **상태를 매초 다시 알린다.**
    //
    // 상태가 바뀌는 순간에만 한 번 보냈더니 그 한 줄이 USB CDC 버퍼에서 씹혀서
    // 맥이 도착을 통째로 놓쳤다 (보드는 환영 연출 중인데 컴퓨터만 조용했다).
    // 그래서 '변화를 한 번 통보'가 아니라 '현재 상태를 계속 방송'하는 방식으로 바꿨다.
    // 맥은 값이 아니라 **값의 변화**를 보고 판단하므로 매초 보내도 중복 실행되지 않고,
    // 한 줄쯤 씹혀도 다음 초에 따라잡는다. 환영은 6초라 기회가 여섯 번 있다.
    Serial.printf("EVT %s\n", STATE_EVT[state]);

    if (connHandle != BLE_CONN_HANDLE_INVALID) {
      BLEConnection* conn = Bluefruit.Connection(connHandle);
      if (conn) {
        int8_t r = conn->getRssi();
        // 0은 SoftDevice가 아직 표본을 못 채웠다는 뜻이다. 실제 0dBm일 리는 없다
        if (r != 0) { lastRssi = r; rssiValid = true; }
      }

      uint8_t payload[4] = {
        state,
        (uint8_t) lastRssi,
        seq++,
        (uint8_t) ((rssiValid ? 0x01 : 0x00) | (filming ? 0x02 : 0x00)
                   | (quiet ? 0x04 : 0x00)),
      };
      // 값이 그대로여도 매번 보낸다. 이 알림이 백그라운드 앱을 깨우는 신호다
      chrStatus.notify(payload, sizeof(payload));
    }

    // 사람이 읽는 로그. 상태가 바뀌었거나 한참 지났을 때만 찍는다.
    // 매초 찍으면 CDC 버퍼가 밀려서 위의 EVT 줄이 씹힌다 — 그게 원래 버그였다
    if (state != lastLogState || now - lastHumanLog >= HUMAN_LOG_MS) {
      lastLogState = state;
      lastHumanLog = now;
      if (connHandle != BLE_CONN_HANDLE_INVALID) {
        Serial.printf("[welcome] %s  rssi=%d%s\n",
                      STATE_NAME[state], lastRssi, filming ? "  [촬영]" : "");
      } else {
        Serial.printf("[welcome] %s — 연결 없음%s\n",
                      STATE_NAME[state], filming ? "  [촬영]" : "");
      }
    }
  }
}
