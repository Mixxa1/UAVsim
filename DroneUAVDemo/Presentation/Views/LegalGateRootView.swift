import SwiftUI

struct LegalGateRootView: View {
    @StateObject private var legalViewModel = LegalAgreementViewModel()

    var body: some View {
        Group {
            if legalViewModel.isAccepted {
                ContentView()
            } else {
                LegalAgreementView(viewModel: legalViewModel)
            }
        }
    }
}
