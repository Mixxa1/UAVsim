import AppKit
import Foundation

/// Запускает standalone CADNext (Qt/Coin3D приложение) как внешний процесс.
/// Swift-симулятор не встраивает Qt/Coin3D CAD UI — единственная точка
/// интеграции на этом этапе — этот лаунчер.
@MainActor
final class CADNextLauncherService {
    static let shared = CADNextLauncherService()

    private static let buildCommand = """
    cmake -S CADNext -B CADNext/build-gui-occt -DCADNEXT_BUILD_APP=ON -DCADNEXT_WITH_QT=ON -DCADNEXT_WITH_COIN3D=ON -DCADNEXT_WITH_OCCT=ON
    cmake --build CADNext/build-gui-occt
    """

    /// Относительные пути к собранному бинарнику внутри репозитория.
    /// build-gui-occt — основная CAD-сборка: Sketch on Face и Cut
    /// Extrude требуют OCCT BRep backend. build-gui остаётся запасным
    /// viewer-only вариантом без boolean cut.
    private static let relativeExecutablePaths = [
        "CADNext/build-gui-occt/app/cadnext_app",
        "CADNext/build-gui/app/cadnext_app"
    ]

    func openCADNext() {
        guard let executable = locateExecutable() else {
            presentNotFoundAlert()
            return
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        do {
            try process.run()
        } catch {
            presentLaunchFailedAlert(executable: executable, error: error)
        }
    }

    func locateExecutable() -> URL? {
        let fileManager = FileManager.default
        for candidate in candidateExecutables() {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                print("[CADNextLauncher] Selected: \(candidate.path)")
                return candidate
            }
        }
        print("[CADNextLauncher] No cadnext_app found among candidates")
        return nil
    }

    private func candidateExecutables() -> [URL] {
        var candidates: [URL] = []

        // Будущая упаковка: бинарник внутри bundle приложения.
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/cadnext_app"))

        for root in repositoryRootCandidates() {
            for relativePath in Self.relativeExecutablePaths {
                candidates.append(root.appendingPathComponent(relativePath))
            }
        }
        return candidates
    }

    private func repositoryRootCandidates() -> [URL] {
        var roots: [URL] = []

        // Dev-сценарий: этот файл лежит в <repo>/DroneUAVDemo/Services/, и
        // именно на dev-машине существует локально собранный cadnext_app.
        let sourceFile = URL(fileURLWithPath: #filePath)
        roots.append(sourceFile
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // DroneUAVDemo
            .deletingLastPathComponent()) // корень репозитория

        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return roots
    }

    private func presentNotFoundAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("cadnext.alert.notFound.title", comment: "")
        let searchedPaths = candidateExecutables()
            .map { $0.path }
            .joined(separator: "\n")
        alert.informativeText = String(
            format: NSLocalizedString("cadnext.alert.notFound.message", comment: ""),
            searchedPaths,
            Self.buildCommand
        )
        alert.runModal()
    }

    private func presentLaunchFailedAlert(executable: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("cadnext.alert.launchFailed.title", comment: "")
        alert.informativeText = "\(executable.path)\n\n\(error.localizedDescription)"
        alert.runModal()
    }
}
