import Foundation

enum UAVVisualPreset: String, CaseIterable, Hashable {
    case abstractCustom
    case djiMatrice350RTK
    case djiMavic4Pro
    case djiNeo
    case djiPhantom3Standard
    case freeflyAltaX
    case wingtraOneGenII
    case quantumSystemsTrinityPro
    case djiFlyCart30
    case griff30
    case griff60
    case avidrone490TL
    case mq9bSkyGuardian
    case hermes900
    case ft5Los
    case flyEye

    var title: String {
        switch self {
        case .abstractCustom:
            return "Abstract UAV"
        case .djiMatrice350RTK:
            return "DJI Matrice 350 RTK"
        case .djiMavic4Pro:
            return "DJI Mavic 4 Pro"
        case .djiNeo:
            return "DJI Neo"
        case .djiPhantom3Standard:
            return "DJI Phantom 3 Standard"
        case .freeflyAltaX:
            return "Freefly Alta X"
        case .wingtraOneGenII:
            return "WingtraOne GEN II"
        case .quantumSystemsTrinityPro:
            return "Quantum Systems Trinity Pro"
        case .djiFlyCart30:
            return "DJI FlyCart 30"
        case .griff30:
            return "Griff 30"
        case .griff60:
            return "Griff 60"
        case .avidrone490TL:
            return "Avidrone 490TL"
        case .mq9bSkyGuardian:
            return "MQ-9B SkyGuardian"
        case .hermes900:
            return "Hermes 900"
        case .ft5Los:
            return "FT5 Łoś"
        case .flyEye:
            return "FlyEye"
        }
    }
}
