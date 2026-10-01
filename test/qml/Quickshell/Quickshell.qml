pragma Singleton
import QtQuick
QtObject {
  property var execs: []
  property var procs: []
  function execDetached(cmd) { execs.push(cmd) }
}
