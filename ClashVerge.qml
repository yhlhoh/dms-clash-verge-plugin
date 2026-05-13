import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property string resolvedPluginId: pluginId || "clashVerge"
    readonly property string pluginPath: pluginService ? pluginService.getPluginPath(resolvedPluginId) : ""
    readonly property string runnerPath: pluginPath ? pluginPath + "/scripts/run-helper.sh" : ""

    property bool loading: false
    property bool busy: false
    property bool hasLoaded: false
    property string errorText: ""
    property string viewMode: "overview"
    property string expandedGroup: ""
    property string barLabel: "Clash"
    property string barMode: "idle"
    property bool delayTesting: false
    property bool delayTestingGroup: false
    property string testingGroup: ""
    property string testingNode: ""
    property var runtimeState: ({})
    property var selectorGroups: []
    property var profiles: []
    property var delayResults: ({})

    function shortText(value, maxLength) {
        const text = String(value || "")
        if (text.length <= maxLength)
            return text
        return text.slice(0, Math.max(0, maxLength - 1)) + "…"
    }

    function modeLabel(modeName) {
        switch (modeName) {
        case "rule":
            return "Rule"
        case "global":
            return "Global"
        case "direct":
            return "Direct"
        default:
            return modeName || "Unknown"
        }
    }

    function summaryText() {
        if (runtimeState.summaryGroup && runtimeState.summaryNode)
            return runtimeState.summaryGroup + " -> " + runtimeState.summaryNode
        if (runtimeState.currentProfileName)
            return runtimeState.currentProfileName
        return "Open to load Clash Verge status"
    }

    function applyState(data) {
        hasLoaded = true
        runtimeState = data || {}
        selectorGroups = data.selectorGroups || []
        profiles = data.profiles || []
        if ((!expandedGroup || selectorGroups.every(group => group.name !== expandedGroup)) && selectorGroups.length > 0)
            expandedGroup = selectorGroups[0].name
        barLabel = shortText(data.summaryNode || data.currentProfileName || "Clash", 18)
        barMode = shortText(data.mode || "idle", 8)
        if (!data.runtimeError)
            errorText = ""
    }

    function handleJsonOutput(rawText) {
        const cleanText = String(rawText || "").trim()
        if (!cleanText)
            return

        let payload
        try {
            payload = JSON.parse(cleanText)
        } catch (error) {
            errorText = "Helper returned invalid JSON"
            console.warn("ClashVerge JSON parse failed", error, cleanText)
            return
        }

        if (!payload.ok) {
            errorText = payload.error || "Clash Verge helper failed"
            return
        }

        applyState(payload.data || {})
    }

    function delayKey(groupName, nodeName) {
        return String(groupName || "") + "::" + String(nodeName || "")
    }

    function delayText(groupName, nodeName) {
        const key = delayKey(groupName, nodeName)
        const entry = delayResults[key]
        if (!entry)
            return ""
        if (entry.pending)
            return "Testing..."
        if (entry.error)
            return entry.error
        if (entry.ok && entry.delay !== undefined && entry.delay !== null)
            return entry.delay + " ms"
        return "Unavailable"
    }

    function delayButtonText(groupName, nodeName) {
        if (isTestingThisNode(groupName, nodeName))
            return "Testing"
        return "Test"
    }

    function testAllButtonText(groupName) {
        return isTestingThisGroup(groupName) ? "Testing" : "Test all"
    }

    function canTestNode(nodeName) {
        return ["DIRECT", "REJECT", "REJECT-DROP", "PASS"].indexOf(String(nodeName || "")) < 0
    }

    function isTestingThisNode(groupName, nodeName) {
        return delayTesting && !delayTestingGroup && testingGroup === groupName && testingNode === nodeName
    }

    function isTestingThisGroup(groupName) {
        return delayTesting && delayTestingGroup && testingGroup === groupName
    }

    function setDelayPending(groupName, nodeName) {
        const key = delayKey(groupName, nodeName)
        const next = Object.assign({}, delayResults)
        next[key] = {
            pending: true,
            ok: false,
            delay: null,
            error: ""
        }
        delayResults = next
    }

    function storeDelayResult(groupName, nodeName, data) {
        const key = delayKey(groupName, nodeName)
        const next = Object.assign({}, delayResults)
        next[key] = {
            pending: false,
            ok: !!data.ok,
            delay: data.delay,
            error: data.ok ? "" : (data.error || "Unavailable")
        }
        delayResults = next
    }

    function storeGroupDelayResults(groupName, payload) {
        const results = payload && payload.results ? payload.results : []
        for (let i = 0; i < results.length; ++i) {
            const result = results[i]
            if (!result || !result.node)
                continue
            storeDelayResult(groupName, result.node, result)
        }
    }

    function refreshState(forceRefresh) {
        if (!runnerPath) {
            errorText = "Plugin path is not ready yet"
            return
        }
        if (procQuery.running)
            return

        if (forceRefresh)
            errorText = ""

        loading = true
        procQuery.command = [runnerPath, "status"]
        procQuery.running = true
    }

    function runAction(args) {
        if (!runnerPath) {
            errorText = "Plugin path is not ready yet"
            return
        }
        if (busy || procAction.running)
            return

        busy = true
        errorText = ""
        procAction.command = [runnerPath].concat(args)
        procAction.running = true
    }

    function setNode(groupName, nodeName) {
        runAction(["set-node", groupName, nodeName])
    }

    function setProfile(profileId) {
        runAction(["set-profile", profileId])
    }

    function testDelay(groupName, nodeName) {
        if (!runnerPath || delayTesting || busy)
            return

        delayTesting = true
        delayTestingGroup = false
        testingGroup = groupName
        testingNode = nodeName
        setDelayPending(groupName, nodeName)
        procDelay.command = [runnerPath, "test-delay", groupName, nodeName]
        procDelay.running = true
    }

    function testGroup(groupName, nodes) {
        if (!runnerPath || delayTesting || busy)
            return

        delayTesting = true
        delayTestingGroup = true
        testingGroup = groupName
        testingNode = ""

        const nodeList = nodes || []
        for (let i = 0; i < nodeList.length; ++i) {
            const nodeName = String(nodeList[i] || "")
            if (canTestNode(nodeName))
                setDelayPending(groupName, nodeName)
        }

        procDelay.command = [runnerPath, "test-group", groupName]
        procDelay.running = true
    }

    Process {
        id: procQuery
        stdout: StdioCollector {
            onStreamFinished: root.handleJsonOutput(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const message = text.trim()
                if (message)
                    root.errorText = message
            }
        }
        onExited: exitCode => {
            root.loading = false
            if (exitCode !== 0 && !root.errorText)
                root.errorText = "Failed to load Clash Verge status"
        }
    }

    Process {
        id: procAction
        stdout: StdioCollector {
            onStreamFinished: root.handleJsonOutput(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const message = text.trim()
                if (message)
                    root.errorText = message
            }
        }
        onExited: exitCode => {
            root.busy = false
            if (exitCode !== 0 && !root.errorText)
                root.errorText = "Clash Verge action failed"
        }
    }

    Process {
        id: procDelay
        stdout: StdioCollector {
            onStreamFinished: {
                const cleanText = String(text || "").trim()
                if (!cleanText)
                    return

                try {
                    const payload = JSON.parse(cleanText)
                    if (!payload.ok) {
                        if (root.delayTestingGroup) {
                            root.errorText = payload.error || "Delay test failed"
                        } else {
                            root.storeDelayResult(root.testingGroup, root.testingNode, {
                                ok: false,
                                error: payload.error || "Delay test failed"
                            })
                        }
                        return
                    }
                    if (root.delayTestingGroup)
                        root.storeGroupDelayResults(root.testingGroup, payload.data || {})
                    else
                        root.storeDelayResult(root.testingGroup, root.testingNode, payload.data || {})
                } catch (error) {
                    if (root.delayTestingGroup) {
                        root.errorText = "Invalid delay response"
                    } else {
                        root.storeDelayResult(root.testingGroup, root.testingNode, {
                            ok: false,
                            error: "Invalid delay response"
                        })
                    }
                    console.warn("ClashVerge delay parse failed", error, cleanText)
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const message = text.trim()
                if (message) {
                    if (root.delayTestingGroup)
                        root.errorText = message
                    else
                        root.storeDelayResult(root.testingGroup, root.testingNode, {
                            ok: false,
                            error: message
                        })
                }
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                if (root.delayTestingGroup)
                    root.errorText = root.errorText || "Group delay test failed"
                else
                    root.storeDelayResult(root.testingGroup, root.testingNode, {
                        ok: false,
                        error: "Delay test failed"
                    })
            }

            root.delayTesting = false
            root.delayTestingGroup = false
            root.testingGroup = ""
            root.testingNode = ""
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: runtimeState.available ? "vpn_lock" : "vpn_key_off"
                color: runtimeState.available ? Theme.primary : Theme.surfaceVariantText
                size: Theme.iconSize - 4
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                StyledText {
                    text: root.barLabel
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                }

                StyledText {
                    text: root.barMode
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: runtimeState.available ? "vpn_lock" : "vpn_key_off"
                color: runtimeState.available ? Theme.primary : Theme.surfaceVariantText
                size: Theme.iconSize - 4
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.shortText(root.barMode, 6)
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 460
    popoutHeight: 620

    popoutContent: Component {
        PopoutComponent {
            id: popoutRoot
            headerText: "Clash Verge"
            detailsText: root.viewMode === "overview"
                ? "Loads state only while this popout is open."
                : "Switch mode, selector nodes, and active profile on demand."
            showCloseButton: true

            Component.onCompleted: {
                root.viewMode = "overview"
                root.refreshState(false)
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - popoutRoot.headerHeight - popoutRoot.detailsHeight - Theme.spacingM

                Flickable {
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: contentColumn.implicitHeight
                    clip: true

                    Column {
                        id: contentColumn
                        width: parent.width
                        spacing: Theme.spacingM

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            Repeater {
                                model: [
                                    { key: "overview", label: "Overview" },
                                    { key: "controls", label: "Controls" }
                                ]

                                Rectangle {
                                    required property var modelData
                                    width: 110
                                    height: 34
                                    radius: 17
                                    color: root.viewMode === modelData.key ? Theme.primary : Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        color: root.viewMode === modelData.key ? Theme.primaryText : Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.viewMode = parent.modelData.key
                                    }
                                }
                            }

                            Rectangle {
                                width: 92
                                height: 34
                                radius: 17
                                anchors.verticalCenter: parent.verticalCenter
                                color: refreshArea.containsMouse ? Theme.primaryHover : Theme.surfaceContainerHigh
                                opacity: (root.loading || root.busy) ? 0.6 : 1

                                StyledText {
                                    anchors.centerIn: parent
                                    text: root.loading ? "Loading" : "Refresh"
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                }

                                MouseArea {
                                    id: refreshArea
                                    anchors.fill: parent
                                    enabled: !root.loading && !root.busy
                                    hoverEnabled: true
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.BusyCursor
                                    onClicked: root.refreshState(true)
                                }
                            }
                        }

                        Rectangle {
                            visible: root.errorText.length > 0
                            width: parent.width
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            implicitHeight: errorColumn.implicitHeight + Theme.spacingM * 2

                            Column {
                                id: errorColumn
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingXS

                                StyledText {
                                    text: "Helper Error"
                                    color: Theme.error
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                }

                                StyledText {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: root.errorText
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }

                        Rectangle {
                            visible: root.viewMode === "overview"
                            width: parent.width
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            implicitHeight: overviewColumn.implicitHeight + Theme.spacingM * 2

                            Column {
                                id: overviewColumn
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                StyledText {
                                    text: root.loading ? "Loading Clash Verge state..." : (runtimeState.available ? "Connected to Mihomo" : "Runtime not connected")
                                    color: runtimeState.available ? Theme.primary : Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                }

                                StyledText {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: root.summaryText()
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 1
                                    color: Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.15)
                                }

                                StyledText {
                                    text: "Profile: " + (runtimeState.currentProfileName || "None")
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                StyledText {
                                    text: "Mode: " + root.modeLabel(runtimeState.mode)
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                StyledText {
                                    text: "Tun: " + (runtimeState.tunEnabled ? "Enabled" : "Disabled")
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                StyledText {
                                    text: "System Proxy: " + (runtimeState.systemProxyEnabled ? "Enabled" : "Disabled")
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                StyledText {
                                    text: "Core: " + (runtimeState.coreVersion || "Unavailable")
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                StyledText {
                                    visible: !!runtimeState.runtimeError
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: "Runtime: " + runtimeState.runtimeError
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                Rectangle {
                                    width: 140
                                    height: 34
                                    radius: 17
                                    color: controlsArea.containsMouse ? Theme.primaryHover : Theme.primary

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Open Controls"
                                        color: Theme.primaryText
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                    }

                                    MouseArea {
                                        id: controlsArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.viewMode = "controls"
                                    }
                                }
                            }
                        }

                        Column {
                            visible: root.viewMode === "controls"
                            width: parent.width
                            spacing: Theme.spacingM

                            Rectangle {
                                width: parent.width
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh
                                implicitHeight: modeColumn.implicitHeight + Theme.spacingM * 2

                                Column {
                                    id: modeColumn
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: "Mode"
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                    }

                                    StyledText {
                                        text: root.modeLabel(runtimeState.mode)
                                        color: Theme.primary
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                    }

                                    StyledText {
                                        width: parent.width
                                        wrapMode: Text.WordWrap
                                        text: "Mode is display-only here to avoid drifting out of sync with Clash Verge's own UI state."
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            Rectangle {
                                width: parent.width
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh
                                implicitHeight: groupsColumn.implicitHeight + Theme.spacingM * 2

                                Column {
                                    id: groupsColumn
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: "Selector Groups"
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                    }

                                    StyledText {
                                        visible: root.selectorGroups.length === 0
                                        text: root.loading ? "Loading live selectors..." : "No live selector groups available"
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    Repeater {
                                        model: root.selectorGroups

                                        delegate: Rectangle {
                                            required property var modelData
                                            property string groupName: String(modelData.name || "")
                                            property string currentNode: String(modelData.now || "")
                                            property var groupNodes: modelData.all || []
                                            width: groupsColumn.width
                                            radius: Theme.cornerRadius
                                            color: Theme.surfaceContainerHighest
                                            implicitHeight: groupColumn.implicitHeight + Theme.spacingS * 2

                                            Column {
                                                id: groupColumn
                                                anchors.fill: parent
                                                anchors.margins: Theme.spacingS
                                                spacing: Theme.spacingS

                                                Row {
                                                    width: parent.width
                                                    spacing: Theme.spacingS

                                                    Column {
                                                        width: parent.width - 126
                                                        spacing: 2

                                                        StyledText {
                                                            text: groupName
                                                            color: Theme.surfaceText
                                                            font.pixelSize: Theme.fontSizeSmall
                                                            font.weight: Font.Medium
                                                        }

                                                        StyledText {
                                                            width: parent.width
                                                            wrapMode: Text.WordWrap
                                                            text: "Current: " + currentNode
                                                            color: Theme.surfaceVariantText
                                                            font.pixelSize: Theme.fontSizeSmall
                                                        }
                                                    }

                                                    Rectangle {
                                                        width: 64
                                                        height: 28
                                                        radius: 14
                                                        color: groupTestArea.containsMouse ? Theme.primaryHover : Theme.surfaceContainerHigh
                                                        opacity: root.isTestingThisGroup(groupName) ? 0.7 : 1

                                                        StyledText {
                                                            anchors.centerIn: parent
                                                            text: root.testAllButtonText(groupName)
                                                            color: Theme.surfaceText
                                                            font.pixelSize: Theme.fontSizeSmall
                                                        }

                                                        MouseArea {
                                                            id: groupTestArea
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            enabled: !root.delayTesting && !root.busy
                                                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                            onClicked: root.testGroup(groupName, groupNodes)
                                                        }
                                                    }

                                                    Rectangle {
                                                        width: 46
                                                        height: 28
                                                        radius: 14
                                                        color: groupToggleArea.containsMouse ? Theme.primaryHover : Theme.surfaceContainerHigh

                                                        StyledText {
                                                            anchors.centerIn: parent
                                                            text: root.expandedGroup === groupName ? "Hide" : "Open"
                                                            color: Theme.surfaceText
                                                            font.pixelSize: Theme.fontSizeSmall
                                                        }

                                                        MouseArea {
                                                            id: groupToggleArea
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: root.expandedGroup = root.expandedGroup === groupName ? "" : groupName
                                                        }
                                                    }
                                                }

                                                Column {
                                                    visible: root.expandedGroup === groupName
                                                    width: parent.width
                                                    spacing: Theme.spacingXS

                                                    Repeater {
                                                        model: groupNodes

                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            property string optionNode: String(modelData || "")
                                                            width: groupColumn.width
                                                            radius: Theme.cornerRadius
                                                            color: optionNode === currentNode ? Theme.primaryContainer : Theme.surfaceContainerHigh
                                                            implicitHeight: optionColumn.implicitHeight + Theme.spacingS * 2
                                                            opacity: root.busy ? 0.6 : 1

                                                            Column {
                                                                id: optionColumn
                                                                anchors.fill: parent
                                                                anchors.margins: Theme.spacingS

                                                                Row {
                                                                    width: parent.width
                                                                    spacing: Theme.spacingS

                                                                    StyledText {
                                                                        width: parent.width - 66
                                                                        text: optionNode
                                                                        wrapMode: Text.WordWrap
                                                                        color: optionNode === currentNode ? Theme.primary : Theme.surfaceText
                                                                        font.pixelSize: Theme.fontSizeSmall
                                                                    }

                                                                    Rectangle {
                                                                        width: 58
                                                                        height: 24
                                                                        radius: 12
                                                                        color: delayMouse.containsMouse ? Theme.primaryHover : Theme.surfaceContainerHighest
                                                                        opacity: !root.canTestNode(optionNode) ? 0.45 : (root.isTestingThisNode(groupName, optionNode) ? 0.7 : 1)

                                                                        StyledText {
                                                                            anchors.centerIn: parent
                                                                            text: root.canTestNode(optionNode) ? root.delayButtonText(groupName, optionNode) : "N/A"
                                                                            color: Theme.surfaceText
                                                                            font.pixelSize: Theme.fontSizeSmall
                                                                        }

                                                                        MouseArea {
                                                                            id: delayMouse
                                                                            anchors.fill: parent
                                                                            hoverEnabled: true
                                                                            preventStealing: true
                                                                            propagateComposedEvents: false
                                                                            enabled: root.canTestNode(optionNode) && !root.delayTesting && !root.busy
                                                                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                                            onClicked: root.testDelay(groupName, optionNode)
                                                                        }
                                                                    }
                                                                }

                                                                StyledText {
                                                                    visible: root.delayText(groupName, optionNode).length > 0
                                                                    width: parent.width
                                                                    text: root.delayText(groupName, optionNode)
                                                                    wrapMode: Text.WordWrap
                                                                    color: Theme.surfaceVariantText
                                                                    font.pixelSize: Theme.fontSizeSmall
                                                                }
                                                            }

                                                            MouseArea {
                                                                anchors.fill: parent
                                                                anchors.rightMargin: 66
                                                                enabled: !root.busy && optionNode !== currentNode
                                                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                                onClicked: root.setNode(groupName, optionNode)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                width: parent.width
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHigh
                                implicitHeight: profilesColumn.implicitHeight + Theme.spacingM * 2

                                Column {
                                    id: profilesColumn
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: "Profiles"
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                    }

                                    Repeater {
                                        model: root.profiles

                                        delegate: Rectangle {
                                            required property var modelData
                                            width: profilesColumn.width
                                            radius: Theme.cornerRadius
                                            color: modelData.isCurrent ? Theme.primaryContainer : Theme.surfaceContainerHighest
                                            implicitHeight: profileColumn.implicitHeight + Theme.spacingS * 2
                                            opacity: root.busy ? 0.6 : 1

                                            Column {
                                                id: profileColumn
                                                anchors.fill: parent
                                                anchors.margins: Theme.spacingS
                                                spacing: Theme.spacingXS

                                                StyledText {
                                                    text: modelData.name
                                                    color: modelData.isCurrent ? Theme.primary : Theme.surfaceText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.Medium
                                                }

                                                StyledText {
                                                    text: (modelData.type || "profile") + (modelData.isCurrent ? " • current" : "")
                                                    color: Theme.surfaceVariantText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                enabled: !root.busy && !modelData.isCurrent
                                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                onClicked: root.setProfile(modelData.uid)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
