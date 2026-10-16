import QtQuick

// Covers a TextEdit so it never reads the clipboard itself: Qt's middle-click
// paste and drop read it inside the shell, synchronously and with no limit on
// size or time. A middle click is handed on as primaryPaste, a drop is taken
// and ignored.
Item {
  id: root

  signal primaryPaste(real x, real y)

  anchors.fill: parent

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.MiddleButton
    onClicked: function(mouse) { root.primaryPaste(mouse.x, mouse.y) }
  }

  DropArea {
    anchors.fill: parent
    onDropped: function(drop) { drop.accept(Qt.IgnoreAction) }
  }
}
