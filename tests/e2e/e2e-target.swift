// e2e-target: クライアントの E2E テストで、Mac の画面いっぱいに出す「目印の窓」。
//
//   e2e-target <出力ディレクトリ> [--animate]
//
// --animate: 真ん中を、色の変わる四角が 30 コマ/秒で動き続ける（動きのある画面の通信量を測るため）。
//
// メインの画面（RDP の仮想ディスプレイ）を覆い、決まった色の背景と四隅の色付きの四角を描く。
// クライアントの画面にこれがどう映るかで、映っているか・どこまで見えているか・向きを確かめる。
// 真ん中の入力欄（英字の入力ソースだけ）に打たれた文字を typed.txt に、クリックの位置を
// clicks.txt（画面全体の座標、ポイント、左上が原点）に書く。画面の構成が変わったら覆い直す。
// 覆っている範囲は frame.json に、前面かどうか（とそのときの前面のアプリ）は status.json に書く。
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/rdp-e2e/target")
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

/// 背景と四隅の色（0〜255）。壁紙やメニューバーに出てこない、はっきりした色
enum Palette {
    static let background = NSColor(srgbRed: 16 / 255, green: 160 / 255, blue: 80 / 255, alpha: 1)
    static let topLeft = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let topRight = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    static let bottomLeft = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    static let bottomRight = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
}

func write(_ name: String, _ text: String, append: Bool = false) {
    let url = directory.appendingPathComponent(name)
    if append, let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? Data(text.utf8).write(to: url)
    }
}

/// AppKit の座標（左下が原点）から、CoreGraphics の画面全体の座標（左上が原点）へ
func globalTopLeft(_ point: NSPoint) -> CGPoint {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: point.x, y: primaryHeight - point.y)
}

final class TargetView: NSView {
    override var isFlipped: Bool { true }
    /// --animate のときに進む
    var tick = 0

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        bounds.fill()
        if CommandLine.arguments.contains("--animate") {
            let side = min(bounds.width, bounds.height) * 0.25
            let span = bounds.width - side
            let phase = Double(tick % 120) / 120
            let x = span * (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
            NSColor(hue: CGFloat(tick % 90) / 90, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: x, y: bounds.height * 0.2, width: side, height: side).fill()
        }
        let side = (min(bounds.width, bounds.height) * 0.15).rounded()
        let corners: [(NSColor, NSRect)] = [
            (Palette.topLeft, NSRect(x: 0, y: 0, width: side, height: side)),
            (Palette.topRight, NSRect(x: bounds.width - side, y: 0, width: side, height: side)),
            (Palette.bottomLeft, NSRect(x: 0, y: bounds.height - side, width: side, height: side)),
            (Palette.bottomRight, NSRect(x: bounds.width - side, y: bounds.height - side, width: side, height: side)),
        ]
        for (color, rect) in corners {
            color.setFill()
            rect.fill()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        record("down", event)
    }

    override func rightMouseDown(with event: NSEvent) {
        record("right", event)
    }

    private func record(_ kind: String, _ event: NSEvent) {
        guard let window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let point = globalTopLeft(screenPoint)
        write("clicks.txt", String(format: "%@ %.1f %.1f %d\n", kind, point.x, point.y, event.clickCount), append: true)
        // 入力欄の外をクリックしても、キーは入力欄へ行くように
        window.makeFirstResponder((window as? TargetWindow)?.field)
    }
}

/// 選ばれるたびに英字の入力ソースだけにする入力欄。日本語入力が有効だと、打った文字が未確定のまま
/// 残って入力欄の文字にならない（クリックし直すと新しい編集が始まり、制限が外れる）
final class RomanField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        restrictToRoman()
        return became
    }

    func restrictToRoman() {
        (currentEditor() as? NSTextView)?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
    }
}

final class TargetWindow: NSWindow, NSTextFieldDelegate {
    let field = RomanField()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = TargetView()
        contentView = view
        field.font = .monospacedSystemFont(ofSize: 28, weight: .regular)
        field.placeholderString = "E2E"
        field.delegate = self
        view.addSubview(field)
    }

    /// メインの画面を覆い直す
    func cover() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // NSScreen.main はキーウインドウの画面なので、メニューバーのある画面（screens[0]）を使う
        let target = NSScreen.screens.first ?? screen
        setFrame(target.frame, display: true)
        let width = min(600, target.frame.width * 0.6)
        field.frame = NSRect(x: (target.frame.width - width) / 2, y: target.frame.height / 2 - 24, width: width, height: 48)
        contentView?.needsDisplay = true
        let topLeft = globalTopLeft(NSPoint(x: target.frame.minX, y: target.frame.maxY))
        let id = target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        write("frame.json", """
        {"display":\(id?.intValue ?? 0),"x":\(topLeft.x),"y":\(topLeft.y),"w":\(target.frame.width),"h":\(target.frame.height),"scale":\(target.backingScaleFactor)}

        """)
    }

    func controlTextDidChange(_ notification: Notification) {
        write("typed.txt", field.stringValue)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = TargetWindow()
write("typed.txt", "")
write("clicks.txt", "")
window.cover()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(window.field)
app.activate(ignoringOtherApps: true)
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    window.cover()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
}
// キーが入力欄に届くのは、このアプリが前面で入力欄がキーを受けているときだけ。
// 通知の確認パネルなどに前面を取られると届かないので、テストが確かめられるように書いておく
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    let editing = window.firstResponder === window.field.currentEditor()
    if editing { window.field.restrictToRoman() }
    write("status.json", """
    {"active":\(app.isActive),"key":\(window.isKeyWindow),"editing":\(editing),"front":"\(front.replacingOccurrences(of: "\"", with: ""))"}

    """)
}
if CommandLine.arguments.contains("--animate"), let view = window.contentView as? TargetView {
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        view.tick += 1
        view.needsDisplay = true
    }
}
signal(SIGTERM) { _ in exit(0) }
app.run()
