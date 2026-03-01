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
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        log.log("CarPlay DISCONNECTED", category: .carplay)
        self.interfaceController = nil
        self.templateManager = nil
        AudioPlayerService.shared.stop()
    }
}
