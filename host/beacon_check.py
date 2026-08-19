#!/usr/bin/env python3
"""
보드가 iBeacon으로 광고하고 있는지 맥에서 확인한다.

**촬영 전에 이것부터 돌린다.** 아이폰이 반응하지 않을 때 원인은 대개 셋 중 하나인데,
이 도구 한 번이면 첫 번째가 바로 걸러진다.

  1. 보드에 다른 펌웨어가 올라가 있다     ← 여기서 잡힌다 (광고가 안 보임)
  2. 아이폰 위치 권한이 '항상'이 아니다   ← 앱 화면의 체크리스트에서 확인
  3. 이미 리전 안에 있어서 진입이 안 뜬다 ← 앱의 '환영 리허설'로 확인

bleak이 필요하다. Together 프로젝트의 가상환경을 그대로 쓰면 된다:

    ~/Documents/Arduino/nu40dk_together/host/.venv/bin/python beacon_check.py

첫 실행에서 "Bluetooth device is turned off"가 나오면 블루투스가 꺼진 게 아니라
bleak이 CoreBluetooth 상태 콜백을 1초만 기다리다 단정한 것이다. 한 번 더 실행하면 된다.
"""

import asyncio
import sys

try:
    from bleak import BleakScanner
except ImportError:
    sys.exit("bleak이 없습니다. Together의 가상환경으로 실행하세요:\n"
             "  ~/Documents/Arduino/nu40dk_together/host/.venv/bin/python beacon_check.py")

APPLE_ID = 0x004C          # iBeacon은 애플 제조사 데이터로 실려 온다
WANT_UUID = "6e753430646b4e55c000000000000001"   # 펌웨어의 BEACON_UUID
SCAN_SEC = 7.0

GREEN, YELLOW, DIM, RESET = "\033[32m", "\033[33m", "\033[2m", "\033[0m"


def parse_ibeacon(data: bytes):
    """애플 제조사 데이터에서 iBeacon을 뽑는다. 아니면 None."""
    if len(data) < 23 or data[0] != 0x02 or data[1] != 0x15:
        return None
    return (
        data[2:18].hex(),
        int.from_bytes(data[18:20], "big"),
        int.from_bytes(data[20:22], "big"),
    )


async def main():
    hits = {}

    def on_found(dev, adv):
        beacon = None
        for mid, data in (adv.manufacturer_data or {}).items():
            if mid == APPLE_ID:
                beacon = parse_ibeacon(data)
        if not beacon or beacon[0] != WANT_UUID:
            return
        if dev.address in hits:
            hits[dev.address] = max(hits[dev.address], adv.rssi)
            return
        hits[dev.address] = adv.rssi
        print(f"{GREEN}■ 보드 발견{RESET}  {dev.address}")
        print(f"   iBeacon  major={beacon[1]}  minor={beacon[2]}")
        print(f"   이름     {adv.local_name or dev.name or '(스캔응답 없음)'}")
        print(f"   서비스   {adv.service_uuids or '(스캔응답에 없음)'}")

    print(f"{DIM}{SCAN_SEC:.0f}초 동안 찾는 중…{RESET}")
    scanner = BleakScanner(detection_callback=on_found)
    await scanner.start()
    await asyncio.sleep(SCAN_SEC)
    await scanner.stop()

    print()
    if hits:
        best = max(hits.values())
        print(f"{GREEN}정상 — iBeacon 광고가 나오고 있습니다 (최대 {best} dBm){RESET}")
        print(f"{DIM}아이폰이 반응하지 않는다면 원인은 보드가 아니라 권한 쪽입니다.{RESET}")
    else:
        print(f"{YELLOW}광고가 안 보입니다.{RESET}")
        print("  · 보드에 nu40dk_welcome 펌웨어가 올라가 있는지 (시리얼에 '[welcome]'이 찍히는지)")
        print("  · USB 전원이 들어와 있는지")
        print("  · 맥이 보드에서 너무 멀지 않은지")


if __name__ == "__main__":
    asyncio.run(main())
