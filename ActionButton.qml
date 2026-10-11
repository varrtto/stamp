import QtQuick
import QtQuick.Layouts

Rectangle {
  id: button

  required property QtObject colors
  property string text: ""
  property bool filled: false
  property bool danger: false
  signal clicked()

  Layout.preferredWidth: label.implicitWidth + 28
  Layout.preferredHeight: 36
  radius: 8
  opacity: enabled ? 1 : 0.4
  color: !enabled ? colors.bgRaised
       : filled && danger ? colors.danger
       : filled ? colors.accent
       : (area.containsMouse ? colors.bgRaised : "transparent")
  border.color: danger ? colors.danger : (filled ? "transparent" : colors.line)
  border.width: filled ? 0 : 1

  Text {
    id: label
    anchors.centerIn: parent
    text: button.text
    color: button.filled ? button.colors.bgDeep : (button.danger ? button.colors.danger : button.colors.fg)
    font.family: "Adwaita Sans"
    font.pixelSize: 13
    font.weight: Font.Medium
  }

  MouseArea {
    id: area
    anchors.fill: parent
    enabled: button.enabled
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: button.clicked()
  }
}
