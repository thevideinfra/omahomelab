import QtQuick
Rectangle { property bool hasCursor: false; property bool current: false; property bool bordered: false; property color foreground
  color: hasCursor ? "#333333" : (current ? "#222222" : "transparent") }
