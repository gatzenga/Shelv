import CarPlay

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var rootController: CarPlayRootController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let controller = CarPlayRootController(interfaceController: interfaceController)
        rootController = controller
        Task { @MainActor in controller.connect() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        let controller = rootController
        rootController = nil
        Task { @MainActor in controller?.disconnect() }
    }
}
