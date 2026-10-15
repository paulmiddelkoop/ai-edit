import QtQuick
import qs.Commons
import qs.Ui

BorderSurface {
  id: root

  property string key: ""
  property string label: ""
  property bool direct: false
  property bool selected: false
  property color foreground: Color.foreground
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var selectedBorderSpec: Border.none()
  property string fontFamily: Style.font.menuFamily

  readonly property color textColor: selected ? selectedText : foreground

  signal activated(bool shift)
  signal pointed(point scenePosition)

  radius: Style.cornerRadius
  color: selected ? selectedBackground : "transparent"
  borderSpec: selected ? selectedBorderSpec : Border.none()

  // As in Omarchy's keybindings menu (Super+K): "key → action", in its
  // monospace font, so every label starts in the same column.
  Text {
    anchors.left: parent.left
    anchors.leftMargin: Border.left(root.selectedBorderSpec) + Style.space(18)
    anchors.right: trail.left
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: (root.key || " ") + " → " + root.label
    color: root.textColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.weight: Font.Medium
    elide: Text.ElideRight
  }

  Text {
    id: trail
    width: Style.space(14)
    anchors.right: parent.right
    anchors.rightMargin: Border.right(root.selectedBorderSpec) + Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.direct ? "↵" : ""
    color: root.textColor
    opacity: 0.36
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: function(mouse) { root.pointed(mapToItem(null, mouse.x, mouse.y)) }
    onClicked: function(mouse) { root.activated((mouse.modifiers & Qt.ShiftModifier) !== 0) }
  }
}
