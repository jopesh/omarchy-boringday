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
  // The one action with a dependency outside Omarchy. Drawn disabled when the
  // CLI is not there, rather than offered and then failing into the hero line.
  readonly property bool aetherReady: service ? service.aetherReady : false
  readonly property bool rotating: service ? service.autoRotate : false

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
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }
  Text {
    id: captionRef
    visible: false
    text: "X"
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  Text {
    id: descriptionRef
    visible: false
    // Kept in lockstep with descriptionLines so the reserve and the clamp can
    // never disagree.
    text: ("X\n").repeat(Math.max(0, root.descriptionLines - 1)) + "X"
    textFormat: Text.PlainText
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

  // The service's limit, not a number of its own: the reserve below has to be
  // the length of the list it is reserving for, and two constants that must
  // agree are one constant too many.
  readonly property int pieceSlots: service && service.pieceLimit > 0 ? service.pieceLimit : 3
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
    // Behind the transient lines rather than in front of them: it is true for
    // the whole session, so it can wait for a quiet moment to be read.
    if (service.stateError) return "󰀪  " + service.stateError
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

  function moveCursor(dx, dy) {
    cursorActive = true
    if (cursorRows.length === 0) return
    // Left and right step through the rotation choices while the cursor is
    // on either rotation row, and mean nothing anywhere else.
    if (dy === 0) {
      var here = cursorRow()
      if (!here || (here.kind !== "auto" && here.kind !== "interval") || dx === 0) return
      if (dx > 0) cycleInterval()
      else cycleIntervalBack()
      return
    }
    cursorIndex = Math.max(0, Math.min(cursorRows.length - 1, cursorIndex + dy))
    var row = cursorRow()
    // Arrow keys browse: unlike hover, moving the cursor here is a deliberate
    // keypress, so it previews as it goes rather than making the keyboard do a
    // select-then-look two-step.
    if (row && row.kind === "piece") selectedIndex = row.index
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
    else if (row.kind === "interval") toggleMenu(intervalMenu)
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

  // The list's shuffle, not the pill's: this refills the rows and leaves the
  // wall alone. Setting a random piece outright is still what a keybinding and
  // the rotation do, through the service's other shuffle.
  function shuffleList() {
    if (service) service.shuffleList()
  }

  function download() {
    if (service && selected) service.download(selected)
  }

  function installToTheme() {
    if (service && selected) service.installToTheme(selected)
  }

  function generateTheme() {
    if (service && selected) service.generateTheme(selected, "panel")
  }

  function openArtPage() {
    if (service && selected) service.openArtPage(selected)
  }

  function openSite() {
    if (service) service.openSite()
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

  function cycleIntervalBack() {
    if (service) service.cycleIntervalBack()
  }

  // ------------------------------------------------------------------ menus

  function toggleMenu(menu) {
    if (!menu) return
    if (menu.opened) menu.close()
    else menu.open()
  }

  function restoreKeys() {
    keyCatcher.forceActiveFocus()
  }

  function closeMenus() {
    moreMenu.close()
    intervalMenu.close()
  }

  // What "More" offers for the piece being previewed. Built as data so the
  // letter beside each row is the same letter keyActions answers to.
  readonly property var moreOptions: {
    var busy = service ? (service.applying || service.generating) : true
    return [
      { value: "download", label: "Save a copy to Pictures", hint: "d" },
      { value: "install", label: "Add to the current theme", hint: "t" },
      {
        value: "theme",
        label: aetherReady ? "Build a theme from it" : "Build a theme (needs aether)",
        hint: "g",
        enabled: aetherReady && !busy
      },
      { value: "open", label: "Open on anotherboring.day", hint: "o", separatorBefore: true }
    ]
  }

  function runMoreAction(value) {
    if (value === "download") download()
    else if (value === "install") installToTheme()
    else if (value === "theme") generateTheme()
    else if (value === "open") openArtPage()
  }

  // The four presets, then following today's piece. The service owns what
  // each choice writes; this only names them and marks the one in force.
  readonly property var intervalOptions: {
    var out = []
    var follows = service ? service.followsToday : false
    var seconds = service ? service.intervalSeconds : 0
    for (var i = 0; i < Model.INTERVALS.length; i++) {
      var preset = Model.INTERVALS[i]
      out.push({
        value: String(preset),
        label: "Every " + Model.everyLabel(preset),
        checked: !follows && seconds === preset
      })
    }
    out.push({ value: "today", label: "Today's piece", hint: "daily",
      checked: follows, separatorBefore: true })
    return out
  }

  readonly property string intervalChoiceLabel: {
    if (!service) return ""
    return service.followsToday ? "Today's piece" : "Every " + service.intervalLabel
  }

  function chooseInterval(value) {
    if (!service) return
    if (value === "today") service.setRotateTo("today")
    else service.setIntervalSeconds(Number(value))
  }

  function openMoreMenu() {
    if (root.selected !== null && root.ready) toggleMenu(moreMenu)
  }

  // The letters the panel answers to, as a table rather than a ladder of
  // else-ifs — the same letters the action tooltips name in their own text,
  // written here beside the functions they call.
  readonly property var keyActions: ({
    "s": root.shuffleList, "d": root.download, "t": root.installToTheme,
    "g": root.generateTheme, "o": root.openArtPage, "r": root.refresh,
    "a": root.toggleAuto, "i": root.cycleInterval, "e": root.toggleDescription,
    "m": root.openMoreMenu,
    "\r": root.setSelected, "\n": root.setSelected
  })

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (!opened) closeMenus()
  else {
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
    if (!piece) return false
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i].id === piece.id) {
        selectedIndex = i
        return true
      }
    }
    return false
  }

  // A fresh fetch can shrink the list under a cursor that was parked at the end.
  property bool landedOnCurrent: false

  onPiecesChanged: {
    if (selectedIndex >= pieces.length) selectedIndex = 0
    if (cursorIndex >= cursorRows.length) cursorIndex = Math.max(0, cursorRows.length - 1)
    // Open the panel after a restart and it describes the wallpaper on screen,
    // not today's piece by default. Once only: after this the selection is the
    // user's to move.
    //
    // Spent when it lands, not when it is first tried. The fetch publishes its
    // list before the service puts the restored piece back into it, and the
    // state file may not even have been read yet, so the first change here can
    // arrive with nothing to land on — and did, which is how a restart came
    // back describing today's piece rather than the one on the wall.
    if (!landedOnCurrent && pieces.length > 0 && service && service.stateLoaded)
      landedOnCurrent = !service.current || selectPiece(service.current)
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
    // Rotation is said with the glyph, not with colour. BarIndicator — the
    // shell's own bar-status component — turns the accent off and swaps
    // activeText for inactiveText, so a bar item's state is a shape rather
    // than a hue; the pill follows it. The slot is a fixed width either way,
    // so the swap cannot shove its neighbours around.
    text: root.rotating ? "󰚰" : "󰋩"
    useActiveColor: false
    tooltipText: {
      if (!root.service) return "Another Boring Piece"
      if (root.service.current) return root.service.current.name + " — " + root.service.current.artist
      return "Another Boring Piece"
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
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
        var action = root.keyActions[String(t).toLowerCase()]
        if (action) action()
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
                textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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

              // Inset by one border width: at a fractional display scale
              // (seen at 1.25) the first chip's left border sits on the
              // content's clipped left edge and is not drawn.
              Row {
                anchors.left: parent.left
                anchors.leftMargin: Math.max(1, Style.space(1))
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
                      textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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

          // Actions on the piece currently previewed: the one that matters
          // most as a button, the rest behind "More". Every one of them keeps
          // its letter, so the keyboard reaches them without opening the menu.
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            Button {
              id: setButton
              text: "Set as background"
              bordered: true
              selected: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              enabled: root.selected !== null && root.ready
              opacity: enabled ? 1 : 0.5
              onClicked: root.setSelected()

              // The key that does the same, dimmed after the label — where
              // the menus put each row's letter — instead of in a tooltip.
              leftAlign: true
              width: implicitWidth + setButtonKey.implicitWidth + Style.space(10)

              Text {
                id: setButtonKey
                anchors.right: parent.right
                anchors.rightMargin: setButton.horizontalPadding
                anchors.verticalCenter: parent.verticalCenter
                text: "↵"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Button {
              id: moreButton
              text: "More  󰅀"
              bordered: true
              active: moreMenu.opened
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              enabled: root.selected !== null && root.ready
              opacity: enabled ? 1 : 0.5
              onClicked: root.toggleMenu(moreMenu)

              // The key that does the same, dimmed after the label — where
              // the menus put each row's letter — instead of in a tooltip.
              leftAlign: true
              width: implicitWidth + moreButtonKey.implicitWidth + Style.space(10)

              Text {
                id: moreButtonKey
                anchors.right: parent.right
                anchors.rightMargin: moreButton.horizontalPadding
                anchors.verticalCenter: parent.verticalCenter
                text: "m"
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              PopupMenu {
                id: moreMenu
                options: root.moreOptions
                onPicked: function (value) { root.runMoreAction(value) }
              }
            }
          }
          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            // The list's one control sits on its own header: it acts on what
            // is being chosen from, not on the piece being previewed.
            Item {
              width: parent.width
              height: Math.max(sectionHeader.implicitHeight, shuffleButton.implicitHeight)

              PanelSectionHeader {
                id: sectionHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "TODAY AND TWO MORE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Button {
                id: shuffleButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Shuffle"
                tooltipText: "Two more pieces in place of these  (s)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                verticalPadding: Style.space(2)
                enabled: root.ready && !(root.service && root.service.shufflingList)
                opacity: enabled ? 1 : 0.5
                onClicked: root.shuffleList()
              }
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

          // Rotation, as two rows: whether it runs, and what it changes to.
          // The period is a dropdown rather than a value to click through, so
          // any choice is one click away and the list says what the choices
          // are. A period set by hand in shell.json still reads as itself on
          // the trigger ("Every 45 minutes") and simply matches no row.
          CursorSurface {
            id: autoRow
            width: parent.width
            hasCursor: root.rowHasCursor("auto", 0)
            foreground: root.foreground
            // No padding of its own. The switch already carries six pixels of
            // cursor-ring padding on every side, and that is the row's
            // breathing room.
            implicitHeight: autoContent.implicitHeight

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

              Text {
                id: autoLabel
                anchors.left: parent.left
                anchors.right: autoSwitch.left
                anchors.rightMargin: Style.spacing.controlGap
                anchors.verticalCenter: parent.verticalCenter
                text: "Rotate automatically"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                maximumLineCount: 1
                elide: Text.ElideRight
              }

              ToggleSwitch {
                id: autoSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.rotating
                interactive: root.ready
                hasCursor: root.rowHasCursor("auto", 0)
                foreground: root.foreground
                onHovered: function (on) { if (on) root.focusRow("auto", 0) }
                onToggled: root.toggleAuto()
              }
            }
          }

          // Dim while rotation is off, because the choice is inert then — but
          // still live, so the period can be picked before switching on.
          CursorSurface {
            id: intervalRow
            width: parent.width
            hasCursor: root.rowHasCursor("interval", 0)
            foreground: root.foreground
            implicitHeight: Math.max(intervalCaption.implicitHeight, intervalTrigger.implicitHeight)
              + Style.spacing.labelGap * 2

            Component.onCompleted: root.registerCursorItem("interval", 0, intervalRow)

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.focusRow("interval", 0)
            }

            Text {
              id: intervalCaption
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX / 2
              anchors.right: intervalTrigger.left
              anchors.rightMargin: Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              text: "Change"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              maximumLineCount: 1
              elide: Text.ElideRight
            }

            Button {
              id: intervalTrigger
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX / 2
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(implicitWidth, Style.space(150))
              leftAlign: true
              bordered: true
              active: intervalMenu.opened
              hasCursor: root.rowHasCursor("interval", 0)
              text: root.intervalChoiceLabel + "  󰅀"
              foreground: root.rotating ? root.foreground : root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              enabled: root.ready
              onHovered: function (on) { if (on) root.focusRow("interval", 0) }
              onClicked: root.toggleMenu(intervalMenu)

              // Opens upwards: this is the last control in the card, and a
              // popup cannot draw past the bottom of the panel's window.
              PopupMenu {
                id: intervalMenu
                upward: true
                alignRight: true
                options: root.intervalOptions
                onPicked: function (value) { root.chooseInterval(value) }
              }
            }
          }
          // Where the art comes from. Centred rather than flush left, because
          // every other line in the card is a control or a fact about the
          // piece and this is neither — the different alignment is what says
          // so at a glance. Deliberately not a cursor row: `o` already opens
          // the page for the piece on screen, and a colophon does not need to
          // be reachable from the keyboard.
          Item {
            width: parent.width
            height: root.captionHeight

            Row {
              anchors.centerIn: parent
              // No vertical anchors on the children: both are set in the same
              // face at the same size, so they share a height and line up on
              // their own. Anchoring inside a positioner is what Row warns
              // about.
              spacing: Style.space(4)

              Text {
                height: root.captionHeight
                text: "Curated by"
                textFormat: Text.PlainText
                color: root.dim
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                verticalAlignment: Text.AlignVCenter
              }

              // Only the domain is the link — "Curated by" is not clickable,
              // and the hit area is the word itself rather than the width of
              // the card, so crossing the row does not light up a link.
              Text {
                id: siteCredit
                height: root.captionHeight
                text: "anotherboring.day"
                textFormat: Text.PlainText
                color: siteMouse.containsMouse ? root.foreground : root.dim
                opacity: siteMouse.containsMouse ? 1.0 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                verticalAlignment: Text.AlignVCenter

                MouseArea {
                  id: siteMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openSite()
                }
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

    // Which of the three is the one on the wall, since the selection no
    // longer has to be — browsing previews without setting.
    Text {
      id: onWall
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.labelGap
      anchors.verticalCenter: parent.verticalCenter
      visible: !!(root.service && root.service.current && pieceRow.piece
        && root.service.current.id === pieceRow.piece.id)
      text: visible ? "on wall" : ""
      textFormat: Text.PlainText
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Column {
      anchors.left: pieceThumb.right
      anchors.leftMargin: Style.spacing.controlGap
      anchors.right: onWall.visible ? onWall.left : parent.right
      anchors.rightMargin: Style.spacing.labelGap
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        width: parent.width
        text: pieceRow.piece ? pieceRow.piece.name : ""
        textFormat: Text.PlainText
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
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        maximumLineCount: 1
        elide: Text.ElideRight
      }
    }
  }

  // A small menu that opens off the control it is declared in: the panel's
  // "More" actions and the rotation choices. Drawn like the shell's own
  // Dropdown popup, but it can open upwards — the shell's opens downwards
  // only, and the rotation choice is the last control in the card, where a
  // downward popup would run past the bottom of the panel's window and be
  // cut off. Rows are { value, label, hint, checked, enabled, separatorBefore }.
  component PopupMenu: Popup {
    id: menu

    property var options: []
    property bool upward: false
    property bool alignRight: false
    property int currentIndex: -1
    readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border",
      Color.popups.border, Color.popups.border, Style.normalBorderWidth)

    signal picked(string value)

    // The rows fill the popup, so the popup cannot take its width from them;
    // it is measured from the longest label and hint instead. Longest by
    // characters: the shell font is monospaced, and on one that is not the
    // padding absorbs the difference.
    function longest(key, prefixChecked) {
      var best = ""
      for (var i = 0; i < options.length; i++) {
        var o = options[i]
        var t = (prefixChecked && o.checked ? "✓  " : "") + String(o[key] || "")
        if (t.length > best.length) best = t
      }
      return best
    }
    TextMetrics {
      id: labelMeasure
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      text: menu.longest("label", true) + "✓  "
    }
    TextMetrics {
      id: hintMeasure
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      text: menu.longest("hint", false)
    }
    readonly property real naturalWidth: Math.ceil(labelMeasure.advanceWidth + hintMeasure.advanceWidth)
      + Style.spacing.controlPaddingX * 2 + Style.space(16)

    function rowEnabled(i) {
      return i >= 0 && i < options.length && options[i].enabled !== false
    }

    function step(delta) {
      var i = currentIndex
      for (var n = 0; n < options.length; n++) {
        i = (i + delta + options.length) % options.length
        if (rowEnabled(i)) { currentIndex = i; return }
      }
    }

    function choose(i) {
      if (!rowEnabled(i)) return
      var value = String(options[i].value)
      close()
      picked(value)
    }

    x: alignRight && parent ? parent.width - width : 0
    y: upward ? -height - Style.spacing.xxs : (parent ? parent.height : 0) + Style.spacing.xxs
    width: Math.max(parent ? parent.width : 0, naturalWidth + leftPadding + rightPadding)
    closePolicy: Popup.CloseOnPressOutsideParent | Popup.CloseOnEscape
    focus: true
    padding: Style.spacing.hairline
    leftPadding: Border.left(borderSpec) + Style.spacing.hairline
    rightPadding: Border.right(borderSpec) + Style.spacing.hairline
    topPadding: Border.top(borderSpec) + Style.spacing.hairline
    bottomPadding: Border.bottom(borderSpec) + Style.spacing.hairline

    background: BorderSurface {
      color: Color.popups.background
      borderSpec: menu.borderSpec
      radius: Style.cornerRadius
    }

    onOpened: {
      currentIndex = -1
      for (var i = 0; i < options.length; i++) if (options[i].checked) currentIndex = i
      if (!rowEnabled(currentIndex)) { currentIndex = -1; step(1) }
      keys.forceActiveFocus()
    }
    // Hand the keyboard back to the panel, which stops answering keys
    // while a popup holds them.
    onClosed: Qt.callLater(root.restoreKeys)

    contentItem: Item {
      id: keys
      implicitHeight: menuColumn.implicitHeight
      focus: true

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) menu.close()
        else if (event.key === Qt.Key_Down || event.text === "j") menu.step(1)
        else if (event.key === Qt.Key_Up || event.text === "k") menu.step(-1)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                 || event.key === Qt.Key_Space) menu.choose(menu.currentIndex)
        else {
          // A row's letter picks it directly, as it does with the menu shut.
          var letter = String(event.text || "").toLowerCase()
          for (var i = 0; letter && i < menu.options.length; i++) {
            if (menu.options[i].hint === letter) { menu.choose(i); break }
          }
        }
        event.accepted = true
      }

      Column {
        id: menuColumn
        width: parent.width

        Repeater {
          model: menu.options

          Column {
            id: entry
            required property var modelData
            required property int index
            readonly property bool usable: modelData.enabled !== false
            readonly property bool hot: menu.currentIndex === index && usable
            width: menuColumn.width

            Rectangle {
              visible: entry.modelData.separatorBefore === true && entry.index > 0
              width: parent.width
              height: Style.spacing.hairline
              color: Util.alpha(Color.popups.text, 0.15)
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.popupRowHeight
              color: entry.hot ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

              Text {
                id: entryLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.right: entryHint.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: (entry.modelData.checked ? "✓  " : "") + entry.modelData.label
                textFormat: Text.PlainText
                color: !entry.usable ? Qt.darker(Color.popups.text, 1.8)
                  : entry.hot ? Style.hoverStateColor(Color.popups.text, Color.accent)
                  : Color.popups.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: entryHint
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                text: entry.modelData.hint || ""
                textFormat: Text.PlainText
                color: Qt.darker(Color.popups.text, 1.8)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                enabled: entry.usable
                cursorShape: Qt.PointingHandCursor
                onEntered: menu.currentIndex = entry.index
                onClicked: menu.choose(entry.index)
              }
            }
          }
        }
      }
    }
  }
}
