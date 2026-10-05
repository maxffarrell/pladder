import Foundation
import PladderCore

public enum CoreAIParakeetModel: String, CaseIterable, Sendable {
    case v3, ultra, redux

    public var engineID: EngineID { EngineID("parakeet-\(rawValue)-coreai") }
    public var displayName: String {
        switch self {
        case .v3: "Parakeet v3"
        case .ultra: "Parakeet Ultra"
        case .redux: "Parakeet Redux"
        }
    }
    var bundleName: String {
        switch self {
        case .v3: "parakeet-tdt-0.6b-v3_float16_streaming150"
        case .ultra: "parakeet-ultra_float16_streaming150"
        case .redux: "parakeet-redux_float16_streaming150"
        }
    }
    // Release artifacts are pinned after physical-device qualification.
    var artifact: CoreAIArtifact { CoreAIArtifacts.artifact(for: self) }
}

struct CoreAIArtifact: Sendable {
    let repository: String
    let revision: String
    let sha256: String
    let bytes: Int64
    var url: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/model.zip")!
    }
}

enum CoreAIArtifacts {
    static func artifact(for model: CoreAIParakeetModel) -> CoreAIArtifact {
        switch model {
        case .redux:
            CoreAIArtifact(repository: "maxffarrell/parakeet-redux-coreai", revision: "d8c8956f5d26c65f15467ac4f85e9146e65aa536", sha256: "8f50e79dbf90ff74ad21d5905ba346350568cfad194df0bfce3c3835c56dddd3", bytes: 344632840)
        case .v3:
            CoreAIArtifact(repository: "maxffarrell/parakeet-v3-coreai", revision: "8f73472d82c41c9a00c470d22e88cea8b48b7d9e", sha256: "f3e383b7c777f02ee928fd503d386447fa7cf58327483acb4294386f86c8e359", bytes: 1165836322)
        case .ultra:
            CoreAIArtifact(repository: "maxffarrell/parakeet-ultra-coreai", revision: "c8d7dfb71248c128345d15e3cf5d8ba7c76ddac2", sha256: "a0059f4740eecb077a60fb99ff6de3bb90880aabb5c009e2b19c6d41d269f430", bytes: 1165834385)
        }
    }
}
