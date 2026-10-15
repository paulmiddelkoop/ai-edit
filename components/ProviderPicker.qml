import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: root
  property var providers: []
  property string backend: "agy"
  property string error: ""
  property bool saving: false
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily
  readonly property var provider: providers.filter(function(p) { return p.id === root.backend })[0] || ({ models: [] })
  signal chosen(string backend, string model)
  signal closed()
  spacing: Style.spacing.sm

  function begin(backend, model) {
    root.backend = backend === "agent" ? "claude" : backend
    modelField.text = model || ""
    root.error = ""
    Qt.callLater(function() { modelField.forceActiveFocus(); modelField.selectAll() })
  }

  Row {
    width: parent.width
    spacing: Style.spacing.sm
    Repeater {
      model: root.providers
      delegate: Rectangle {
        required property var modelData
        width: (root.width - 2 * Style.spacing.sm) / 3
        height: Style.space(34)
        radius: Style.cornerRadius
        color: root.backend === modelData.id ? Util.alpha(root.accent, 0.2) : "transparent"
        opacity: modelData.installed ? 1 : 0.4
        Text {
          anchors.centerIn: parent
          text: modelData.label
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        MouseArea {
          anchors.fill: parent
          enabled: modelData.installed && !root.saving
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.backend = modelData.id
            modelField.text = modelData.model
            root.error = ""
            modelField.forceActiveFocus()
            modelField.selectAll()
          }
        }
      }
    }
  }

  Flickable {
    width: parent.width
    height: Math.min(modelList.implicitHeight, Style.space(150))
    contentWidth: width
    contentHeight: modelList.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Column {
      id: modelList
      width: parent.width
      Repeater {
        model: root.provider.models
        delegate: Rectangle {
          required property var modelData
          width: modelList.width
          height: Style.space(32)
          radius: Style.cornerRadius
          color: modelField.text === modelData.id ? Util.alpha(root.accent, 0.12) : "transparent"
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
          MouseArea {
            anchors.fill: parent
            enabled: !root.saving
            cursorShape: Qt.PointingHandCursor
            onClicked: root.chosen(root.backend, modelData.id)
          }
        }
      }
    }
  }

  TextField {
    id: modelField
    width: parent.width
    enabled: !root.saving
    placeholderText: "Model ID"
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (text.trim()) root.chosen(root.backend, text.trim())
        event.accepted = true
      } else if (event.key === Qt.Key_Escape) {
        root.closed()
        event.accepted = true
      } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
        var index = root.providers.map(function(p) { return p.id }).indexOf(root.backend)
        index = (index + (event.key === Qt.Key_Left ? -1 : 1) + root.providers.length) % root.providers.length
        var next = root.providers[index]
        if (next && next.installed) {
          root.backend = next.id
          text = next.model
          selectAll()
        }
        event.accepted = true
      }
    }
  }

  Text {
    width: parent.width
    text: root.error || (root.saving ? "Saving…" : root.providers.length ? "Choose a model, or enter its ID and press Enter. Ctrl+←/→ changes backend." : "Loading models…")
    textFormat: Text.PlainText
    color: root.error ? Color.urgent : root.foreground
    opacity: 0.6
    wrapMode: Text.Wrap
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
