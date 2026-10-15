import Foundation
import NetworkExtension

@main enum FilterExtensionMain {
    static func main() {
        autoreleasepool { NEProvider.startSystemExtensionMode() }
        dispatchMain()
    }
}
