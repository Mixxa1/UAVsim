import Foundation

@MainActor
final class LegalAgreementViewModel: ObservableObject {
    @Published private(set) var documents: [LegalDocument] = []
    @Published private(set) var isAccepted: Bool = false
    @Published var loadingError: String?

    private let service: LegalAgreementService
    private var bundle: LegalDocumentBundle?

    init(service: LegalAgreementService = LegalAgreementService()) {
        self.service = service
        reload()
    }

    func reload() {
        do {
            let loadedBundle = try service.loadBundledDocuments()
            bundle = loadedBundle
            documents = loadedBundle.documents
            isAccepted = service.hasAcceptedCurrentDocuments()
            loadingError = nil
        } catch {
            bundle = nil
            documents = []
            isAccepted = false
            loadingError = "Не удалось загрузить EULA/TOS: \(error.localizedDescription)"
        }
    }

    func accept() {
        guard let bundle else {
            loadingError = "Невозможно принять соглашение: документы не загружены."
            isAccepted = false
            return
        }

        do {
            try service.saveAcceptance(for: bundle)
            isAccepted = true
            loadingError = nil
        } catch {
            isAccepted = false
            loadingError = "Не удалось сохранить принятие соглашений: \(error.localizedDescription)"
        }
    }

    func debugResetAcceptance() {
        do {
            try service.deleteAcceptanceForDebug()
            reload()
        } catch {
            loadingError = "Не удалось удалить файл принятия: \(error.localizedDescription)"
        }
    }

    var acceptanceDebugPath: String {
        service.acceptanceFileDebugPath()
    }
}
