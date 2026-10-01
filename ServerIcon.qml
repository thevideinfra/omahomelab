import QtQuick

// Three stacked rack units. Drawn with rectangles so it follows the theme colour
// and does not depend on the icon font.
Item {
    id: root

    property real iconSize: 14
    property color color: "white"

    readonly property real unitHeight: Math.max(3, Math.round(iconSize * 0.27))
    readonly property real gap: Math.max(1, Math.round(iconSize * 0.1))

    implicitWidth: iconSize
    implicitHeight: unitHeight * 3 + gap * 2
    width: implicitWidth
    height: implicitHeight

    Repeater {
        model: 3

        Rectangle {
            required property int index

            x: 0
            y: index * (root.unitHeight + root.gap)
            width: root.iconSize
            height: root.unitHeight
            radius: 1.5
            color: "transparent"
            border.width: 1
            border.color: root.color

            Rectangle {
                width: Math.max(1.5, parent.height * 0.3)
                height: width
                radius: width / 2
                color: root.color
                x: parent.width - width * 2.2
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
