import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var templateManager: CarPlayTemplateManager?
    private let log = DebugLogger.shared

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        log.log("CarPlay CONNECTED", category: .carplay)
        self.interfaceController = interfaceController
        templateManager = CarPlayTemplateManager(
            interfaceController: interfaceController,
            audioPlayer: AudioPlayerService.shared,
            providerManager: ProviderManager.shared
        )
        templateManager?.configure()
        SXMMetadataService.shared.setFeedPollingEnabled(true)
        ESPNScoreService.shared.setPollingEnabled(true)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        log.log("CarPlay DISCONNECTED", category: .carplay)
        SXMMetadataService.shared.setFeedPollingEnabled(false)
        ESPNScoreService.shared.setPollingEnabled(false)
        self.interfaceController = nil
        self.templateManager = nil
        AudioPlayerService.shared.stop()
    }
}
