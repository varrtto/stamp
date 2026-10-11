import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

FloatingWindow {
  id: win

  title: "Stamp"
  visible: true
  color: theme.bg
  implicitWidth: 960
  implicitHeight: 480
  // A tall minimum makes Hyprland scale the whole workspace down when this
  // window is tiled with others on a short screen.
  minimumSize: Qt.size(160, 120)

  onClosed: Qt.quit()

  QtObject {
    id: theme
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
  property bool hasScanned: false
  property string cancelPath: ""
  property string rememberedPath: ""
  property real rememberedSize: 0
  property real copiedBytes: 0
  property real elapsedSec: 0
  property string speedText: ""
  property string writePhase: ""
  property string flashError: ""
  property bool ejectAfter: true
  property bool pickingDrive: false

  readonly property string scriptPath: Quickshell.shellDir + "/flash.sh"
  readonly property var selected: {
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].path === selectedPath) return devices[i]
    }
    return null
  }
  readonly property bool imageTooBig: selected !== null && imageBytes > 0 && selected.size > 0 && imageBytes > selected.size
  readonly property bool canFlash: imagePath.length > 0 && selected !== null && selected.size > 0 && !imageTooBig && phase !== "checking" && phase !== "flashing"
  readonly property real progress: imageBytes > 0 ? Math.max(0, Math.min(1, copiedBytes / imageBytes)) : 0
  readonly property bool showProgress: phase === "flashing" || (phase === "done" && selected !== null)
  readonly property bool canCancel: phase === "flashing" && writePhase !== "sync" && writePhase !== "eject" && writePhase !== "done"
  readonly property string progressDetail: {
    if (phase === "done" && selected !== null) return formatBytes(imageBytes)
    if (!(phase === "flashing" && writePhase === "write")) return ""
    const eta = copiedBytes > 0 && elapsedSec > 0
        ? "  ·  " + formatEta((imageBytes - copiedBytes) / (copiedBytes / elapsedSec)) + " left"
        : ""
    return Math.round(progress * 100) + "%   " + formatBytes(copiedBytes)
        + " of " + formatBytes(imageBytes)
        + (speedText ? "   ·   " + speedText : "")
        + eta
  }
  readonly property string footerText: {
    if (status.length > 0) return status
    if (imageTooBig) return "The image is larger than the selected stick."
    return progressDetail
  }

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
    theme.bg = pick("background", theme.bg)
    theme.bgDeep = pick("darker_background", theme.bgDeep)
    theme.bgRaised = pick("lighter_background", theme.bgRaised)
    theme.fg = pick("foreground", theme.fg)
    theme.muted = pick("cyan", theme.muted)
    theme.accent = pick("accent", theme.accent)
    theme.danger = pick("red", theme.danger)
    theme.line = pick("selection", theme.line)
    theme.ok = pick("cyan", theme.ok)
  }

  function refreshDevices() {
    if (phase === "flashing" || phase === "checking" || scanProc.running) return
    scanProc.running = true
  }

  function applyDevices(text) {
    hasScanned = true
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
      // Powering the stick off leaves the device node in place with a size of 0.
      let size = Number(disk.size) || 0
      if (!(size > 0)) {
        for (let j = 0; j < devices.length; j++) {
          if (devices[j].path === disk.path && devices[j].size > 0) {
            size = devices[j].size
            break
          }
        }
      }
      if (!(size > 0) && disk.path === rememberedPath && rememberedSize > 0) size = rememberedSize
      found.push({
        path: disk.path,
        name: disk.name,
        size: size,
        sizeLabel: formatBytes(size),
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

  function baseName(path) {
    const slash = String(path || "").lastIndexOf("/")
    return slash >= 0 ? path.slice(slash + 1) : path
  }

  function browse() {
    if (phase === "flashing" || phase === "checking" || pickerProc.running) return
    pickingDrive = false
    let start = imagePath
    if (start.length > 0) {
      const slash = start.lastIndexOf("/")
      start = slash > 0 ? start.slice(0, slash) : "/"
    } else {
      start = urlToPath(StandardPaths.writableLocation(StandardPaths.HomeLocation))
    }
    if (!start || start.length === 0) start = "/"
    if (!start.endsWith("/")) start += "/"
    pickerProc.exec([
      "zenity", "--file-selection",
      "--title=Choose a disk image",
      "--filename=" + start,
      "--file-filter=Disk images | *.iso *.img *.ISO *.IMG",
      "--file-filter=All files | *",
      "--width=960",
      "--height=520"
    ])
  }

  function chooseDrive() {
    if (phase === "flashing" || phase === "checking") return
    if (devices.length === 0) {
      status = hasScanned ? "No USB sticks found. Plug one in." : "Looking for USB sticks…"
      return
    }
    if (devices.length === 1) {
      selectDrive(devices[0].path)
      return
    }
    pickingDrive = true
  }

  function selectDrive(path) {
    selectedPath = path
    pickingDrive = false
    if (phase === "error" || phase === "done") {
      phase = "idle"
      status = ""
    }
  }

  function burn() {
    if (phase === "flashing" || phase === "checking") return
    pickingDrive = false
    if (!canFlash) {
      if (imagePath.length === 0) status = "Choose an image first."
      else if (selected === null) status = "Choose a USB stick first."
      else if (imageTooBig) status = "The image is larger than the selected stick."
      return
    }
    flashError = ""
    status = "Checking the stick…"
    phase = "checking"
    checkProc.exec([scriptPath, "--check", imagePath, selected.path])
  }

  function startWrite() {
    if (!selected) {
      phase = "error"
      status = "The stick disappeared."
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
      const devBytes = Number(parts[2]) || 0
      if (devBytes > 0 && selected) {
        rememberedPath = selected.path
        rememberedSize = devBytes
      }
    }
  }

  function finishFlash(code) {
    if (code === 0 || writePhase === "done") {
      phase = "done"
      if (!status) status = "Write finished."
      if (!doneSound.running) doneSound.running = true
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
      win.hasScanned = true
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

  Process {
    id: doneSound
    command: ["canberra-gtk-play", "-i", "complete"]
  }

  Process {
    id: pickerProc
    stdout: StdioCollector {
      onStreamFinished: {
        const path = text.replace(/\s+$/, "")
        if (path) win.setImage(path)
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: win.phase !== "flashing" && win.phase !== "checking"
    triggeredOnStart: true
    onTriggered: win.refreshDevices()
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 18
    spacing: 12

    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 10

      Rectangle {
        id: imageStep
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: 18
        color: imageHover.containsMouse && imageHover.enabled ? theme.bgRaised : "transparent"
        border.color: win.imagePath.length > 0 ? theme.accent : theme.line
        border.width: 1

        StepIcon {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -22
          width: Math.min(imageStep.width, imageStep.height - 64) * 0.86
          height: width
          source: Qt.resolvedUrl("icons/disc.svg")
          color: win.imagePath.length > 0 ? theme.accent : theme.muted
        }

        Text {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: 16
          horizontalAlignment: Text.AlignHCenter
          text: win.imagePath.length > 0
              ? win.baseName(win.imagePath) + (win.imageBytes > 0 ? "\n" + win.formatBytes(win.imageBytes) : "")
              : "Choose an image"
          color: win.imagePath.length > 0 ? theme.fg : theme.muted
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          font.family: "Adwaita Sans"
          font.pixelSize: 14
          font.weight: Font.Medium
        }

        MouseArea {
          id: imageHover
          anchors.fill: parent
          hoverEnabled: true
          enabled: win.phase !== "flashing" && win.phase !== "checking"
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: win.browse()
        }
      }

      Rectangle {
        id: driveStep
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: 18
        color: driveHover.containsMouse && driveHover.enabled && !win.pickingDrive ? theme.bgRaised : "transparent"
        border.color: win.selected !== null ? theme.accent : theme.line
        border.width: 1

        StepIcon {
          visible: !win.pickingDrive
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -22
          width: Math.min(driveStep.width, driveStep.height - 64) * 0.86
          height: width
          source: Qt.resolvedUrl("icons/usb.svg")
          color: win.selected !== null ? theme.accent : theme.muted
        }

        Text {
          visible: !win.pickingDrive
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: 16
          horizontalAlignment: Text.AlignHCenter
          text: win.selected
              ? win.selected.title + "\n" + win.selected.sizeLabel
              : (win.devices.length === 0 ? "Plug in a stick" : "Choose a stick")
          color: win.selected !== null ? theme.fg : theme.muted
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          font.family: "Adwaita Sans"
          font.pixelSize: 14
          font.weight: Font.Medium
        }

        MouseArea {
          id: driveHover
          anchors.fill: parent
          hoverEnabled: true
          visible: !win.pickingDrive
          enabled: win.phase !== "flashing" && win.phase !== "checking"
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: win.chooseDrive()
        }

        ListView {
          anchors.fill: parent
          anchors.margins: 12
          visible: win.pickingDrive
          clip: true
          spacing: 8
          boundsBehavior: Flickable.StopAtBounds
          model: win.devices

          delegate: Rectangle {
            required property var modelData
            width: ListView.view.width
            height: modelData.mounts.length > 0 ? 72 : 56
            radius: 10
            color: theme.bgDeep
            border.color: theme.line

            Column {
              anchors.fill: parent
              anchors.margins: 10
              spacing: 2

              Text {
                width: parent.width
                text: modelData.title + "   " + modelData.sizeLabel
                color: theme.fg
                elide: Text.ElideRight
                font.family: "Adwaita Sans"
                font.pixelSize: 14
                font.weight: Font.Medium
              }
              Text {
                width: parent.width
                text: modelData.name
                color: theme.accent
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 12
              }
              Text {
                width: parent.width
                visible: modelData.mounts.length > 0
                text: "Mounted. It will be unmounted."
                color: theme.muted
                elide: Text.ElideRight
                font.family: "Adwaita Sans"
                font.pixelSize: 12
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: win.selectDrive(modelData.path)
            }
          }
        }
      }

      Rectangle {
        id: flameStep
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: 18
        color: flameHover.containsMouse && flameHover.enabled ? theme.bgRaised : "transparent"
        border.color: win.canFlash || win.phase === "flashing" ? theme.danger : theme.line
        border.width: 1

        StepIcon {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -22
          width: Math.min(flameStep.width, flameStep.height - 64) * 0.86
          height: width
          source: Qt.resolvedUrl("icons/flame.svg")
          color: win.canFlash || win.phase === "flashing" || win.phase === "done" ? theme.danger : theme.muted
          opacity: win.canFlash || win.phase === "flashing" || win.phase === "checking" || win.phase === "done" ? 1 : 0.45
        }

        Text {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: 16
          horizontalAlignment: Text.AlignHCenter
          text: {
            if (win.phase === "checking") return "Checking…"
            if (win.phase === "flashing" && win.writePhase === "write") return Math.round(win.progress * 100) + "%"
            if (win.phase === "flashing") return "Writing…"
            if (win.phase === "done") return "Done"
            return "Write"
          }
          color: win.canFlash || win.phase === "flashing" || win.phase === "done" ? theme.fg : theme.muted
          elide: Text.ElideRight
          font.family: "Adwaita Sans"
          font.pixelSize: 14
          font.weight: Font.Medium
        }

        MouseArea {
          id: flameHover
          anchors.fill: parent
          hoverEnabled: true
          enabled: win.phase !== "flashing" && win.phase !== "checking"
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: win.burn()
        }
      }
    }

    Rectangle {
      visible: win.showProgress
      Layout.fillWidth: true
      Layout.preferredHeight: 8
      radius: 4
      color: theme.bgDeep

      Rectangle {
        width: parent.width * (win.phase === "done" ? 1 : win.progress)
        height: parent.height
        radius: 4
        color: theme.accent
      }
    }

    RowLayout {
      Layout.fillWidth: true
      visible: win.footerText.length > 0 || win.canCancel
      spacing: 12

      Text {
        Layout.fillWidth: true
        text: win.footerText
        color: win.phase === "error" || win.imageTooBig ? theme.danger : theme.fg
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        font.family: "Adwaita Sans"
        font.pixelSize: 13
      }

      Text {
        visible: win.canCancel
        text: "Cancel"
        color: theme.danger
        font.family: "Adwaita Sans"
        font.pixelSize: 13
        font.weight: Font.Medium

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: win.cancelWrite()
        }
      }
    }
  }
}
