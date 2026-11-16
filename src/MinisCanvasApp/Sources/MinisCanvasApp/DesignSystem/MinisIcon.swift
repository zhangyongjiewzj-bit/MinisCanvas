import Foundation

/// Stable semantic icon IDs. Consumers never depend on the upstream filename.
public enum MinisIcon: String, CaseIterable, Sendable {
    case archive
    case attachment
    case back
    case branch
    case cancel
    case caretDown
    case caretLeft
    case caretRight
    case check
    case close
    case command
    case copy
    case database
    case delete
    case document
    case documentSearch
    case download
    case edit
    case externalLink
    case eye
    case eyeOff
    case file
    case filter
    case folder
    case folderAdd
    case globe
    case grid
    case help
    case image
    case images
    case info
    case library
    case link
    case lock
    case mail
    case menu
    case message
    case messages
    case microphone
    case more
    case next
    case pause
    case pin
    case play
    case plugin
    case refresh
    case retry
    case search
    case send
    case settings
    case share
    case sidebarLeft
    case sidebarRight
    case spinner
    case stop
    case success
    case warning
    case terminal
    case task
    case upload
    case user
    case users
    case video
    case volume
    case add
    case remove
    case server
    case schedule
    case analytics
    case target
    case status
    case power
    case activity
    case unavailable
    case connection
    case wandSparkles
    case box
    case cpu
    case handOpen

    /// Name of the compile-time asset in KeylineIcons.xcassets.
    public var assetName: String { rawValue }

    /// Fixed upstream source filename, retained for provenance and review.
    public var upstreamFilename: String {
        switch self {
        case .archive: return "archive"
        case .attachment: return "file-plus"
        case .back: return "circle-arrow-left"
        case .branch: return "git-branch"
        case .cancel: return "square-x"
        case .caretDown: return "caret-down"
        case .caretLeft: return "caret-left"
        case .caretRight: return "caret-right"
        case .check: return "circle-check"
        case .close: return "circle-x"
        case .command: return "square-menu"
        case .copy: return "copy"
        case .database: return "database"
        case .delete: return "bin"
        case .document: return "file-text"
        case .documentSearch: return "search-2"
        case .download: return "file-arrow-down"
        case .edit: return "pen"
        case .externalLink: return "square-arrow-up-right"
        case .eye: return "eye"
        case .eyeOff: return "eye-off"
        case .file: return "file"
        case .filter: return "filter"
        case .folder: return "folder"
        case .folderAdd: return "folder-plus"
        case .globe: return "globe"
        case .grid: return "grid-2x2"
        case .help: return "circle-question"
        case .image: return "image"
        case .images: return "images"
        case .info: return "info"
        case .library: return "package"
        case .link: return "route"
        case .lock: return "lock"
        case .mail: return "mail"
        case .menu: return "circle-menu"
        case .message: return "message"
        case .messages: return "messages"
        case .microphone: return "mic"
        case .more: return "circle-more-horizontal"
        case .next: return "circle-arrow-right"
        case .pause: return "pause"
        case .pin: return "bookmark"
        case .play: return "play"
        case .plugin: return "shapes"
        case .refresh: return "git-refresh"
        case .retry: return "git-return"
        case .search: return "search"
        case .send: return "file-arrow-up"
        case .settings: return "settings"
        case .share: return "share"
        case .sidebarLeft: return "panel-left"
        case .sidebarRight: return "panel-right"
        case .spinner: return "loader"
        case .stop: return "stop"
        case .success: return "circle-progress-check"
        case .warning: return "triangle-alert"
        case .terminal: return "square-terminal"
        case .task: return "receipt"
        case .upload: return "arrow-up-dashed-panel"
        case .user: return "user"
        case .users: return "users"
        case .video: return "list-video"
        case .volume: return "volume"
        case .add: return "circle-plus"
        case .remove: return "circle-minus"
        case .server: return "server"
        case .schedule: return "calendar"
        case .analytics: return "square-bar-chart"
        case .target: return "circle-navigation"
        case .status: return "circle"
        case .power: return "toggle-off"
        case .activity: return "square-activity"
        case .unavailable: return "circle-off"
        case .connection: return "signal"
        case .wandSparkles: return "wand-sparkles"
        case .box: return "box"
        case .cpu: return "cpu"
        case .handOpen: return "hand-open"
        }
    }

    /// Allowlisted SF Symbol used only when a packaged asset is unavailable.
    public var fallbackSystemName: String {
        switch self {
        case .archive: return "archivebox"
        case .attachment: return "paperclip"
        case .back: return "chevron.left"
        case .branch: return "arrow.triangle.branch"
        case .cancel, .close: return "xmark.circle"
        case .caretDown: return "chevron.down"
        case .caretLeft: return "chevron.left"
        case .caretRight: return "chevron.right"
        case .check, .success: return "checkmark.circle"
        case .command: return "command"
        case .copy: return "doc.on.doc"
        case .database: return "externaldrive"
        case .delete: return "trash"
        case .document: return "doc.text"
        case .documentSearch: return "doc.text.magnifyingglass"
        case .download: return "square.and.arrow.down"
        case .edit: return "pencil"
        case .externalLink: return "arrow.up.right.square"
        case .eye: return "eye"
        case .eyeOff: return "eye.slash"
        case .file: return "doc"
        case .filter: return "line.3.horizontal.decrease"
        case .folder: return "folder"
        case .folderAdd: return "folder.badge.plus"
        case .globe: return "globe"
        case .grid: return "square.grid.2x2"
        case .help: return "questionmark.circle"
        case .image, .images: return "photo"
        case .info: return "info.circle"
        case .library: return "shippingbox"
        case .link: return "link"
        case .lock: return "lock"
        case .mail: return "envelope"
        case .menu: return "ellipsis.circle"
        case .message: return "bubble.left"
        case .messages: return "bubble.left.and.bubble.right"
        case .microphone: return "mic"
        case .more: return "ellipsis.circle"
        case .next: return "chevron.right"
        case .pause: return "pause.circle"
        case .pin: return "pin"
        case .play: return "play.circle"
        case .plugin: return "puzzlepiece.extension"
        case .refresh, .retry: return "arrow.clockwise"
        case .search: return "magnifyingglass"
        case .send: return "arrow.up.circle"
        case .settings: return "gearshape"
        case .share: return "square.and.arrow.up"
        case .sidebarLeft: return "sidebar.leading"
        case .sidebarRight: return "sidebar.trailing"
        case .spinner: return "progress.indicator"
        case .stop: return "stop.circle"
        case .warning: return "exclamationmark.triangle"
        case .terminal: return "terminal"
        case .task: return "checklist"
        case .upload: return "arrow.up"
        case .user: return "person"
        case .users: return "person.2"
        case .video: return "video"
        case .volume: return "speaker.wave.2"
        case .add: return "plus.circle"
        case .remove: return "minus.circle"
        case .server: return "server.rack"
        case .schedule: return "calendar"
        case .analytics: return "chart.bar"
        case .target: return "scope"
        case .status: return "circle"
        case .power: return "power"
        case .activity: return "waveform"
        case .unavailable: return "circle.slash"
        case .connection: return "wifi"
        case .wandSparkles: return "wand.and.stars"
        case .box: return "cube.transparent"
        case .cpu: return "cpu"
        case .handOpen: return "hand.raised.circle"
        }
    }
}
