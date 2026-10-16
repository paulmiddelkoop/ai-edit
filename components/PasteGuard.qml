import QtQuick

// Covers a TextEdit so a middle click never pastes through Qt, which reads the
// primary selection inside the shell, synchronously and with no limit on size
// or time; the click is handed on as primaryPaste.
Item {
  id: root

  signal primaryPaste(real x, real y)

  anchors.fill: parent

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.MiddleButton
    onClicked: function(mouse) { root.primaryPaste(mouse.x, mouse.y) }
  }
}
