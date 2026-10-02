import QtQuick
Item {
  property string path; property bool printErrors; property bool watchChanges
  signal loaded(); signal loadFailed(var error); signal fileChanged()
  function reload() { loaded() }
  function text() { var x = new XMLHttpRequest(); x.open("GET", "file://" + path, false); x.send(); return x.responseText }
  Component.onCompleted: loaded()
}
