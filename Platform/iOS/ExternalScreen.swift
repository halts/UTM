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

@objc class ExternalScreenController: NSObject {
    static var didActivateExternalDisplay = false
    
    private weak var vmViewController: VMDisplayMetalViewController!
    private var metalView: MTKView!
    private var externalWindow: UIWindow?
    private weak var externalVC: UIViewController?
    
    @objc init(vmViewController: VMDisplayMetalViewController, metalView: MTKView) {
        super.init()
        self.vmViewController = vmViewController
        self.metalView = metalView
        
        // Listen for external screen events
        NotificationCenter.default.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self = self else { return }
            // got a new screen connected
            guard let newScreen = notification.object as? UIScreen else { return }
            
            guard !Self.didActivateExternalDisplay else { return }
            Self.didActivateExternalDisplay = true
            self.setupExternalScreen(newScreen)
        }
        
        NotificationCenter.default.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: nil) { [weak self] notification in
            guard Self.didActivateExternalDisplay else { return }
            Self.didActivateExternalDisplay = false
            
            guard let self = self else { return }
            
            guard let oldScreen = notification.object as? UIScreen else { return }
            
            if let window = self.externalWindow, window.screen == oldScreen {
                if let extVC = self.externalVC as? VMExternalDisplayMetalViewController {
                    // discard external metal view
                    extVC.dismiss(animated: false, completion: nil)
                } else if let extVC = self.externalVC {
                    extVC.view.removeFromSuperview()
                    metalView.removeFromSuperview()
                    // move metal view to internal vc
                    vmViewController.view!.insertSubview(metalView, at: 0)
                    metalView.bindFrameToSuperviewBounds()
                }
                let newSize = UIApplication.shared.keyWindow!.bounds.size
                vmViewController.displayResize(newSize)
                vmViewController.resetDisplay()
                let renderer = (self.metalView!.delegate as! UTMRenderer)
                renderer.mtkView(self.metalView!, drawableSizeWillChange: newSize)
                DispatchQueue.main.async {
                    self.metalView!.drawableSize = newSize
                }
                self.externalWindow = nil
                self.externalVC = nil
            }
        }
        
        // screen already connected?
        if UIScreen.screens.count > 1 {
            let newScreen = UIScreen.screens[1]
            guard !Self.didActivateExternalDisplay else { return }
            Self.didActivateExternalDisplay = true
            setupExternalScreen(newScreen)
        }
    }
    
    deinit {
        vmViewController = nil
        externalWindow = nil
        externalVC = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func setupExternalScreen(_ newScreen: UIScreen) {
        // TODO offer resolution switch? Only possible while no window is attached
//        let modes = newScreen.availableModes
//        for (index, mode) in modes.enumerated() {
//            print("External screen mode \(index): \(mode.size.width) x \(mode.size.height)")
//        }

        let screenFrame = CGRect(origin: .zero, size: newScreen.currentMode!.size)
        let newWindow = UIWindow(frame: screenFrame)
        externalWindow = newWindow
        newWindow.screen = newScreen

        makeExtendedDisplayVC(newWindow: newWindow)
//        makeExternalOnlyVC(newWindow: newWindow)
        
        newWindow.isHidden = false
        
        print("setup external display")
    }
    
    @objc func displaySize() -> CGSize {
        if let externalWindow = externalWindow {
            return externalWindow.bounds.size
        } else {
            return vmViewController.view!.bounds.size
        }
    }
    
    private func makeExtendedDisplayVC(newWindow: UIWindow) {
        let extVC = VMExternalDisplayMetalViewController()
        extVC.screenSize = newWindow.bounds.size
        extVC.loadView()
        newWindow.rootViewController = extVC
        self.externalVC = extVC
        /// request `CSDisplay` to create a virtual display with the external window bounds
        guard let mainDisplay = vmViewController.vmDisplay else { return }
        let newMonitorID = mainDisplay.monitorID + 1 // TODO more than 1 external?
        mainDisplay.requestResolution(newWindow.bounds, monitorID: newMonitorID)
    }
    
    private func makeExternalOnlyVC(newWindow: UIWindow) {
        metalView.removeFromSuperview()
        let externalVC = UIViewController()
        newWindow.rootViewController = externalVC
        externalVC.view.addSubview(metalView)
        metalView.bindFrameToSuperviewBounds()
        DispatchQueue.main.async {
            self.vmViewController.displayResize(self.externalWindow!.bounds.size)
            self.vmViewController.resetDisplay()
            let renderer = (self.metalView!.delegate as! UTMRenderer)
            renderer.mtkView(self.metalView!, drawableSizeWillChange: self.externalWindow!.bounds.size)
            self.metalView!.drawableSize = self.externalWindow!.bounds.size
        }
        self.externalVC = externalVC
    }
}
