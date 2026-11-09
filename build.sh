#!/usr/bin/env bash
# build.yaml 의 타겟을 Docker(zmk-build-arm) 로 로컬 빌드해 firmware/ 에 .uf2 를 만드는 스크립트
#
# 사용법
#   ./build.sh                 build.yaml 의 모든 타겟 빌드
#   ./build.sh totem_left      지정한 shield 만 빌드 (여러 개 가능)
#   ./build.sh -u              빌드 전에 ZMK·Zephyr 소스를 최신으로 갱신 (west update)
#
# ZMK·Zephyr 소스는 Docker 볼륨(zmk-totem-workspace)에 보관해 두 번째 실행부터 다시 받지 않는다.
# 볼륨을 지우려면 docker volume rm zmk-totem-workspace

set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
IMAGE=zmkfirmware/zmk-build-arm:stable
VOLUME=zmk-totem-workspace
OUT_DIR="$ROOT/firmware"

RUN_TS=$(date +"%Y%m%d_%H%M%S")
SCRIPT_NAME=$(basename "$0" .sh)
LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR" "$OUT_DIR"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}_${RUN_TS}.log"
FAIL_FILE="$LOG_DIR/${SCRIPT_NAME}_${RUN_TS}_fail.log"
touch "$FAIL_FILE"

log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" "$FAIL_FILE"; }

START=$(date +%s)
OK=0; FAIL=0; SKIP=0

summary() {
    log "[종료] 성공=$OK 실패=$FAIL 스킵=$SKIP  소요=$(( $(date +%s) - START ))s"
    log "[로그] $LOG_FILE"
    log "[실패로그] $FAIL_FILE"
}

# 컨테이너 안에서 명령 실행. 출력은 화면과 실행 로그에 함께 남긴다.
in_docker() {
    docker run --rm \
        -v "$VOLUME":/workspace \
        -v "$ROOT":/zmk-config:ro \
        -v "$OUT_DIR":/out \
        -w /workspace \
        "$IMAGE" bash -c "$1" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

UPDATE=0
if [ "${1:-}" = "-u" ]; then UPDATE=1; shift; fi
WANT=("$@")

if ! docker info >/dev/null 2>&1; then
    log_fail "Docker 가 실행 중이 아니다"
    FAIL=1; summary; exit 1
fi

log "[1/3] 이미지 확인 ($IMAGE)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker pull "$IMAGE" 2>&1 | tee -a "$LOG_FILE"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        log_fail "이미지 받기 실패"; FAIL=1; summary; exit 1
    fi
fi

log "[2/3] west 작업 공간 준비 (볼륨 $VOLUME, update=$UPDATE)"
if ! in_docker "
    set -e
    mkdir -p config
    cp /zmk-config/config/west.yml config/west.yml
    [ -d .west ] || west init -l config
    if [ ! -d zmk ] || [ $UPDATE = 1 ]; then west update --fetch-opt=--filter=tree:0; fi
"; then
    log_fail "west 작업 공간 준비 실패"; FAIL=1; summary; exit 1
fi

# build.yaml 의 include 목록을 'board shield snippet' 줄로 바꾼다 (컨테이너의 pyyaml 사용)
TARGETS=$(docker run --rm -v "$ROOT":/zmk-config:ro "$IMAGE" python3 -c "
import yaml
for t in yaml.safe_load(open('/zmk-config/build.yaml'))['include']:
    print(t['board'], t.get('shield', '-'), t.get('snippet', '-'))
")
if [ -z "$TARGETS" ]; then
    log_fail "build.yaml 에서 타겟을 읽지 못했다"; FAIL=1; summary; exit 1
fi

log "[3/3] 빌드"
while read -r board shield snippet; do
    if [ ${#WANT[@]} -gt 0 ] && [[ ! " ${WANT[*]} " =~ " $shield " ]]; then
        SKIP=$((SKIP + 1)); continue
    fi
    snippet_arg=""; [ "$snippet" != "-" ] && snippet_arg="-S $snippet"
    log "빌드 시작: board=$board shield=$shield snippet=$snippet"
    rm -f "$OUT_DIR/$shield.uf2"
    if in_docker "
        set -e
        west zephyr-export >/dev/null
        west build -p -s zmk/app -d build/$shield -b $board $snippet_arg -- \
            -DZMK_CONFIG=/zmk-config/config -DSHIELD=$shield
        cp build/$shield/zephyr/zmk.uf2 /out/$shield.uf2
    "; then
        OK=$((OK + 1)); log "빌드 성공: firmware/$shield.uf2"
    else
        FAIL=$((FAIL + 1)); log_fail "빌드 실패: $shield"
    fi
done <<< "$TARGETS"

summary
[ "$FAIL" -eq 0 ]
