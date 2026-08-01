#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Запуск «The Boat» одной командой.
#
# Игра — это ПРОЕКТ движка, а не самостоятельная программа: чтобы в неё
# поиграть, нужен собранный SAGE Engine. Скрипт находит его рядом, клонирует и
# собирает, если не нашёл, и запускает игру, редактор или headless-проверку.
#
#   ./tools/run.sh              играть
#   ./tools/run.sh --editor     открыть проект в редакторе SAGE
#   ./tools/run.sh --check      автопрогон без окна (то же, что гоняет CI)
#   ./tools/run.sh --seed=7     любые параметры игры уходят дальше как есть
#
# Где искать движок: $SAGE_ENGINE, затем ../SAGE-Engine, затем клон в ./.engine.
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_REPO="https://github.com/AmckinatorStudios/SAGE-Engine.git"

MODE="play"
GAME_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --editor) MODE="editor" ;;
        --check)  MODE="check" ;;
        *)        GAME_ARGS+=("$arg") ;;
    esac
done

# --- Найти движок ----------------------------------------------------------
find_engine() {
    if [[ -n "${SAGE_ENGINE:-}" && -f "${SAGE_ENGINE}/CMakeLists.txt" ]]; then
        echo "${SAGE_ENGINE}"; return
    fi
    if [[ -f "${PROJECT_DIR}/../SAGE-Engine/CMakeLists.txt" ]]; then
        (cd "${PROJECT_DIR}/../SAGE-Engine" && pwd); return
    fi
    if [[ -f "${PROJECT_DIR}/.engine/CMakeLists.txt" ]]; then
        echo "${PROJECT_DIR}/.engine"; return
    fi
    echo ""
}

ENGINE_DIR="$(find_engine)"
if [[ -z "${ENGINE_DIR}" ]]; then
    echo "SAGE Engine не найден — клонирую в ${PROJECT_DIR}/.engine"
    git clone --depth 1 "${ENGINE_REPO}" "${PROJECT_DIR}/.engine"
    ENGINE_DIR="${PROJECT_DIR}/.engine"
fi

BUILD_DIR="${ENGINE_DIR}/build"
PLAYER="${BUILD_DIR}/runtime/SagePlayer"
EDITOR="${BUILD_DIR}/editor/SageEditor"

# --- Собрать движок, если нужного бинарника ещё нет -------------------------
need_binary="${PLAYER}"
[[ "${MODE}" != "play" ]] && need_binary="${EDITOR}"
if [[ ! -x "${need_binary}" ]]; then
    echo "Собираю SAGE Engine в ${BUILD_DIR} (первый раз это долго)..."
    cmake -S "${ENGINE_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
    cmake --build "${BUILD_DIR}" -j"$(nproc 2>/dev/null || echo 4)"
fi

# --- Запуск ----------------------------------------------------------------
case "${MODE}" in
    play)
        exec "${PLAYER}" "${PROJECT_DIR}" "${GAME_ARGS[@]:-}"
        ;;
    editor)
        # Редактор ищет проекты через свой launcher; открываем сразу нужный.
        cd "$(dirname "${EDITOR}")"
        exec ./SageEditor
        ;;
    check)
        # Тот же прогон, что в CI: редактор открывает проект, играет автопилотом
        # фиксированным шагом и собирает игру в exe. Без окна (xvfb, если есть).
        RUNNER=""
        command -v xvfb-run >/dev/null 2>&1 && RUNNER="xvfb-run -a"
        log="$(mktemp)"
        (cd "$(dirname "${EDITOR}")" && \
         ${RUNNER} env \
            SAGE_EDITOR_OPEN_PROJECT="${PROJECT_DIR}" \
            SAGE_EDITOR_PLAY_SECONDS=240 \
            SAGE_EDITOR_BUILD_TO=theboat_dist \
            SAGE_GAME_ARGS="autopilot=1 ${GAME_ARGS[*]:-}" \
            SAGE_SCREENSHOT_AT_FRAME=5 SAGE_SCREENSHOT_PATH=/dev/null \
            ./SageEditor) > "${log}" 2>&1 || true
        grep -E "THEBOAT|SESSION" "${log}" || true
        if grep -q "THEBOAT: ROUTINE OK" "${log}" && grep -q "SESSION: PASS" "${log}"; then
            echo "OK: автопилот прожил день на лодке, игра собрана в exe"
        else
            echo "ОШИБКА: автопрогон не дошёл до конца — полный лог в ${log}"
            exit 1
        fi
        ;;
esac
