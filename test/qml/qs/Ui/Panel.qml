import QtQuick
Item {
  property string moduleName; property string ipcTarget; property bool manageIpc
  property var bar: null; property var settings: ({}); property bool opened: false
  property color barForeground: "#dddddd"
  function setting(name, fallback) { var v = settings ? settings[name] : undefined; return v === undefined || v === null ? fallback : v }
  function open() { opened = true } function close() { opened = false } function toggle() { opened = !opened }
  function switchPanel(d) {}
}
