import QtQuick
import Quickshell
Item {
  id: p
  property bool running: false
  property var command: []
  property QtObject stdout; property QtObject stderr
  signal exited(int exitCode)
  onRunningChanged: if (running) {
    Quickshell.procs.push(command)
    var fail = command.join(" ").indexOf("failme") !== -1
    var x = new XMLHttpRequest(); x.open("GET", Qt.resolvedUrl("../../out.json").toString(), false); x.send()
    if (stdout) { stdout.text = x.responseText; stdout.streamFinished() }
    if (stderr) stderr.text = fail ? "boom: could not write" : ""
    running = false
    p.exited(fail ? 1 : 0)
  }
}
