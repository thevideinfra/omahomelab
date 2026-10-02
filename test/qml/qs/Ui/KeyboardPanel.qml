import QtQuick
Item { property Item anchorItem; property var owner; property var bar; property bool open; property Item focusTarget
  property real padding: 14; property real contentWidth: 400; property real contentHeight: 600
  function fittedContentWidth(w) { return w } function fittedContentHeight(h, m) { return Math.min(h, m, 300) }  // short, so the guest list has to scroll
  width: contentWidth; height: contentHeight }
