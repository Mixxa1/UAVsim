import Foundation
import QuartzCore

@main
struct AudioPreparationProbe {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("uavsim-audio-preparation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var failures: [String] = []

        for scenario in ["pack", "missing-pack", "missing-airflow"] {
            let bundleURL = temporary.appendingPathComponent("\(scenario).bundle")
            let resources = bundleURL.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": "uavsim.probe.\(scenario)", "CFBundlePackageType": "BNDL"]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try plistData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
            if scenario != "missing-pack" {
                try FileManager.default.copyItem(
                    at: root.appendingPathComponent("DroneUAVDemo/Resources/Audio"),
                    to: resources.appendingPathComponent("Audio")
                )
                if scenario == "missing-airflow" {
                    try FileManager.default.removeItem(
                        at: resources.appendingPathComponent("Audio/Aero/Airflow/airflow_loop.wav")
                    )
                }
            }
            let bundle = Bundle(url: bundleURL)!
            let service = SimulationAudioService()
            let setupStarted = CACurrentMediaTime()
            service.prepare(bundle: bundle)
            let setupMs = (CACurrentMediaTime() - setupStarted) * 1000
            if service.isPrepared { failures.append("\(scenario): decoding ran synchronously") }
            service.prepare(bundle: bundle) // In-flight preparation is idempotent.
            if scenario == "missing-airflow" { service.stop() } // Installation after exit is safe.
            let waitStarted = CACurrentMediaTime()
            var yields = 0
            while !service.isPrepared && CACurrentMediaTime() - waitStarted < 10 {
                try await Task.sleep(nanoseconds: 1_000_000)
                yields += 1
            }
            if !service.isPrepared { failures.append("\(scenario): preparation timed out") }
            if !service.canPlay(.airflowLoop) { failures.append("\(scenario): airflow missing") }
            if scenario == "missing-pack" {
                if !service.catalog.isEmpty { failures.append("Missing pack should keep an empty catalog") }
            } else {
                for asset in service.catalog.manifest.assets {
                    if let id = AudioAssetID(rawValue: asset.id), !service.canPlay(id) {
                        failures.append("\(scenario): \(id.rawValue) did not decode")
                    }
                }
            }
            service.prepare(bundle: bundle)
            if !service.isPrepared { failures.append("Repeated prepare invalidated ready buffers") }
            service.stop()
            print(String(format: "%@: setup %.2f ms, async wait %.2f ms, main actor yielded %d times",
                         scenario, setupMs, (CACurrentMediaTime() - waitStarted) * 1000, yields))
        }
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
        print("PASS: background decoding, complete pack, missing-pack/clip fallback, repeated prepare, stop during load")
    }
}
