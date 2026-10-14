import Foundation
import NetworkExtension

@main enum SystemExtensionMain {
    static func main() {
        autoreleasepool {
            NEProvider.startSystemExtensionMode()
        }
        dispatchMain()
    }
}
