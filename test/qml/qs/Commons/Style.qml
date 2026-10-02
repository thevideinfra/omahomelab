pragma Singleton
import QtQuick
QtObject {
  property real cornerRadius: 6
  property real gapsOut: 8
  function space(px) { return px }
  property QtObject font: QtObject { property string family: "monospace"; property int caption: 10; property int bodySmall: 11; property int body: 12; property int subtitle: 13; property int title: 14; property int heading: 16; property int display: 24; property int icon: 14 }
  property QtObject spacing: QtObject { property real rowPaddingX: 10; property real labelGap: 4; property real popupPadding: 14 }
}
