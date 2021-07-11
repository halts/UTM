# 不完美啟動

 在iOS14中，蘋果[修補][1]了我們用來讓JIT工作的“把戲”。 因此，下一個最佳的解決方案所涉及的範圍更廣。 這只適用於非越獄設備。 如果你越獄了，你不需要這樣做。

 ## 前置條件

 * Xcode
 * [最新的正式版IPA][3]
 * [iOS App Signer][4]
 * [Homebrew][2]
 * [ios-deploy][5] (`brew install ios-deploy`)

 ## 簽名

 安裝並按照[iOS App Signer][4]的說明進行操作。 請確保您的簽名證書和配置文件匹配。 選擇UTM.ipa正式版作為輸入文件並且按下開始。

 將已簽名的IPA保存為`UTM-signed.ipa`，過程完成後將`UTM-signed.ipa`重命名為`UTM-signed.zip`並且打開ZIP文件。  macOS會將文件提取至名為`Payload/`的新目錄。

 ## 部署

 要部署UTM，連接你的設備然後在終端中運行：

 ```sh
 ios-deploy --bundle /path/to/Payload/UTM.app
 ```

 (提示：你可以把 `Payload/UTM.app` 拖放進終端來自動填充目錄。)

 ## 啟動

 當你每次希望啟動UTM時，都需要運行以下命令。  (你無法在iOS14中從主屏幕正常啟動UTM否則它無法正常運行！)

 ```sh
 ios-deploy --justlaunch --noinstall --bundle /path/to/Payload/UTM.app
 ```

 (提示：如果您打開Xcode並轉到Window->Devices and Simulators並找到您的設備，那麼您可以選中“Connect via network”（通過網絡連接）以便在沒有USB電纜的情況下部署/啟動。你只 需要解鎖設備並靠近你的電腦。)

 ## 疑難解答

 ### 信任問題

 如果你看見了消息：`The operation couldn't be completed. Unable to launch xxx because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user.（無法完成操作。無法啟動xxx， 因為它的代碼簽名無效、授權不足或其配置文件未被用戶明確信任。 ）`，你需要打開設置-> 通用-> 設備管理，選擇開發者描述文件，然後選擇信任。

 ### 註冊捆綁標識符失敗

 Xcode 可能在嘗試創建簽名配置文件時顯示此消息，您需要更改綁定標識符並重試。

 [1]: https://github.com/utmapp/UTM/issues/397
 [2]: https://brew.sh
 [3]: https://github.com/utmapp/UTM/releases
 [4]: https://dantheman827.github.io/ios-app-signer/
 [5]: https://github.com/ios-control/ios-deploy
