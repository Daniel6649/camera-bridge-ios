import SwiftUI
import UIKit

@main
struct CameraBridgeApp: App {
    init() {
        let segments = UISegmentedControl.appearance()
        segments.selectedSegmentTintColor = UIColor(red: 45/255, green: 107/255, blue: 1, alpha: 1)
        segments.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segments.setTitleTextAttributes([.foregroundColor: UIColor(red: 237/255, green: 243/255, blue: 1, alpha: 1)], for: .normal)
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
