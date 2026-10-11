import QtQuick
import Qt5Compat.GraphicalEffects

Item {
  id: root

  property url source
  property color color: "white"

  implicitWidth: 20
  implicitHeight: 20

  Image {
    id: image
    anchors.fill: parent
    source: root.source
    visible: false
    fillMode: Image.PreserveAspectFit
    smooth: true
    sourceSize: Qt.size(Math.max(1, root.width * 2), Math.max(1, root.height * 2))
  }

  ColorOverlay {
    anchors.fill: parent
    source: image
    color: root.color
  }
}
