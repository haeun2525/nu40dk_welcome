#!/usr/bin/env python3
"""
NU40DK Welcome — 맥 쪽 데몬

보드가 시리얼로 "EVT WELCOME"을 뱉으면 맥을 깨우고, 환영 화면을 띄우고,
config.json에 적힌 앱들을 연다. 출근길에 문을 열면 이게 한꺼번에 일어난다.

보드가 없어도, 뽑았다 꽂아도, 프로그램은 계속 살아서 기다린다.
이 데몬이 죽어 있으면 보드는 반짝이는데 컴퓨터만 조용하다 — 촬영 전에
터미널에 초록색 '보드 연결됨'이 떠 있는지 반드시 확인할 것.

pyserial 없이 termios로 직접 포트를 연다. 이 맥에 pyserial이 없고,
촬영 전날 pip이 막혀 있는 상황을 만들고 싶지 않아서다.

실행:  python3 ~/Documents/Arduino/nu40dk_welcome/host/welcome.py
리허설: python3 welcome.py --test    보드 없이 맥 쪽 연출만 한 번 돌린다
종료:  Ctrl-C
"""

import glob
import json
import os
import re
import select
import subprocess
import sys
import termios
import time
import urllib.parse

HERE         = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH  = os.path.join(HERE, "config.json")
WELCOME_PAGE = os.path.join(HERE, "welcome.html")

CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 보드를 못 찾거나 끊겼을 때 다시 찾아보는 간격
RECONNECT_SEC = 1.0

# 앱을 여러 개 열 때 사이 간격. 한꺼번에 열면 창들이 서로 앞으로 나오려고 싸운다
STAGGER_SEC = 0.35

# 같은 이벤트가 이 시간 안에 또 오면 무시한다. 펌웨어도 쿨다운을 걸지만
# 보드를 리셋하거나 재업로드하면 EVT가 다시 나올 수 있다
COOLDOWN_SEC = 5.0

EVT_RE = re.compile(r"^EVT ([A-Z]+)$")

STATE_LABEL = {"AWAY": "부재", "WELCOME": "환영 중", "PRESENT": "자리에 있음"}

DIM    = "\033[2m"
BOLD   = "\033[1m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
CYAN   = "\033[36m"
RESET  = "\033[0m"


def log(msg, color=""):
    stamp = time.strftime("%H:%M:%S")
    print(f"{DIM}{stamp}{RESET}  {color}{msg}{RESET}", flush=True)


def load_config():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def find_port(configured):
    """설정에 포트가 박혀 있으면 그것만, 아니면 usbmodem을 훑는다."""
    if configured:
        return configured if os.path.exists(configured) else None
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    return ports[0] if ports else None


def open_port(path):
    """포트를 raw 모드로 연다. 실패하면 OSError가 그대로 올라간다."""
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)

        # 줄바꿈 변환, 에코, 시그널 해석을 전부 끈다. 들어온 바이트를 그대로 받는다
        iflag = 0
        oflag = 0
        lflag = 0
        cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
        ispeed = ospeed = termios.B115200
        cc = list(cc)
        cc[termios.VMIN]  = 0
        cc[termios.VTIME] = 0

        termios.tcsetattr(
            fd, termios.TCSANOW,
            [iflag, oflag, cflag, lflag, ispeed, ospeed, cc],
        )
        # 꽂아둔 사이 쌓인 묵은 출력은 버린다. 안 그러면 켜자마자 환영이 터진다
        termios.tcflush(fd, termios.TCIFLUSH)
    except Exception:
        os.close(fd)
        raise

    return fd


# ---------------------------------------------------------------- 맥 깨우기

def wake_display(seconds):
    """잠든 화면을 켠다.

    caffeinate -u 는 '사용자가 방금 움직인 것처럼' 취급해 디스플레이를 깨운다.
    -t 로 유지 시간을 주지 않으면 촬영 내내 화면이 안 꺼져서 좋기도 하고
    나쁘기도 한데, 짧게 주고 손을 떼는 쪽이 안전하다.

    한계: **맥이 완전히 잠들어 있으면 이 프로세스도 같이 자고 있어서 못 깨운다.**
    화면만 꺼진 상태(디스플레이 슬립)에서만 동작한다. 촬영에서는 시스템 설정 >
    잠금 화면에서 '디스플레이 끄기'만 짧게, '잠자기'는 안 함으로 두는 게 확실하다.
    """
    try:
        subprocess.Popen(["caffeinate", "-u", "-t", str(seconds)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("  ↳ 화면 깨움", GREEN)
    except OSError as e:
        log(f"  ↳ 화면 못 깨움 — {e}", YELLOW)


def show_welcome(cfg):
    """환영 화면을 크롬 앱 모드 창으로 띄운다.

    --app은 탭도 주소창도 없는 창을 연다. 페이지가 끝나면 스스로 닫히므로
    출근하고 나서 창이 남지 않는다.
    """
    if not os.path.exists(WELCOME_PAGE):
        log("welcome.html이 없습니다 — 환영 화면 건너뜀", YELLOW)
        return
    if not os.path.exists(CHROME_BIN):
        log("크롬을 못 찾아 환영 화면을 건너뜁니다", YELLOW)
        return

    params = {
        "msg": cfg.get("message", "환영합니다!"),
        "sub": cfg.get("submessage", ""),
        "name": cfg.get("name", ""),
        # 화면이 스스로 닫히는 시각. 촬영 때는 카메라를 옮길 시간이 필요해서
        # 보드 연출(WELCOME_MS)만큼 길게 잡는다
        "ms": int(float(cfg.get("screen_seconds", 6.5)) * 1000),
    }
    url = ("file://" + urllib.parse.quote(WELCOME_PAGE) + "?"
           + urllib.parse.urlencode(params))
    try:
        subprocess.Popen([CHROME_BIN, f"--app={url}", "--start-fullscreen"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("  ↳ 환영 화면", GREEN)
    except OSError as e:
        log(f"  ↳ 환영 화면 못 띄움 — {e}", YELLOW)


def open_item(item):
    """앱 하나 또는 URL 하나. 이미 떠 있는 앱이면 앞으로 끌어온다."""
    if item.get("app"):
        cmd, label = ["open", "-a", item["app"]], item["app"]
    elif item.get("url"):
        cmd, label = ["open", item["url"]], item["url"]
    else:
        log(f"  ↳ 열 대상이 비었습니다: {item}", YELLOW)
        return

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        log(f"  ↳ {label} 열림", GREEN)
    else:
        detail = (result.stderr or "").strip() or f"open 종료코드 {result.returncode}"
        log(f"  ↳ '{label}' 못 엶 — {detail}", YELLOW)


def say(text):
    """맞이하는 목소리. 촬영에서 빼고 싶으면 config에서 지우면 된다."""
    try:
        subprocess.Popen(["say", "-v", "Yuna", text],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        log(f"  ↳ 음성 못 냄 — {e}", YELLOW)


def welcome(cfg):
    """도착했을 때 맥이 하는 일 전부."""
    log(f"{BOLD}환영합니다!{RESET}", CYAN)

    # 순서가 중요하다. 화면부터 깨워야 그 위로 창이 뜨는 게 보인다.
    # 앱을 먼저 열면 꺼진 화면 뒤에서 다 끝나 있고, 켜졌을 땐 이미 정적이다
    wake_display(int(cfg.get("wake_seconds", 8)))

    if cfg.get("welcome_screen", True):
        # 화면이 켜지는 데 잠깐 걸린다. 바로 띄우면 앞부분 애니메이션을 놓친다
        time.sleep(float(cfg.get("screen_delay_sec", 1.2)))
        show_welcome(cfg)

    voice = cfg.get("voice")
    if voice:
        say(voice)

    items = cfg.get("open", [])
    if items:
        # 환영 화면이 잠깐 혼자 있어야 그림이 산다. 앱은 그 뒤에 올라온다
        time.sleep(float(cfg.get("apps_delay_sec", 2.5)))
        for i, item in enumerate(items):
            if i:
                time.sleep(STAGGER_SEC)
            open_item(item)


def run():
    cfg = load_config()
    port_cfg = cfg.get("port")

    print()
    log("NU40DK Welcome 시작", CYAN)
    log(f"  환영 문구  {cfg.get('message', '환영합니다!')}")
    apps = [i.get("app") or i.get("url") or "?" for i in cfg.get("open", [])]
    log(f"  도착하면   {', '.join(apps) if apps else '(여는 앱 없음)'}")
    log("종료하려면 Ctrl-C", DIM)

    # 환영 화면은 별도 프로세스라 실패해도 조용히 묻힌다.
    # 도착한 뒤에 알게 되면 늦으므로 시작할 때 확인해둔다
    if cfg.get("welcome_screen", True):
        for path, what in ((WELCOME_PAGE, "welcome.html"), (CHROME_BIN, "크롬")):
            if not os.path.exists(path):
                log(f"{what}이(가) 없어 환영 화면이 안 뜹니다 {DIM}{path}{RESET}", YELLOW)
    print()

    fd = None
    path = None
    buf = b""
    last_welcome = 0.0
    board_state = None         # 보드가 방송하는 현재 상태. 변화만 보고 반응한다
    warned_missing = False     # "보드 못 찾음"을 매초 찍지 않기 위한 빗장
    warned_wrong_fw = False    # 다른 펌웨어 경고도 한 번만

    try:
        while True:
            # --- 연결 ---
            if fd is None:
                path = find_port(port_cfg)
                if path is None:
                    if not warned_missing:
                        log("보드를 찾는 중… (USB 연결 확인)", YELLOW)
                        warned_missing = True
                    time.sleep(RECONNECT_SEC)
                    continue

                try:
                    fd = open_port(path)
                except OSError as e:
                    if not warned_missing:
                        log(f"{path} 못 엶 — {e.strerror}. "
                            f"Arduino 시리얼 모니터가 켜져 있으면 닫아주세요", YELLOW)
                        warned_missing = True
                    time.sleep(RECONNECT_SEC)
                    continue

                buf = b""
                warned_missing = False
                warned_wrong_fw = False
                # 보드를 다시 꽂았으면 그쪽 상태도 처음부터다. 기억을 지운다 —
                # 안 지우면 첫 방송이 '변화'로 안 읽혀서 도착을 놓친다
                board_state = None
                log(f"보드 연결됨 {DIM}{path}{RESET}", GREEN)

            # --- 읽기 ---
            try:
                ready, _, _ = select.select([fd], [], [], 0.5)
                if not ready:
                    # 보드를 뽑으면 조용해지기만 할 뿐 에러가 안 날 수 있다.
                    # 노드가 사라졌는지 직접 확인한다
                    if not os.path.exists(path):
                        raise OSError(f"{path} 사라짐")
                    continue

                chunk = os.read(fd, 4096)
                if not chunk:
                    raise OSError(f"{path} 연결 끊김")
            except OSError as e:
                log(f"보드 끊김 — 다시 찾는 중 {DIM}({e}){RESET}", YELLOW)
                os.close(fd)
                fd = None
                time.sleep(RECONNECT_SEC)
                continue

            buf += chunk

            # --- 줄 단위 처리 ---
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue

                match = EVT_RE.match(line)
                if match:
                    evt = match.group(1)

                    # **보드는 현재 상태를 매초 방송한다.** 우리가 반응할 것은
                    # 값이 아니라 값의 **변화**다.
                    #
                    # 처음에는 보드가 상태 전이 때 한 번만 알렸는데, 그 한 줄이
                    # USB CDC 버퍼에서 씹혀서 도착을 통째로 놓친 적이 있다.
                    # 지금은 매초 오므로 한 줄쯤 사라져도 다음 초에 따라잡는다.
                    if evt == board_state:
                        continue

                    if board_state is None:
                        # 데몬을 켠 시점에 보드가 이미 그 상태였을 뿐이다.
                        # 이걸 도착으로 치면 데몬을 켤 때마다 환영이 터진다
                        board_state = evt
                        log(f"보드 상태: {STATE_LABEL.get(evt, evt)}", DIM)
                        continue

                    board_state = evt

                    if evt == "WELCOME":
                        now = time.monotonic()
                        if now - last_welcome < COOLDOWN_SEC:
                            log("환영 신호 무시 — 방금 했습니다", DIM)
                            continue
                        welcome(cfg)
                        # 쿨다운은 작업이 끝난 시점부터 다시 센다.
                        # 앱 여는 데 몇 초 걸리는 사이 들어온 신호가 통과하면 안 된다
                        last_welcome = time.monotonic()
                    elif evt == "PRESENT":
                        log("자리에 있음", DIM)
                    elif evt == "AWAY":
                        log("부재", DIM)
                    continue

                if line == "READY":
                    log("보드 준비 완료 (iBeacon 광고 중)", GREEN)
                elif line.startswith("LINK"):
                    log(f"  {line}", DIM)
                elif line.startswith("[welcome]"):
                    # 보드의 사람용 로그. 조용히 흘려보내되 상태는 보이게 둔다
                    log(f"  {line[10:]}", DIM)
                elif not warned_wrong_fw:
                    # 다른 펌웨어가 올라가 있으면 여기로 떨어진다.
                    # 원인을 모른 채 기다리는 시간을 없애준다
                    log(f"welcome 신호가 아닌 출력이 옵니다: {DIM}{line[:60]}{RESET}", YELLOW)
                    log("nu40dk_welcome 펌웨어가 올라가 있는지 확인하세요", YELLOW)
                    warned_wrong_fw = True

            # 줄바꿈 없이 쓰레기만 계속 들어오는 펌웨어를 만나도 메모리가 안 새게 한다
            if len(buf) > 8192:
                buf = buf[-1024:]

    except KeyboardInterrupt:
        print()
        log("종료합니다", CYAN)
    finally:
        if fd is not None:
            os.close(fd)


if __name__ == "__main__":
    # 보드 없이 맥 쪽만 리허설한다. 문구·타이밍·앱 목록을 맞출 때 이게 제일 빠르다
    if "--test" in sys.argv:
        log("리허설 — 보드 없이 맥 연출만 실행합니다", CYAN)
        welcome(load_config())
        sys.exit(0)
    sys.exit(run())
