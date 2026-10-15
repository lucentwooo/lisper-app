import Foundation
import CoreAudio
// Repro for DEBUGGING-LOG 2026-10-10 ("hotkey dead + Space swallowed"). Uses the REAL
// AudioRecorder.swift. Scenario: prime capture on the built-in mic, then the DEFAULT INPUT
// DEVICE switches to a device at a different sample rate while idle (like AirPods connecting),
// start() again, switch back; then a switch MID-take.
// RED   = a start() raises an ObjC exception, or capture never resumes after a mid-take switch.
// GREEN = every take succeeds and captures samples.
// Modes: `state` prints "<defaultInputUID> <builtInRate>"; `cleanup <defaultInputUID> <builtInRate>`
// removes any harness aggregate and restores both (run.sh's EXIT trap calls it). If the original
// input is gone by then (e.g. headphones switched off), the built-in mic stays selected.
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard let builtIn = builtInMic() else { print("no built-in microphone found"); exit(3) }

func restore(defaultInputUID: String, rate: Double) {
    if let agg = existingHarnessAggregate() {
        _ = setDefaultInput(builtIn)
        destroyAggregate(agg)
    }
    _ = setNominalRate(builtIn, rate)
    _ = setDefaultInput(device(forUID: defaultInputUID) ?? builtIn)
}
if args.count > 1, args[1] == "state" { print("\(deviceUID(defaultInputDevice())) \(nominalRate(builtIn))"); exit(0) }
if args.count > 3, args[1] == "cleanup" {
    restore(defaultInputUID: args[2], rate: Double(args[3])!); exit(0)
}

func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func setupFailed(_ what: String) -> Never { print("HARNESS SETUP FAILED: \(what)"); exit(3) }

let originalDefaultUID = deviceUID(defaultInputDevice())
let originalRate = nominalRate(builtIn)
if let stale = existingHarnessAggregate() { destroyAggregate(stale); pump(0.5) }
guard setDefaultInput(builtIn) == noErr else { setupFailed("could not select the built-in mic") }
pump(0.5)

let rec = AudioRecorder()
var ok = true
func take(_ label: String) {
    var startErr: Error?
    let t0 = Date()
    if let exc = lisperCatch({ do { try rec.start() } catch { startErr = error } }) {
        print("\(label): EXCEPTION \(exc)"); ok = false; return
    }
    if let startErr { print("\(label): threw \(startErr)"); ok = false; return }
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    pump(0.6)
    let audio = rec.stop()
    print("\(label): ok start=\(ms)ms samples=\(audio.samples.count)")
    if audio.samples.isEmpty { ok = false }
}
func makeAggregate44k() -> AudioObjectID {
    let agg = createAggregate(wrapping: builtIn)
    guard agg != 0 else { setupFailed("could not create the aggregate device") }
    pump(0.5)
    guard setNominalRate(agg, 44100) == noErr else { setupFailed("aggregate rejected 44.1 kHz") }
    pump(0.5)
    return agg
}

print("built-in \(builtIn) nominal=\(originalRate)")
take("take1 built-in")
let agg = makeAggregate44k()
guard setDefaultInput(agg) == noErr else { setupFailed("could not select the aggregate") }
pump(1.0)
take("take2 agg@44.1k")
take("take3 agg@44.1k")
_ = setDefaultInput(builtIn); pump(0.5)
destroyAggregate(agg)
_ = setNominalRate(builtIn, originalRate); pump(1.0)
take("take4 built-in")

// Mid-take switch: AirPods connect WHILE dictating. Samples must keep flowing after it.
let agg2 = makeAggregate44k()
if let exc = lisperCatch({ try? rec.start() }) { print("take5: EXCEPTION \(exc)"); ok = false }
pump(0.8)
print("take5 switching default input mid-take: \(setDefaultInput(agg2))")
pump(1.5)
let audio = rec.stop()
let secs = Double(audio.samples.count) / 16000
print(String(format: "take5 mid-switch: captured %.2fs of ~2.3s wall time", secs))
if secs < 1.3 { print("take5: TRUNCATED at the switch (capture never resumed)"); ok = false }

restore(defaultInputUID: originalDefaultUID, rate: originalRate)
print(ok ? "GREEN" : "RED")
exit(ok ? 0 : 1)
