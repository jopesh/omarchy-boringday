import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar half of the plugin: a pill in the bar that opens a popup showing
// today's piece and the two the service fetched alongside it. Every action
// here is a call into the service, which owns the state — so two monitors show
// the same thing, and closing the panel stops nothing.
//
// Layout rule for this file: nothing in the popup may change size because of
// which piece is selected. Titles, credits and descriptions all vary in length
// between pieces, so every block that renders them is given a height measured
// from the theme's own font and holds it whether the text is short, long, or
// absent. Browsing the three pieces then swaps pixels and moves nothing. The
// card itself is a fixed size; content that legitimately grows — an expanded
// description — scrolls rather than resizing the window.
Panel {
  id: root
  moduleName: "boringday.wallpapers"
  ipcTarget: "boringday.wallpapers"
  manageIpc: false

  // Resolved through the bar's shell handle. serviceFor() reads the shell's
  // service map, so this binding re-evaluates when the service finishes
  // loading rather than latching onto the null it saw first.
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null

  readonly property var pieces: service && service.pieces ? service.pieces : []
  readonly property bool ready: service !== null

  property int selectedIndex: 0
  readonly property var selected: selectedIndex >= 0 && selectedIndex < pieces.length
    ? pieces[selectedIndex] : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------- fixed metrics
  //
  // Every reserved height below is measured from a real Text item rather than
  // derived from FontMetrics. Qt does not lay N lines out as N * lineSpacing,
  // so an arithmetic reserve came out a pixel short of the text it had to hold
  // and `clip` took that pixel off the bottom line. These items never draw;
  // they exist to be measured, and they track the theme's font automatically.

  Text {
    id: subtitleRef
    visible: false
    text: "X"
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }
  Text {
    id: captionRef
    visible: false
    text: "X"
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Text {
    id: descriptionRef
    visible: false
    // Kept in lockstep with descriptionLines so the reserve and the clamp can
    // never disagree.
    text: ("X\n").repeat(Math.max(0, root.descriptionLines - 1)) + "X"
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  readonly property int descriptionLines: 3
  readonly property real titleHeight: Math.ceil(subtitleRef.implicitHeight)
  readonly property real captionHeight: Math.ceil(captionRef.implicitHeight)
  readonly property real descriptionCollapsedHeight: Math.ceil(descriptionRef.implicitHeight)
  // Same padding the TODAY badge puts around its own caption text, so the two
  // small labelled surfaces in the card are the same size.
  readonly property real chipHeight: captionHeight + Style.space(6)
  readonly property real chipGap: Style.space(6)

  readonly property var tags: selected ? Model.tags(selected) : []

  readonly property int pieceSlots: 3
  readonly property real listGap: Style.space(4)
  readonly property real pieceRowHeight: Style.space(30) + Style.spacing.labelGap * 2
  // The piece list holds all three slots from the first frame so the first
  // fetch landing does not shove the rotation row down.
  readonly property real pieceListHeight: pieceRowHeight * pieceSlots + listGap * (pieceSlots - 1)

  readonly property string previewSource: {
    if (!service || !selected) return ""
    var path = service.thumbs ? service.thumbs[selected.id] : ""
    return path ? Util.fileUrl(path) : ""
  }

  // Transient status shares the hero's subtitle instead of owning a row of its
  // own. The hero line is always there and always one line tall, so routing
  // "Saved to …" and errors through it costs no space and cannot shift
  // anything; a dedicated status row sat empty most of the time and pushed the
  // piece list around the rest of it.
  readonly property string heroMeta: {
    if (!service) return "Plugin service is not loaded"
    if (service.lastError) return "󰀪  " + service.lastError
    if (service.status) return service.status
    if (service.applying) return "Setting background…"
    return "Daily fine art, hand-picked"
  }

  // ------------------------------------------------------------- navigation
  //
  // One flat list of everything the keyboard cursor can land on, in the order
  // it appears on screen. Building it from the same data the view renders
  // keeps the cursor from pointing at a row that isn't there.

  property bool cursorActive: false
  property int cursorIndex: 0

  readonly property var cursorRows: {
    var rows = []
    for (var i = 0; i < pieces.length; i++) rows.push({ kind: "piece", index: i })
    rows.push({ kind: "auto", index: 0 })
    rows.push({ kind: "interval", index: 0 })
    return rows
  }

  function cursorRow() {
    if (cursorIndex < 0 || cursorIndex >= cursorRows.length) return null
    return cursorRows[cursorIndex]
  }

  function rowHasCursor(kind, index) {
    if (!cursorActive) return false
    var row = cursorRow()
    return row !== null && row.kind === kind && row.index === index
  }

  // Which chip the keyboard is sitting on while the cursor is on the interval
  // row. Distinct from which period is in force: you walk across the chips and
  // then activate one, the same way ButtonGroup's own Tab focus behaves.
  property int intervalCursor: 0
  readonly property int intervalIndex:
    service ? Model.intervalIndex(service.intervalSeconds) : -1
  readonly property int intervalCount: Model.INTERVALS.length

  function moveCursor(dx, dy) {
    cursorActive = true
    if (cursorRows.length === 0) return
    // Left/right walks the interval chips when the cursor is on that row, and
    // means nothing anywhere else.
    if (dy === 0) {
      var here = cursorRow()
      if (dx !== 0 && here && here.kind === "interval")
        intervalCursor = Math.max(0, Math.min(intervalCount - 1, intervalCursor + dx))
      return
    }
    cursorIndex = Math.max(0, Math.min(cursorRows.length - 1, cursorIndex + dy))
    var row = cursorRow()
    // Arrow keys browse: unlike hover, moving the cursor here is a deliberate
    // keypress, so it previews as it goes rather than making the keyboard do a
    // select-then-look two-step.
    if (row && row.kind === "piece") selectedIndex = row.index
    // Arriving on the chips, start from the period actually in force so the
    // user sees their existing choice rather than a cursor parked elsewhere.
    if (row && row.kind === "interval") intervalCursor = Math.max(0, intervalIndex)
    scrollCursorIntoView()
  }

  function focusRow(kind, index) {
    cursorActive = true
    for (var i = 0; i < cursorRows.length; i++) {
      if (cursorRows[i].kind === kind && cursorRows[i].index === index) {
        cursorIndex = i
        return
      }
    }
  }

  function activateCursor() {
    var row = cursorRow()
    if (!row) return
    // Deliberately the selected piece rather than the row under the cursor:
    // the pointer can rest on a row that is not the one being previewed, and
    // Enter must set the piece the user is actually looking at.
    if (row.kind === "piece") setSelected()
    else if (row.kind === "auto") toggleAuto()
    else if (row.kind === "interval") setInterval(Model.INTERVALS[intervalCursor])
  }

  // Rows register themselves so scrollCursorIntoView can find the item under
  // the cursor without the panel knowing how the view is nested. Keyed by
  // kind+index rather than by position in cursorRows: the first fetch pushes
  // three piece rows in above the rotation row, and a positional key would
  // point at the wrong item from then on.
  property var cursorItems: ({})

  function cursorItemKey(kind, index) {
    return kind + ":" + index
  }

  function registerCursorItem(kind, index, item) {
    cursorItems[cursorItemKey(kind, index)] = item
  }

  function scrollIntoView(item) {
    if (!item || !panelFlick) return
    var margin = Style.space(8)
    var point = item.mapToItem(panelFlick.contentItem, 0, 0)
    var top = point.y
    var bottom = top + item.height
    var viewTop = panelFlick.contentY
    var viewBottom = viewTop + panelFlick.height
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
  }

  function scrollCursorIntoView() {
    Qt.callLater(function () {
      var row = cursorRow()
      if (!row) return
      root.scrollIntoView(cursorItems[cursorItemKey(row.kind, row.index)])
    })
  }

  // ----------------------------------------------------------------- actions

  // Collapsed by default and reset whenever the piece changes: an expanded
  // description is as tall as that particular text, so carrying the expansion
  // across a selection would reintroduce exactly the resizing this layout
  // exists to prevent.
  property bool descriptionExpanded: false
  readonly property bool descriptionTruncated: descriptionText.truncated

  function toggleDescription() {
    if (!descriptionExpanded && !descriptionTruncated) return
    descriptionExpanded = !descriptionExpanded
    // The card does not grow, so bring the newly revealed text into view
    // rather than leaving it below the fold.
    if (descriptionExpanded) Qt.callLater(function () { root.scrollIntoView(descriptionBlock) })
  }

  onSelectedIndexChanged: descriptionExpanded = false

  function setPiece(piece) {
    if (service && piece) service.apply(piece, "set")
  }

  function setSelected() {
    setPiece(selected)
  }

  function shuffle() {
    if (service) service.shuffle("shuffle")
  }

  function download() {
    if (service && selected) service.download(selected)
  }

  function openArtPage() {
    if (service && selected) service.openArtPage(selected)
  }

  function refresh() {
    if (service) service.refresh()
  }

  function toggleAuto() {
    if (service) service.setAutoRotate(!service.autoRotate)
  }

  function cycleInterval() {
    if (service) service.cycleInterval()
  }

  function setInterval(seconds) {
    if (service) service.setIntervalSeconds(seconds)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    descriptionExpanded = false
    if (panelFlick) panelFlick.contentY = 0
    if (service && service.pieces.length === 0) service.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  // Whatever ends up on the wall becomes the piece the panel is describing —
  // including one that arrived from a shuffle, a keybinding, or a rotation that
  // fired while the panel was closed. The service has already put it in the
  // list by the time this runs.
  Connections {
    target: root.service
    function onApplied(piece) { root.selectPiece(piece) }
  }

  function selectPiece(piece) {
    if (!piece) return
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i].id === piece.id) {
        selectedIndex = i
        return
      }
    }
  }

  // A fresh fetch can shrink the list under a cursor that was parked at the end.
  property bool landedOnCurrent: false

  onPiecesChanged: {
    if (selectedIndex >= pieces.length) selectedIndex = 0
    if (cursorIndex >= cursorRows.length) cursorIndex = Math.max(0, cursorRows.length - 1)
    // Open the panel after a restart and it describes the wallpaper on screen,
    // not today's piece by default. Once only: after this the selection is the
    // user's to move.
    if (!landedOnCurrent && pieces.length > 0) {
      landedOnCurrent = true
      if (service && service.current) selectPiece(service.current)
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋩"
    active: root.service ? root.service.autoRotate : false
    tooltipText: {
      if (!root.service) return "Another Boring Piece"
      if (root.service.current) return root.service.current.name + " — " + root.service.current.artist
      return "Another Boring Piece"
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.shuffle()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Sized to the collapsed layout and held there. Subtracting the
    // description's overflow keeps the argument independent of whether the
    // description is expanded, so the card fits its content exactly on any
    // theme and expanding scrolls instead of resizing the window.
    // fittedContentHeight, not cappedContentHeight: only the former adds the
    // card's own padding and borders, and without them the content scrolled by
    // exactly that inset even when nothing had grown.
    contentHeight: panel.fittedContentHeight(root.collapsedContentHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = String(t).toLowerCase()
        if (key === "s") root.shuffle()
        else if (key === "d") root.download()
        else if (key === "o") root.openArtPage()
        else if (key === "r") root.refresh()
        else if (key === "a") root.toggleAuto()
        else if (key === "i") root.cycleInterval()
        else if (key === "e") root.toggleDescription()
        else if (key === "\r" || key === "\n") root.setSelected()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // The hero identifies the plugin, not the piece. Piece metadata used
          // to live here, but PanelHero sizes its title row to the taller of
          // the title text and the TODAY pill — so the header grew by a pixel
          // the moment the pill appeared, and the whole popup with it. Constant
          // text here, piece text below, badge drawn over the image.
          PanelHero {
            id: hero
            width: parent.width
            title: "Another Boring Piece"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            // Assigned to PanelHero's property, so this Component is created in
            // PanelHero's context where an unqualified `root` is the hero, not
            // this panel. Address the hero by id — unique to this file — and
            // take the size off the Style singleton.
            iconComponent: Component {
              Text {
                text: "󰋩"
                color: hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Preview. The source is a local file the service already fetched,
          // so this is a disk read, not a network request mid-render. Fixed
          // height, and PreserveAspectCrop absorbs the difference between a
          // portrait and a landscape piece rather than passing it to the layout.
          Rectangle {
            id: previewFrame
            width: parent.width
            height: Math.round(width * 0.6)
            color: Util.alpha(root.foreground, 0.05)
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(root.foreground, 0.18)
            clip: true

            Image {
              id: preview
              anchors.fill: parent
              anchors.margins: previewFrame.border.width
              source: root.previewSource
              asynchronous: true
              fillMode: Image.PreserveAspectCrop
              sourceSize.width: Math.round(previewFrame.width * 2)
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: preview.status !== Image.Ready
              text: root.previewSource === "" ? "󰋩" : "󰋫"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }

            // Overlaid rather than placed in the column: the badge comes and
            // goes with the selection and must not occupy layout space.
            Rectangle {
              visible: root.selected !== null && root.selected.isToday && preview.status === Image.Ready
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              width: todayBadge.implicitWidth + Style.space(12)
              height: todayBadge.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                id: todayBadge
                anchors.centerIn: parent
                text: "TODAY"
                color: "#ffffff"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setSelected()
            }
          }

          // Title, credit and school as one caption block instead of three
          // rows spaced like sections. The column's 12px gap is what separates
          // *sections* of the card; using it between a title and its own
          // credit meant four facts of very different value all arrived at the
          // same volume. Grouped and tiered instead — name in the subtitle
          // face, artist and year a step down and tight against it, school and
          // genre demoted out of running text into chips. Every height is
          // still reserved: a piece with no school reserves the chip row all
          // the same, so browsing moves nothing.
          Column {
            width: parent.width
            spacing: Style.space(8)

            Column {
              width: parent.width
              spacing: Style.space(3)

              // One line, always one line. A two-line title on one piece and a
              // one-line title on the next is a layout shift.
              Text {
                width: parent.width
                height: root.titleHeight
                text: root.selected ? root.selected.name : "—"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                maximumLineCount: 1
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
              }

              Text {
                width: parent.width
                height: root.captionHeight
                text: root.selected ? Model.credit(root.selected) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                maximumLineCount: 1
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
              }
            }

            // The chips borrow the same control border the interval buttons
            // wear at the foot of the panel, so the school and genre read as
            // labels rather than as more of the credit line. The Item holds
            // the row's height whether there are two chips, one, or none.
            Item {
              id: chipRow
              width: parent.width
              height: root.chipHeight

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.chipGap

                Repeater {
                  model: root.tags

                  BorderSurface {
                    required property string modelData

                    // Safety net for a freakishly long school name: share the
                    // row evenly and elide. Real movement and genre names come
                    // nowhere near the panel's width, so this never fires in
                    // practice — it is here so that when it does, the chip
                    // elides instead of pushing its neighbour off the card.
                    readonly property real maxWidth: Math.max(Style.space(48),
                      (chipRow.width - root.chipGap * (root.tags.length - 1)) / root.tags.length)

                    implicitWidth: Math.min(chipLabel.implicitWidth + Style.space(16), maxWidth)
                    implicitHeight: root.chipHeight
                    color: "transparent"
                    radius: Style.cornerRadius
                    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                    Text {
                      id: chipLabel
                      anchors.centerIn: parent
                      width: Math.min(implicitWidth, parent.width - Style.space(16))
                      text: modelData
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      maximumLineCount: 1
                      elide: Text.ElideRight
                      horizontalAlignment: Text.AlignHCenter
                    }
                  }
                }
              }
            }
          }

          // Reserved at three lines regardless of how much text the piece
          // carries, so switching pieces never moves anything below. Expanding
          // is the one place the content is allowed to grow, because the user
          // asked it to — and it scrolls rather than resizing the card.
          Item {
            id: descriptionBlock
            width: parent.width
            height: root.descriptionExpanded
              ? Math.max(root.descriptionCollapsedHeight, descriptionText.implicitHeight)
              : root.descriptionCollapsedHeight
            clip: true

            // No height animation here. An animated Behavior that gets
            // retargeted mid-flight — expand, then move to another piece —
            // was observed stopping partway and leaving the block stuck at a
            // fractional height it never left. Expansion is instant, which is
            // both deterministic and what "no warping" asks for.

            Text {
              id: descriptionText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              text: root.selected ? root.selected.description : ""
              color: Qt.darker(root.foreground, 1.25)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              // Line-count clipping is what sets `truncated`, which is how the
              // toggle below knows whether there is anything more to show.
              maximumLineCount: root.descriptionExpanded ? 999 : root.descriptionLines
              elide: Text.ElideRight
            }
          }

          // Always present, empty when there is nothing to expand — an
          // appearing and disappearing link is itself a layout shift.
          Text {
            id: descriptionToggle
            width: parent.width
            height: root.captionHeight
            text: {
              if (root.descriptionExpanded) return "󰅃  Show less"
              return root.descriptionTruncated ? "󰅀  Show more" : ""
            }
            color: toggleMouse.containsMouse ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter

            MouseArea {
              id: toggleMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: descriptionToggle.text !== ""
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleDescription()
            }
          }

          // Actions on the piece currently previewed.
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            PanelActionButton {
              iconText: "󰸉"
              tooltipText: "Set as background  (Enter)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.selected !== null && root.ready
              onClicked: root.setSelected()
            }
            PanelActionButton {
              iconText: "󰒟"
              tooltipText: "Shuffle a random piece  (s)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.ready
              onClicked: root.shuffle()
            }
            PanelActionButton {
              iconText: "󰇚"
              tooltipText: "Save a copy to Pictures  (d)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.selected !== null && root.ready
              onClicked: root.download()
            }
            PanelActionButton {
              iconText: "󰖟"
              tooltipText: "Open on anotherboring.day  (o)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.selected !== null
              onClicked: root.openArtPage()
            }
            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Fetch today's pieces again  (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.ready
              onClicked: root.refresh()
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "TODAY AND TWO MORE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              height: root.pieceListHeight

              Column {
                id: pieceColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: root.listGap

                Repeater {
                  model: root.pieces
                  PieceRow {
                    required property var modelData
                    required property int index
                    width: pieceColumn.width
                    piece: modelData
                    rowIndex: index
                  }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // Rotation. The toggle and the interval are two targets on one row:
          // the switch owns on/off, the interval label cycles the presets.
          CursorSurface {
            id: autoRow
            width: parent.width
            hasCursor: root.rowHasCursor("auto", 0)
            foreground: root.foreground
            implicitHeight: autoContent.implicitHeight + Style.spacing.controlPaddingY * 2

            Component.onCompleted: root.registerCursorItem("auto", 0, autoRow)

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.focusRow("auto", 0)
            }

            Item {
              id: autoContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX / 2
              anchors.rightMargin: Style.spacing.rowPaddingX / 2
              implicitHeight: Math.max(autoLabel.implicitHeight, autoSwitch.implicitHeight)

              Column {
                id: autoLabel
                anchors.left: parent.left
                anchors.right: autoSwitch.left
                anchors.rightMargin: Style.spacing.controlGap
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.labelGap

                Text {
                  width: parent.width
                  text: "Rotate automatically"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  maximumLineCount: 1
                  elide: Text.ElideRight
                }

                // Kept alongside the chips because it is the only thing that
                // can describe a period set by hand in shell.json, which
                // matches no chip.
                Text {
                  id: intervalLabel
                  width: parent.width
                  height: root.captionHeight
                  text: root.service ? "every " + root.service.intervalLabel : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  maximumLineCount: 1
                  elide: Text.ElideRight
                  verticalAlignment: Text.AlignVCenter
                }
              }

              ToggleSwitch {
                id: autoSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.service ? root.service.autoRotate : false
                interactive: root.ready
                hasCursor: root.rowHasCursor("auto", 0)
                foreground: root.foreground
                onHovered: function (on) { if (on) root.focusRow("auto", 0) }
                onToggled: root.toggleAuto()
              }
            }
          }

          // How often, as a row of chips rather than a value you cycle blindly.
          // Not wrapped in a CursorSurface: ButtonGroup's chips paint their own
          // selected and hover-cursor states from the same Style tokens, and a
          // surface behind them would put two highlights on one row.
          Item {
            id: intervalRow
            width: parent.width
            implicitHeight: intervalGroup.implicitHeight

            Component.onCompleted: root.registerCursorItem("interval", 0, intervalRow)

            ButtonGroup {
              id: intervalGroup
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX / 2
              anchors.verticalCenter: parent.verticalCenter
              options: Model.intervalOptions()
              // Unselects every chip when shell.json carries a period that is
              // not one of the presets; the caption above still names it.
              value: root.service ? String(root.service.intervalSeconds) : ""
              foreground: root.foreground
              accent: root.bar ? root.bar.urgent : Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              // Panel-cursor driven, per ButtonGroup's contract: the panel owns
              // the cursor, so the group must not also take Tab focus.
              focusable: false
              cursorIndex: root.rowHasCursor("interval", 0) ? root.intervalCursor : -1

              onChanged: function (value) { root.setInterval(Number(value)) }
              onHovered: function (index, isHovered) {
                if (!isHovered) return
                root.focusRow("interval", 0)
                root.intervalCursor = index
              }
            }
          }
        }
      }
    }
  }

  // What the card is sized to: the column as it stands, minus however far the
  // description has been expanded past its reserve. Constant in every state.
  readonly property real descriptionOverflow:
    Math.max(0, descriptionBlock.height - descriptionCollapsedHeight)
  readonly property real collapsedContentHeight:
    Math.max(1, column.implicitHeight - descriptionOverflow)

  component PieceRow: CursorSurface {
    id: pieceRow

    property var piece: null
    property int rowIndex: 0

    hasCursor: root.rowHasCursor("piece", rowIndex)
    current: root.selectedIndex === rowIndex
    foreground: root.foreground
    implicitHeight: root.pieceRowHeight

    Component.onCompleted: root.registerCursorItem("piece", rowIndex, pieceRow)

    // Hover moves the cursor ring and nothing else; the click is what chooses
    // the piece. Selecting on hover meant dragging the pointer across the list
    // on the way to a button repainted the preview and the metadata behind it.
    // Choosing is not the same as applying: this list previews, and the wall
    // only changes on the Set button, the preview image, or Enter.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow("piece", pieceRow.rowIndex)
      onClicked: root.selectedIndex = pieceRow.rowIndex
    }

    Rectangle {
      id: pieceThumb
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.labelGap
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(46)
      height: Style.space(30)
      color: Util.alpha(root.foreground, 0.06)
      clip: true

      Image {
        anchors.fill: parent
        source: {
          if (!root.service || !pieceRow.piece) return ""
          var path = root.service.thumbs ? root.service.thumbs[pieceRow.piece.id] : ""
          return path ? Util.fileUrl(path) : ""
        }
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: Style.space(120)
      }
    }

    Column {
      anchors.left: pieceThumb.right
      anchors.leftMargin: Style.spacing.controlGap
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.labelGap
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        width: parent.width
        text: pieceRow.piece ? pieceRow.piece.name : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        maximumLineCount: 1
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: pieceRow.piece
          ? (pieceRow.piece.isToday ? "Today  ·  " : "") + pieceRow.piece.artist
          : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        maximumLineCount: 1
        elide: Text.ElideRight
      }
    }
  }
}
