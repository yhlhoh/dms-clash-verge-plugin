import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // =========================================================================
    // ⬇️ 后端逻辑：一字未改 ⬇️
    // =========================================================================

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
            spacing: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                name: runtimeState.available ? "vpn_lock" : "vpn_key_off"
                color: runtimeState.available ? Theme.primary : Theme.surfaceVariantText
                size: Theme.iconSize - 2
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: 200 } }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                StyledText {
                    text: root.barLabel
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            anchors.horizontalCenter: parent.horizontalCenter

            DankIcon {
                name: runtimeState.available ? "vpn_lock" : "vpn_key_off"
                color: runtimeState.available ? Theme.primary : Theme.surfaceVariantText
                size: Theme.iconSize - 2
                anchors.horizontalCenter: parent.horizontalCenter
                Behavior on color { ColorAnimation { duration: 200 } }
            }
        }
    }

    popoutWidth: 460
    popoutHeight: root.viewMode === "overview" ? 430 : 660

    popoutContent: Component {
        PopoutComponent {
            id: popoutRoot
            headerText: "Clash Verge"
            detailsText: root.viewMode === "overview" 
                ? "Current Runtime Status" 
                : "Manage Nodes & Profiles"
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
                    contentHeight: contentColumn.implicitHeight + Theme.spacingL
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height

                    Column {
                        id: contentColumn
                        width: parent.width
                        spacing: Theme.spacingM

                        Row {
                            width: parent.width
                            height: 40
                            spacing: Theme.spacingM

                            Rectangle {
                                width: parent.width - refreshBtn.width - Theme.spacingM
                                height: parent.height
                                radius: height / 2
                                color: Theme.surfaceContainerHighest

                                Row {
                                    anchors.fill: parent
                                    anchors.margins: 4
                                    spacing: 4

                                    Repeater {
                                        model: [
                                            { key: "overview", label: "Overview" },
                                            { key: "controls", label: "Controls" }
                                        ]

                                        Rectangle {
                                            required property var modelData
                                            width: (parent.width - 4) / 2
                                            height: parent.height
                                            radius: height / 2
                                            color: root.viewMode === modelData.key ? Theme.primary : "transparent"
                                            Behavior on color { ColorAnimation { duration: 150 } }

                                            StyledText {
                                                anchors.centerIn: parent
                                                text: modelData.label
                                                color: root.viewMode === modelData.key ? Theme.primaryText : Theme.surfaceText
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: root.viewMode === modelData.key ? Font.DemiBold : Font.Normal
                                                Behavior on color { ColorAnimation { duration: 150 } }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.viewMode = parent.modelData.key
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                id: refreshBtn
                                width: 40
                                height: 40
                                radius: 20
                                color: refreshArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                opacity: (root.loading || root.busy) ? 0.5 : 1
                                Behavior on color { ColorAnimation { duration: 150 } }

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: "refresh"
                                    color: Theme.surfaceText
                                    size: Theme.iconSize - 4
                                    RotationAnimation on rotation {
                                        loops: Animation.Infinite
                                        from: 0; to: 360; duration: 1000
                                        running: root.loading
                                    }
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
                            color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.15)
                            border.color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.3)
                            border.width: 1
                            implicitHeight: errorColumn.implicitHeight + Theme.spacingM * 2

                            Column {
                                id: errorColumn
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingXS

                                Row {
                                    spacing: Theme.spacingS
                                    DankIcon { name: "error"; color: Theme.error; size: Theme.iconSize - 4 }
                                    StyledText {
                                        text: "Helper Error"
                                        color: Theme.error
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                    }
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

                        // ==========================================
                        // OVERVIEW 面板
                        // ==========================================
                        Rectangle {
                            visible: root.viewMode === "overview"
                            width: parent.width
                            radius: Theme.cornerRadius
                            color: "transparent"
                            border.color: Theme.surfaceContainerHigh
                            border.width: 1
                            implicitHeight: overviewColumn.implicitHeight + Theme.spacingL * 2

                            Column {
                                id: overviewColumn
                                anchors.fill: parent
                                anchors.margins: Theme.spacingL
                                spacing: Theme.spacingM

                                Row {
                                    spacing: Theme.spacingS
                                    Rectangle {
                                        width: 12; height: 12; radius: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: root.loading ? Theme.surfaceVariantText : (runtimeState.available ? Theme.primary : Theme.error)
                                    }
                                    StyledText {
                                        text: root.loading ? "Loading state..." : (runtimeState.available ? "Connected to Core" : "Runtime Disconnected")
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: root.summaryText()
                                    color: Theme.primary
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                }

                                Rectangle {
                                    width: parent.width; height: 1; color: Theme.surfaceContainerHighest
                                }

                                Grid {
                                    id: overviewGrid
                                    width: parent.width
                                    columns: 2
                                    columnSpacing: Theme.spacingM
                                    rowSpacing: Theme.spacingM

                                    Column {
                                        width: (overviewGrid.width - overviewGrid.columnSpacing) / overviewGrid.columns
                                        spacing: 2

                                        StyledText {
                                            text: "Profile"
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                        }

                                        StyledText {
                                            text: runtimeState.currentProfileName || "None"
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                        }
                                    }

                                    Column {
                                        width: (overviewGrid.width - overviewGrid.columnSpacing) / overviewGrid.columns
                                        spacing: 2

                                        StyledText {
                                            text: "Mode"
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                        }

                                        StyledText {
                                            text: root.modeLabel(runtimeState.mode)
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                        }
                                    }

                                    Column {
                                        width: (overviewGrid.width - overviewGrid.columnSpacing) / overviewGrid.columns
                                        spacing: 2

                                        StyledText {
                                            text: "Tun Mode"
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                        }

                                        StyledText {
                                            text: runtimeState.tunEnabled ? "Enabled" : "Disabled"
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                        }
                                    }

                                    Column {
                                        width: (overviewGrid.width - overviewGrid.columnSpacing) / overviewGrid.columns
                                        spacing: 2

                                        StyledText {
                                            text: "System Proxy"
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                        }

                                        StyledText {
                                            text: runtimeState.systemProxyEnabled ? "Enabled" : "Disabled"
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                        }
                                    }

                                    Column {
                                        width: (overviewGrid.width - overviewGrid.columnSpacing) / overviewGrid.columns
                                        spacing: 2

                                        StyledText {
                                            text: "Core Version"
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                        }

                                        StyledText {
                                            text: runtimeState.coreVersion || "Unknown"
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                        }
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 36
                                    radius: Theme.cornerRadius - 4
                                    color: controlsArea.containsMouse ? Theme.primaryHover : Theme.primary
                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "Manage Configuration"
                                        color: Theme.primaryText
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.DemiBold
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

                        // ==========================================
                        // CONTROLS 面板
                        // ==========================================
                        Column {
                            visible: root.viewMode === "controls"
                            width: parent.width
                            spacing: Theme.spacingL

                            // 1. Proxies 卡片
                            Column {
                                width: parent.width
                                spacing: Theme.spacingS

                                StyledText {
                                    text: "Proxy Groups"
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    leftPadding: 4
                                }

                                StyledText {
                                    visible: root.selectorGroups.length === 0
                                    text: root.loading ? "Fetching proxies..." : "No selector groups available."
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    leftPadding: 4
                                }

                                Repeater {
                                    model: root.selectorGroups

                                    delegate: Rectangle {
                                        required property var modelData
                                        property string groupName: String(modelData.name || "")
                                        property string currentNode: String(modelData.now || "")
                                        property var groupNodes: modelData.all || []
                                        property bool isExpanded: root.expandedGroup === groupName

                                        width: parent.width
                                        radius: Theme.cornerRadius
                                        color: "transparent"
                                        border.color: isExpanded ? Theme.primary : Theme.surfaceContainerHigh
                                        border.width: isExpanded ? 1 : 1
                                        implicitHeight: groupInner.implicitHeight
                                        clip: true
                                        Behavior on border.color { ColorAnimation { duration: 200 } }

                                        Column {
                                            id: groupInner
                                            width: parent.width
                                            
                                            Rectangle {
                                                width: parent.width
                                                height: 56
                                                color: "transparent"

                                                MouseArea {
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.expandedGroup = isExpanded ? "" : groupName
                                                    
                                                    Rectangle {
                                                        anchors.fill: parent
                                                        color: Theme.surfaceText
                                                        opacity: parent.containsMouse ? 0.05 : 0
                                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                                    }
                                                }

                                                Row {
                                                    anchors.fill: parent
                                                    anchors.margins: Theme.spacingM
                                                    spacing: Theme.spacingM

                                                    Column {
                                                        width: parent.width - testAllBtn.width - iconInd.width - Theme.spacingM * 2
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        spacing: 2
                                                        StyledText {
                                                            text: groupName
                                                            color: Theme.surfaceText
                                                            font.pixelSize: Theme.fontSizeMedium
                                                            font.weight: Font.Medium
                                                            elide: Text.ElideRight
                                                            width: parent.width
                                                        }
                                                        StyledText {
                                                            text: currentNode
                                                            color: Theme.primary
                                                            font.pixelSize: Theme.fontSizeSmall - 1
                                                            elide: Text.ElideRight
                                                            width: parent.width
                                                        }
                                                    }

                                                    Rectangle {
                                                        id: testAllBtn
                                                        width: 60; height: 28; radius: 14
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        color: groupTestArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                                        border.color: Theme.outline
                                                        border.width: 1
                                                        opacity: root.isTestingThisGroup(groupName) ? 0.6 : 1
                                                        z: 2

                                                        StyledText {
                                                            anchors.centerIn: parent
                                                            text: root.testAllButtonText(groupName)
                                                            color: Theme.surfaceText
                                                            font.pixelSize: Theme.fontSizeSmall - 1
                                                            font.weight: Font.Medium
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

                                                    DankIcon {
                                                        id: iconInd
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        name: isExpanded ? "expand_less" : "expand_more"
                                                        color: Theme.surfaceVariantText
                                                        size: Theme.iconSize - 2
                                                    }
                                                }
                                            }

                                            Column {
                                                visible: isExpanded
                                                width: parent.width
                                                padding: Theme.spacingS
                                                bottomPadding: Theme.spacingM
                                                spacing: 2

                                                Repeater {
                                                    model: groupNodes

                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        property string optionNode: String(modelData || "")
                                                        property bool isCurrent: optionNode === currentNode
                                                        
                                                        width: parent.width
                                                        height: 40
                                                        radius: 6
                                                        color: isCurrent ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1) : (nodeArea.containsMouse ? Theme.surfaceContainerHighest : "transparent")
                                                        Behavior on color { ColorAnimation { duration: 150 } }

                                                        Row {
                                                            anchors.fill: parent
                                                            anchors.leftMargin: Theme.spacingM
                                                            anchors.rightMargin: Theme.spacingS
                                                            spacing: Theme.spacingS

                                                            StyledText {
                                                                width: parent.width - delayBadge.width - Theme.spacingS
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                text: optionNode
                                                                elide: Text.ElideRight
                                                                color: isCurrent ? Theme.primary : Theme.surfaceText
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                font.weight: isCurrent ? Font.DemiBold : Font.Normal
                                                            }

                                                            Rectangle {
                                                                id: delayBadge
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                width: delayTxt.implicitWidth + 16
                                                                height: 24
                                                                radius: 12
                                                                color: {
                                                                    if (delayMouse.containsMouse) return Theme.surfaceContainerHighest
                                                                    let dt = root.delayText(groupName, optionNode)
                                                                    if (dt.includes("ms")) return Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)
                                                                    if (dt.includes("Timeout") || dt.includes("Error")) return Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.15)
                                                                    return "transparent"
                                                                }
                                                                border.color: Theme.surfaceContainerHighest
                                                                border.width: 1
                                                                opacity: !root.canTestNode(optionNode) ? 0.3 : 1
                                                                Behavior on color { ColorAnimation { duration: 150 } }

                                                                StyledText {
                                                                    id: delayTxt
                                                                    anchors.centerIn: parent
                                                                    text: {
                                                                        let dt = root.delayText(groupName, optionNode)
                                                                        return dt ? dt : (root.canTestNode(optionNode) ? "Test" : "N/A")
                                                                    }
                                                                    color: {
                                                                        let dt = root.delayText(groupName, optionNode)
                                                                        if (dt.includes("ms")) return Theme.primary
                                                                        if (dt.includes("Timeout") || dt.includes("Error")) return Theme.error
                                                                        return Theme.surfaceVariantText
                                                                    }
                                                                    font.pixelSize: Theme.fontSizeSmall - 2
                                                                    font.weight: Font.Medium
                                                                }

                                                                MouseArea {
                                                                    id: delayMouse
                                                                    anchors.fill: parent
                                                                    hoverEnabled: true
                                                                    enabled: root.canTestNode(optionNode) && !root.delayTesting && !root.busy
                                                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                                    onClicked: root.testDelay(groupName, optionNode)
                                                                }
                                                            }
                                                        }

                                                        MouseArea {
                                                            id: nodeArea
                                                            anchors.fill: parent
                                                            anchors.rightMargin: delayBadge.width + Theme.spacingS
                                                            enabled: !root.busy && !isCurrent
                                                            hoverEnabled: true
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

                            // 2. Profiles 卡片
                            Column {
                                width: parent.width
                                spacing: Theme.spacingS

                                StyledText {
                                    text: "Profiles"
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    leftPadding: 4
                                }

                                Rectangle {
                                    width: parent.width
                                    radius: Theme.cornerRadius
                                    color: "transparent"
                                    border.color: Theme.surfaceContainerHigh
                                    border.width: 1
                                    implicitHeight: profileList.implicitHeight + Theme.spacingS * 2

                                    Column {
                                        id: profileList
                                        anchors.fill: parent
                                        anchors.margins: Theme.spacingS
                                        spacing: 2

                                        Repeater {
                                            model: root.profiles

                                            delegate: Rectangle {
                                                required property var modelData
                                                width: parent.width
                                                height: 48
                                                radius: 6
                                                color: modelData.isCurrent ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1) : (profileArea.containsMouse ? Theme.surfaceContainerHighest : "transparent")
                                                Behavior on color { ColorAnimation { duration: 150 } }

                                                Row {
                                                    anchors.fill: parent
                                                    anchors.margins: Theme.spacingM
                                                    spacing: Theme.spacingM

                                                    DankIcon {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        name: modelData.isCurrent ? "radio_button_checked" : "radio_button_unchecked"
                                                        color: modelData.isCurrent ? Theme.primary : Theme.surfaceVariantText
                                                        size: Theme.iconSize - 2
                                                    }

                                                    Column {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        spacing: 0
                                                        StyledText {
                                                            text: modelData.name
                                                            color: modelData.isCurrent ? Theme.primary : Theme.surfaceText
                                                            font.pixelSize: Theme.fontSizeSmall
                                                            font.weight: modelData.isCurrent ? Font.DemiBold : Font.Normal
                                                        }
                                                        StyledText {
                                                            text: modelData.type || "profile"
                                                            color: Theme.surfaceVariantText
                                                            font.pixelSize: Theme.fontSizeSmall - 2
                                                        }
                                                    }
                                                }

                                                MouseArea {
                                                    id: profileArea
                                                    anchors.fill: parent
                                                    enabled: !root.busy && !modelData.isCurrent
                                                    hoverEnabled: true
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
}
