import QtQuick
Item { property var bar; property string text; property string tooltipText; property Component iconComponent; signal pressed(int buttonCode)
  implicitWidth: 30; implicitHeight: 24
  Loader { anchors.centerIn: parent; sourceComponent: parent.iconComponent } }
