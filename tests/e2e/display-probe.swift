// display-probe: いまの画面の構成とポインタの位置を JSON で出す（E2E テストが Mac 側を確かめるため）。
//
//   display-probe            画面の一覧（online は寝ている画面も含む）とポインタ
//   display-probe warp X Y   ポインタを (X, Y)（全体の座標、ポイント）へ動かしてから出す
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "warp", let x = Double(arguments[2]), let y = Double(arguments[3]) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    usleep(100_000)
}

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &count)
var displays: [[String: Any]] = []
for id in ids.prefix(Int(count)) {
    let bounds = CGDisplayBounds(id)
    var entry: [String: Any] = [
        "id": id,
        "main": CGDisplayIsMain(id) != 0,
        "builtin": CGDisplayIsBuiltin(id) != 0,
        "vendor": CGDisplayVendorNumber(id),
        "x": bounds.origin.x, "y": bounds.origin.y,
        "w": bounds.size.width, "h": bounds.size.height,
    ]
    if let mode = CGDisplayCopyDisplayMode(id) {
        entry["pw"] = mode.pixelWidth
        entry["ph"] = mode.pixelHeight
        entry["hidpi"] = mode.pixelWidth > mode.width
    }
    displays.append(entry)
}
// 寝ている画面は active の一覧に出ないので、online の一覧で寝ているかを見る
var onlineIds = [CGDirectDisplayID](repeating: 0, count: 16)
var onlineCount: UInt32 = 0
CGGetOnlineDisplayList(16, &onlineIds, &onlineCount)
let online: [[String: Any]] = onlineIds.prefix(Int(onlineCount)).map {
    ["id": $0, "asleep": CGDisplayIsAsleep($0) != 0, "vendor": CGDisplayVendorNumber($0)]
}
let mouse = CGEvent(source: nil)?.location ?? .zero
let output: [String: Any] = ["displays": displays, "online": online, "mouse": ["x": mouse.x, "y": mouse.y]]
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
