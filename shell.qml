import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

FloatingWindow {
  id: win

  title: "Stamp"
  visible: true
  color: palette.bg
  implicitWidth: 560
  implicitHeight: 680
  minimumSize: Qt.size(480, 560)

  onClosed: Qt.quit()

  QtObject {
    id: palette
    property color bg: "#05182e"
    property color bgDeep: "#020c17"
    property color bgRaised: "#0a2540"
    property color fg: "#f6dcac"
    property color muted: "#8cbfb8"
    property color accent: "#faa968"
    property color danger: "#f85525"
    property color line: "#134e5a"
    property color ok: "#8cbfb8"
  }

  property string phase: "idle"
  property string status: ""
  property string imagePath: ""
  property string imageDesc: ""
  property real imageBytes: 0
  property string selectedPath: ""
  property var devices: []
  property string devicesKey: ""
  property bool scanning: false
  property string cancelPath: ""
  property real copiedBytes: 0
  property real elapsedSec: 0
  property string speedText: ""
  property string writePhase: ""
  property string flashError: ""
  property bool ejectAfter: true

  readonly property string scriptPath: Quickshell.shellDir + "/flash.sh"
  readonly property var selected: {
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].path === selectedPath) return devices[i]
    }
    return null
  }
  readonly property bool imageTooBig: selected !== null && imageBytes > 0 && imageBytes > selected.size
  readonly property bool canFlash: imagePath.length > 0 && selected !== null && !imageTooBig && phase !== "checking" && phase !== "flashing"
  readonly property real progress: imageBytes > 0 ? Math.max(0, Math.min(1, copiedBytes / imageBytes)) : 0

  function urlToPath(value) {
    let s = value ? value.toString() : ""
    if (s.startsWith("file://")) s = decodeURIComponent(s.slice(7))
    return s
  }

  function formatBytes(n) {
    n = Number(n) || 0
    const units = ["B", "KiB", "MiB", "GiB", "TiB"]
    let i = 0
    while (n >= 1024 && i < units.length - 1) {
      n /= 1024
      i++
    }
    return (i === 0 ? n.toFixed(0) : n.toFixed(1)) + " " + units[i]
  }

  function formatEta(seconds) {
    seconds = Math.max(0, Math.round(seconds))
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return m + ":" + String(s).padStart(2, "0")
  }

  function applyTheme(text) {
    function pick(key, fallback) {
      const match = text.match(new RegExp("^" + key + "\\s*=\\s*\"(#[0-9A-Fa-f]{6})\"", "m"))
      return match ? match[1] : fallback
    }
    palette.bg = pick("background", palette.bg)
    palette.bgDeep = pick("darker_background", palette.bgDeep)
    palette.bgRaised = pick("lighter_background", palette.bgRaised)
    palette.fg = pick("foreground", palette.fg)
    palette.muted = pick("cyan", palette.muted)
    palette.accent = pick("accent", palette.accent)
    palette.danger = pick("red", palette.danger)
    palette.line = pick("selection", palette.line)
    palette.ok = pick("cyan", palette.ok)
  }

  function refreshDevices() {
    if (phase === "flashing" || phase === "checking" || scanProc.running) return
    scanning = true
    scanProc.running = true
  }

  function applyDevices(text) {
    scanning = false
    let parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      status = "Could not read the disk list."
      return
    }
    const found = []
    const disks = (parsed && parsed.blockdevices) || []
    for (let i = 0; i < disks.length; i++) {
      const disk = disks[i]
      if (!disk || disk.type !== "disk" || disk.tran !== "usb" || disk.ro) continue
      const mounts = collectMounts(disk, [])
      if (mounts.some(isSystemMount)) continue
      const title = [disk.vendor, disk.model].map(clean).filter(Boolean).join(" ") || "USB disk"
      found.push({
        path: disk.path,
        name: disk.name,
        size: Number(disk.size) || 0,
        sizeLabel: formatBytes(disk.size),
        title: title,
        mounts: mounts.join(", ")
      })
    }
    const key = JSON.stringify(found)
    if (key !== devicesKey) {
      devices = found
      devicesKey = key
    }
    if (selectedPath && !found.some(d => d.path === selectedPath)) selectedPath = ""
  }

  function collectMounts(node, acc) {
    const mounts = node.mountpoints || []
    for (let i = 0; i < mounts.length; i++) {
      if (mounts[i]) acc.push(mounts[i])
    }
    const children = node.children || []
    for (let i = 0; i < children.length; i++) collectMounts(children[i], acc)
    return acc
  }

  function isSystemMount(mp) {
    return mp === "/" || mp === "/boot" || mp === "/efi" || mp === "/boot/efi" || mp === "/home"
  }

  function clean(value) {
    return String(value || "").replace(/\s+/g, " ").trim()
  }

  function setImage(fileUrl) {
    const path = urlToPath(fileUrl)
    if (!path || path.indexOf("\n") !== -1) return
    imagePath = path
    imageBytes = 0
    imageDesc = ""
    if (phase === "error" || phase === "done") {
      phase = "idle"
      status = ""
    }
    imageProc.exec(["bash", "-c", "stat -c %s -- \"$1\"; file -b -- \"$1\"", "isoflash", path])
  }

  function onImageInfo(text) {
    const lines = text.replace(/\s+$/, "").split("\n")
    imageBytes = Number(lines[0]) || 0
    imageDesc = lines.slice(1).join(" ")
  }

  function openConfirm() {
    if (!canFlash) return
    confirmField.text = ""
    flashError = ""
    status = ""
    phase = "confirm"
  }

  function startCheck() {
    if (!selected || confirmField.text !== selected.name) return
    if (imagePath.length === 0 || imageTooBig) return
    flashError = ""
    status = "Checking the stick…"
    phase = "checking"
    checkProc.exec([scriptPath, "--check", imagePath, selected.path])
  }

  function startWrite() {
    if (!selected || confirmField.text !== selected.name) {
      phase = "error"
      status = "Confirmation did not match the device."
      return
    }
    phase = "flashing"
    writePhase = "prepare"
    copiedBytes = 0
    elapsedSec = 0
    speedText = ""
    flashError = ""
    status = "Waiting for authorization…"
    cancelPath = "/tmp/isoflash-" + Quickshell.processId + "-" + Date.now() + ".cancel"
    prepProc.exec(["bash", "-c", "set -C; : > \"$1\"", "isoflash", cancelPath])
  }

  function launchWrite() {
    const args = ["pkexec", "/usr/bin/stdbuf", "-oL", "-eL", "/usr/bin/bash", scriptPath, imagePath, selected.path, "--cancel", cancelPath]
    if (ejectAfter) args.push("--eject")
    flashProc.exec(args)
  }

  function cancelWrite() {
    if (phase !== "flashing" || !cancelPath) return
    status = "Cancelling…"
    cancelProc.exec(["bash", "-c", "printf '%s\n' 1 > \"$1\"", "isoflash", cancelPath])
  }

  function onFlashLine(line) {
    line = String(line || "").trim()
    if (!line) return
    if (line.startsWith("error:")) {
      flashError = line.slice(6).trim()
      return
    }
    if (line.startsWith("warn:")) {
      status = line.slice(5).trim()
      return
    }
    if (line.startsWith("progress ")) {
      const parts = line.split(" ")
      copiedBytes = Number(parts[1]) || copiedBytes
      elapsedSec = Number(parts[2]) || elapsedSec
      speedText = parts.slice(3).join(" ")
      status = ""
      return
    }
    if (line === "phase unmount") {
      writePhase = "unmount"
      status = "Unmounting the stick…"
    } else if (line === "phase write") {
      writePhase = "write"
      status = "Writing…"
    } else if (line === "phase sync") {
      writePhase = "sync"
      status = "Syncing. Leave the stick plugged in."
    } else if (line === "phase eject") {
      writePhase = "eject"
      status = "Powering off the stick…"
    } else if (line === "done") {
      writePhase = "done"
      status = ejectAfter ? "Write finished. The stick can be unplugged." : "Write finished. Wait a moment, then unplug the stick."
    } else if (line.startsWith("ok ")) {
      const parts = line.split(" ")
      imageBytes = Number(parts[1]) || imageBytes
    }
  }

  function finishFlash(code) {
    if (code === 0 || writePhase === "done") {
      phase = "done"
      if (!status) status = "Write finished."
      refreshDevices()
      return
    }
    phase = "error"
    if (flashError) status = flashError
    else if (code === 126 || code === 127) status = "Authorization was denied."
    else status = "Write failed (exit " + code + ")."
  }

  Process {
    id: themeProc
    command: ["cat", Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: win.applyTheme(text)
    }
  }

  Process {
    id: scanProc
    command: ["lsblk", "-J", "-b", "-o", "NAME,PATH,SIZE,MODEL,TRAN,TYPE,MOUNTPOINTS,VENDOR,RO"]
    stdout: StdioCollector {
      onStreamFinished: win.applyDevices(text)
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text && text.trim().length > 0) win.status = text.trim()
      }
    }
    onExited: code => {
      win.scanning = false
      if (code !== 0) win.status = "Could not list disks."
    }
  }

  Process {
    id: imageProc
    stdout: StdioCollector {
      onStreamFinished: win.onImageInfo(text)
    }
  }

  Process {
    id: checkProc
    stdout: SplitParser {
      onRead: data => win.onFlashLine(data)
    }
    stderr: SplitParser {
      onRead: data => win.onFlashLine(data)
    }
    onExited: code => {
      if (code === 0) win.startWrite()
      else {
        win.phase = "error"
        win.status = win.flashError || "The image cannot be written to that stick."
      }
    }
  }

  Process {
    id: prepProc
    onExited: code => {
      if (code === 0) win.launchWrite()
      else {
        win.phase = "error"
        win.status = "Could not prepare the write."
      }
    }
  }

  Process {
    id: flashProc
    stdout: SplitParser {
      onRead: data => win.onFlashLine(data)
    }
    stderr: SplitParser {
      onRead: data => win.onFlashLine(data)
    }
    onExited: code => win.finishFlash(code)
  }

  Process { id: cancelProc }

  FileDialog {
    id: picker
    title: "Choose a disk image"
    fileMode: FileDialog.OpenFile
    nameFilters: ["Disk images (*.iso *.img *.ISO *.IMG)", "All files (*)"]
    currentFolder: "file://" + StandardPaths.writableLocation(StandardPaths.HomeLocation)
    onAccepted: win.setImage(selectedFile)
  }

  Timer {
    interval: 3000
    repeat: true
    running: win.phase !== "flashing" && win.phase !== "checking" && win.phase !== "confirm"
    triggeredOnStart: true
    onTriggered: win.refreshDevices()
  }

  Item {
    anchors.fill: parent

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: 22
      spacing: 14

      ColumnLayout {
        spacing: 4
        Layout.fillWidth: true

        Text {
          text: "Stamp"
          color: palette.fg
          font.family: "Adwaita Sans"
          font.pixelSize: 22
          font.weight: Font.DemiBold
        }
        Text {
          Layout.fillWidth: true
          text: "Write a disk image to a USB stick. The whole stick is erased. Internal disks are not listed."
          wrapMode: Text.WordWrap
          color: palette.muted
          font.family: "Adwaita Sans"
          font.pixelSize: 13
        }
      }

      ColumnLayout {
        spacing: 8
        Layout.fillWidth: true

        Text {
          text: "Image"
          color: palette.fg
          font.family: "Adwaita Sans"
          font.pixelSize: 13
          font.weight: Font.Medium
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            radius: 8
            color: palette.bgDeep
            border.color: palette.line
            border.width: 1

            Text {
              anchors.fill: parent
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideMiddle
              text: win.imagePath || "No image selected"
              color: win.imagePath ? palette.fg : palette.muted
              font.family: "JetBrainsMono Nerd Font"
              font.pixelSize: 12
            }
          }

          ActionButton {
            colors: palette
            text: "Browse"
            enabled: win.phase !== "flashing" && win.phase !== "checking"
            onClicked: picker.open()
          }
        }

        Text {
          Layout.fillWidth: true
          visible: win.imagePath.length > 0
          text: (win.imageBytes > 0 ? win.formatBytes(win.imageBytes) + "  ·  " : "") + (win.imageDesc || "Reading image…")
          color: palette.muted
          wrapMode: Text.WordWrap
          font.family: "Adwaita Sans"
          font.pixelSize: 12
        }
      }

      ColumnLayout {
        spacing: 8
        Layout.fillWidth: true
        Layout.fillHeight: true

        RowLayout {
          Layout.fillWidth: true
          Text {
            text: "USB stick"
            color: palette.fg
            font.family: "Adwaita Sans"
            font.pixelSize: 13
            font.weight: Font.Medium
            Layout.fillWidth: true
          }
          ActionButton {
            colors: palette
            text: win.scanning ? "Scanning" : "Refresh"
            enabled: win.phase !== "flashing" && win.phase !== "checking"
            onClicked: win.refreshDevices()
          }
        }

        Flickable {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.minimumHeight: 140
          contentHeight: deviceCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: deviceCol
            width: parent.width
            spacing: 8

            Text {
              width: parent.width
              visible: win.devices.length === 0
              text: win.scanning ? "Looking for USB sticks…" : "No USB sticks found. Plug one in, then refresh."
              color: palette.muted
              wrapMode: Text.WordWrap
              font.family: "Adwaita Sans"
              font.pixelSize: 13
            }

            Repeater {
              model: win.devices
              delegate: Rectangle {
                required property var modelData
                width: deviceCol.width
                height: mountText.visible ? 72 : 56
                radius: 8
                color: win.selectedPath === modelData.path ? palette.bgRaised : palette.bgDeep
                border.color: win.selectedPath === modelData.path ? palette.accent : palette.line
                border.width: win.selectedPath === modelData.path ? 2 : 1

                Column {
                  anchors.fill: parent
                  anchors.margins: 10
                  spacing: 2

                  Text {
                    width: parent.width
                    text: modelData.title + "   " + modelData.sizeLabel
                    color: palette.fg
                    elide: Text.ElideRight
                    font.family: "Adwaita Sans"
                    font.pixelSize: 14
                    font.weight: Font.Medium
                  }
                  Text {
                    width: parent.width
                    text: modelData.path
                    color: palette.accent
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 12
                  }
                  Text {
                    id: mountText
                    width: parent.width
                    visible: modelData.mounts.length > 0
                    text: "Mounted at " + modelData.mounts + ". It will be unmounted."
                    color: palette.muted
                    elide: Text.ElideRight
                    font.family: "Adwaita Sans"
                    font.pixelSize: 12
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: win.phase !== "flashing" && win.phase !== "checking"
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    win.selectedPath = modelData.path
                    if (win.phase === "error" || win.phase === "done" || win.phase === "confirm") {
                      win.phase = "idle"
                      win.status = ""
                    }
                  }
                }
              }
            }
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Rectangle {
          width: 18
          height: 18
          radius: 4
          color: win.ejectAfter ? palette.accent : "transparent"
          border.color: win.ejectAfter ? palette.accent : palette.muted
          border.width: 1

          Text {
            anchors.centerIn: parent
            visible: win.ejectAfter
            text: "✓"
            color: palette.bgDeep
            font.pixelSize: 12
            font.weight: Font.Bold
          }

          MouseArea {
            anchors.fill: parent
            enabled: win.phase !== "flashing"
            cursorShape: Qt.PointingHandCursor
            onClicked: win.ejectAfter = !win.ejectAfter
          }
        }

        Text {
          Layout.fillWidth: true
          text: "Power off the stick when the write finishes"
          color: palette.fg
          font.family: "Adwaita Sans"
          font.pixelSize: 13
          MouseArea {
            anchors.fill: parent
            enabled: win.phase !== "flashing"
            cursorShape: Qt.PointingHandCursor
            onClicked: win.ejectAfter = !win.ejectAfter
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: win.imageTooBig
        wrapMode: Text.WordWrap
        text: "The image is larger than the selected stick."
        color: palette.danger
        font.family: "Adwaita Sans"
        font.pixelSize: 13
      }

      Rectangle {
        visible: win.phase === "flashing" || win.phase === "done"
        Layout.fillWidth: true
        Layout.preferredHeight: 10
        radius: 5
        color: palette.bgDeep

        Rectangle {
          width: parent.width * (win.phase === "done" ? 1 : win.progress)
          height: parent.height
          radius: 5
          color: win.phase === "error" ? palette.danger : palette.accent
        }
      }

      Text {
        Layout.fillWidth: true
        visible: (win.phase === "flashing" && win.writePhase === "write") || win.phase === "done"
        text: {
          if (win.phase === "done") return win.formatBytes(win.imageBytes)
          const eta = win.copiedBytes > 0 && win.elapsedSec > 0
              ? "  ·  " + win.formatEta((win.imageBytes - win.copiedBytes) / (win.copiedBytes / win.elapsedSec)) + " left"
              : ""
          return Math.round(win.progress * 100) + "%   " + win.formatBytes(win.copiedBytes)
              + " of " + win.formatBytes(win.imageBytes)
              + (win.speedText ? "   ·   " + win.speedText : "")
              + eta
        }
        color: palette.muted
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 12
      }

      Text {
        Layout.fillWidth: true
        visible: win.status.length > 0
        wrapMode: Text.WordWrap
        text: win.status
        color: win.phase === "error" ? palette.danger : palette.fg
        font.family: "Adwaita Sans"
        font.pixelSize: 13
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignRight
        spacing: 8

        ActionButton {
          colors: palette
          text: "Cancel"
          visible: win.phase === "flashing" && win.writePhase !== "sync" && win.writePhase !== "eject" && win.writePhase !== "done"
          danger: true
          onClicked: win.cancelWrite()
        }

        ActionButton {
          colors: palette
          text: win.phase === "checking" ? "Checking…" : (win.selected ? "Flash to " + win.selected.name : "Flash")
          filled: true
          enabled: win.canFlash
          onClicked: win.openConfirm()
        }
      }
    }

    Rectangle {
      anchors.fill: parent
      visible: win.phase === "confirm"
      color: Qt.rgba(0, 0, 0, 0.45)
      onVisibleChanged: if (visible) confirmField.forceActiveFocus()

      MouseArea { anchors.fill: parent }

      Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 460)
        height: confirmCol.implicitHeight + 36
        radius: 12
        color: palette.bg
        border.color: palette.line

        ColumnLayout {
          id: confirmCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 18
          spacing: 10

          Text {
            Layout.fillWidth: true
            text: "Erase " + (win.selected ? win.selected.path : "") + "?"
            color: palette.fg
            wrapMode: Text.WordWrap
            font.family: "Adwaita Sans"
            font.pixelSize: 18
            font.weight: Font.DemiBold
          }
          Text {
            Layout.fillWidth: true
            text: win.selected
                ? win.selected.title + "  ·  " + win.selected.sizeLabel + "\nEverything on this stick will be deleted."
                : ""
            color: palette.muted
            wrapMode: Text.WordWrap
            font.family: "Adwaita Sans"
            font.pixelSize: 13
          }
          Text {
            Layout.fillWidth: true
            text: "Type " + (win.selected ? win.selected.name : "") + " to confirm."
            color: palette.fg
            font.family: "Adwaita Sans"
            font.pixelSize: 13
          }
          TextField {
            id: confirmField
            Layout.fillWidth: true
            placeholderText: win.selected ? win.selected.name : ""
            color: palette.fg
            placeholderTextColor: palette.muted
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 14
            selectByMouse: true
            background: Rectangle {
              radius: 8
              color: palette.bgDeep
              border.color: confirmField.activeFocus ? palette.accent : palette.line
            }
            Keys.onReturnPressed: if (win.selected && text === win.selected.name) win.startCheck()
          }
          RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 8
            ActionButton {
              colors: palette
              text: "Back"
              onClicked: win.phase = "idle"
            }
            ActionButton {
              colors: palette
              text: "Erase and write"
              filled: true
              danger: true
              enabled: win.selected !== null && confirmField.text === win.selected.name
              onClicked: win.startCheck()
            }
          }
        }
      }
    }
  }

}
