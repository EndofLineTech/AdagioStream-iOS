import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var templateManager: CarPlayTemplateManager?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
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
        self.interfaceController = nil
        self.templateManager = nil
        AudioPlayerService.shared.stop()
    }
}
