#!/bin/bash
# 더블클릭으로 데몬을 켜는 파일. 터미널 명령을 외우지 않아도 되게 둔다.
# 촬영장에서는 이 창이 떠 있어야 맥이 반응한다 — 실수로 닫지 말 것.
cd "$(dirname "$0")"
exec /usr/bin/python3 welcome.py
