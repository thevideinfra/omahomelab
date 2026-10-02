pragma Singleton
import QtQuick
QtObject { property color foreground: "#dddddd"; property color background: "#111111"; property color urgent: "#ff5555"; property color accent: "#55aaff"; property string currentThemePath: Qt.resolvedUrl("../../theme").toString().replace("file://", ""); property QtObject popups: QtObject { property color background: "#111111" } }
