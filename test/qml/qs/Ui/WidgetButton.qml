import QtQuick
Item { property var bar; property string text; property string tooltipText; property bool dimmed: false; signal pressed(int button)
  implicitWidth: 40; implicitHeight: 24 }
