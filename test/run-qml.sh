#!/usr/bin/env bash
# Headless smoke test of Panel.qml/Service.qml against stubbed Omarchy + Quickshell
# modules, fed with real status.sh output from the mock server.
# Needs Qt 6 with qmltestrunner (on Debian/Ubuntu: qt6-declarative-dev-tools,
# qml6-module-qtquick{,-controls,-layouts,-templates,-window}, qml6-module-qttest,
# qml6-module-qtqml{,-workerscript}, qt6-qpa-plugins). The stubs are NOT the real
# Omarchy UI kit, so this checks our logic and bindings, not pixel layout.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
RUNNER="$(command -v qmltestrunner || ls /usr/lib/qt6/bin/qmltestrunner 2>/dev/null | head -1)"
[ -n "$RUNNER" ] || { echo "qmltestrunner not found — skipping QML test"; exit 0; }

W="$(mktemp -d)"; trap 'kill $MP 2>/dev/null; rm -rf "$W"' EXIT
python3 test/mock_pve.py --port 18091 & MP=$!
sleep 1
OMAPROX_SCHEME=http OMAPROX_TOKEN='root@pam!omarchy=11111111-2222-3333-4444-555555555555' \
  bash status.sh --host 127.0.0.1 --port 18091 >"$W/out.json"
cp -r test/qml/qs test/qml/Quickshell test/qml/tst_panel.qml "$W/"
ln -s "$ROOT" "$W/plugin"
cd "$W" && QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR="$W" \
  "$RUNNER" -input tst_panel.qml -import "$W" 2>&1 | grep -vE '^QStandardPaths|Unable to assign \[undefined\] to QColor'
exit "${PIPESTATUS[0]}"
