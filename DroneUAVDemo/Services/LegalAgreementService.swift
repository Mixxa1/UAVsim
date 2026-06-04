import Foundation

enum LegalDocumentKind: String, Codable, Equatable, Hashable {
    case eula
    case tos
}

struct LegalDocumentBundle: Codable, Equatable {
    var schemaVersion: Int
    var documents: [LegalDocument]
}

struct LegalDocument: Codable, Identifiable, Equatable {
    var kind: LegalDocumentKind
    var version: String
    var title: String
    var subtitle: String?
    var body: [String]

    var id: String {
        "\(kind.rawValue)-\(version)"
    }
}

struct LegalAcceptanceRecord: Codable, Equatable {
    var schemaVersion: Int
    var acceptedAt: Date
    var acceptedAppVersion: String
    var acceptedBuildNumber: String
    var acceptedDocuments: [AcceptedLegalDocument]
}

struct AcceptedLegalDocument: Codable, Equatable, Hashable {
    var kind: LegalDocumentKind
    var version: String
}

enum LegalAgreementError: LocalizedError {
    case missingBundledLegalDocuments
    case emptyBundledLegalDocuments

    var errorDescription: String? {
        switch self {
        case .missingBundledLegalDocuments:
            return "Bundled LegalDocuments.json was not found."
        case .emptyBundledLegalDocuments:
            return "Bundled LegalDocuments.json contains no legal documents."
        }
    }
}

final class LegalAgreementService {
    private let fileManager: FileManager

    private let appFolderName = "DroneUAVDemo"
    private let internalStoreFolderName = "InternalStore"
    private let legalFolderName = "Legal"
    private let acceptanceFileName = "legal_acceptance.json"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadBundledDocuments() throws -> LegalDocumentBundle {
        let url = try bundledLegalDocumentsURL()
        let data = try Data(contentsOf: url)

        let bundle = try JSONDecoder().decode(LegalDocumentBundle.self, from: data)

        guard !bundle.documents.isEmpty else {
            throw LegalAgreementError.emptyBundledLegalDocuments
        }

        return bundle
    }

    func hasAcceptedCurrentDocuments() -> Bool {
        do {
            let bundle = try loadBundledDocuments()
            let record = try loadAcceptanceRecord()

            let requiredDocuments = Set(
                bundle.documents.map {
                    AcceptedLegalDocument(kind: $0.kind, version: $0.version)
                }
            )

            let acceptedDocuments = Set(record.acceptedDocuments)

            return requiredDocuments.isSubset(of: acceptedDocuments)
        } catch {
            return false
        }
    }

    func saveAcceptance(for bundle: LegalDocumentBundle) throws {
        let record = LegalAcceptanceRecord(
            schemaVersion: 1,
            acceptedAt: Date(),
            acceptedAppVersion: Self.appVersion,
            acceptedBuildNumber: Self.buildNumber,
            acceptedDocuments: bundle.documents.map {
                AcceptedLegalDocument(kind: $0.kind, version: $0.version)
            }
        )

        let directoryURL = try legalDirectoryURL()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(record)
        try data.write(to: try acceptanceFileURL(), options: [.atomic])
    }

    func acceptanceFileExists() -> Bool {
        guard let url = try? acceptanceFileURL() else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func deleteAcceptanceForDebug() throws {
        let url = try acceptanceFileURL()

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func acceptanceFileDebugPath() -> String {
        (try? acceptanceFileURL().path) ?? "Unavailable"
    }

    private func loadAcceptanceRecord() throws -> LegalAcceptanceRecord {
        let data = try Data(contentsOf: try acceptanceFileURL())

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(LegalAcceptanceRecord.self, from: data)
    }

    private func bundledLegalDocumentsURL() throws -> URL {
        if let url = Bundle.main.url(
            forResource: "LegalDocuments",
            withExtension: "json"
        ) {
            return url
        }

        if let url = Bundle.main.url(
            forResource: "LegalDocuments",
            withExtension: "json",
            subdirectory: "Legal"
        ) {
            return url
        }

        throw LegalAgreementError.missingBundledLegalDocuments
    }

    private func legalDirectoryURL() throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return applicationSupportURL
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(internalStoreFolderName, isDirectory: true)
            .appendingPathComponent(legalFolderName, isDirectory: true)
    }

    private func acceptanceFileURL() throws -> URL {
        try legalDirectoryURL()
            .appendingPathComponent(acceptanceFileName, isDirectory: false)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
