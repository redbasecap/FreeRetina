import AppKit
import CoreGraphics
import Foundation

let usage = """
usage:
  freeretina
      Menu bar app with the setup assistant (also what FreeRetina.app runs).
  freeretina displays
      List displays, their native panel mode and the FreeRetina resolutions they would get.
  freeretina run [--display ID] [--looks WxH] [--order rgb|bgr] [--strength 0..1.5] [--seconds N] [--supervised]
      Create the FreeRetina display for a physical monitor and drive the panel subpixel-accurately.
      --looks     initial "looks like" resolution (default: ~87% of native). Change it later in
                  System Settings > Displays like any other resolution.
      --order     panel stripe order (default rgb). Check with `compare` + a loupe if unsure.
      --strength  subpixel detail strength (default 1; 0 = plain HiDPI area scaling).
      --seconds   exit automatically after N seconds (safety for first tries).
      --supervised  machine-readable status on stdout; exits with the parent process.
      Ctrl-C restores the previous display setup.
  freeretina compare [--out DIR] [--scale S] [--order rgb|bgr] [--strength X]
      Offline proof: renders text natively, as HiDPI, and as FreeRetina; writes PNGs.
"""

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func require<T>(_ value: T?, _ message: @autoclosure () -> String) -> T {
    guard let value else { fail(message()) }
    return value
}

let order = require(SubpixelOrder(rawValue: option("--order") ?? "rgb"), "--order must be rgb or bgr")
let strength = require(Float(option("--strength") ?? "1"), "--strength must be a number")

switch args.first {
case nil:
    AppController.run()

case "displays":
    for display in PhysicalDisplay.all() {
        print(display.summary)
    }

case "compare":
    let out = URL(fileURLWithPath: option("--out") ?? "compare")
    let scale = require(Double(option("--scale") ?? "2"), "--scale must be a number")
    do { try Compare.run(outDir: out, scale: scale, order: order, strength: strength) } catch { fail("compare: \(error)") }

case "run":
    let all = PhysicalDisplay.all()
    let target: PhysicalDisplay
    if let id = option("--display") {
        target = require(all.first { String($0.id) == id }, "no display \(id); see `freeretina displays`")
    } else {
        target = require(all.first { !$0.isBuiltin }, "no external display found; pass --display ID")
    }
    var looks: CGSize?
    if let spec = option("--looks") {
        let parts = spec.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { fail("--looks must be WxH") }
        looks = CGSize(width: parts[0], height: parts[1])
    }
    let seconds = option("--seconds").map { require(Double($0), "--seconds must be a number") }
    LiveSession.start(EngineOptions(physical: target, looks: looks, order: order, strength: strength,
                                    seconds: seconds, supervised: args.contains("--supervised")))

default:
    print(usage)
}
