//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import UIKit

class VMExternalDisplayMetalViewController: UIViewController {
    private let mtkView = MTKView()
    var screenSize: CGSize!
    
    override func loadView() {
        super.loadView()
        NotificationCenter.default.addObserver(self, selector: #selector(handleDisplayAdded), name: .init(rawValue: "externalDisplayAdded"), object: nil)
    }
    
    private var renderer: UTMRenderer!
    var sourceScreen: UTMRenderSource?
    var sourceCursor: UTMRenderSource?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(mtkView)
        mtkView.bindFrameToSuperviewBounds()
        
        // Set the view to use the default device
        mtkView.device = MTLCreateSystemDefaultDevice();
        if ((self.mtkView.device == nil)) {
            UTM.logger.critical("Metal is not supported on this device")
            return;
        }
    }
    
    @objc func handleDisplayAdded(_ notification: Notification) {
        print("Yippie kay jay Schweinebacke")
        guard let userInfo = notification.userInfo,
              let display = userInfo["display"] as? CSDisplayMetal,
              let input = userInfo["input"] as? CSInput else { return }
        sourceScreen = display
        sourceCursor = input
        
        renderer = UTMRenderer(metalKitView: mtkView)
        renderer.sourceScreen = sourceScreen
        renderer.sourceCursor = sourceCursor
        mtkView.delegate = renderer
        renderer.mtkView(mtkView, drawableSizeWillChange: screenSize)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self)
    }
}
