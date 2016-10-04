//
//  ViewController.swift
//  krSSH
//
//  Created by Alex Grinman on 8/26/16.
//  Copyright © 2016 KryptCo Inc. All rights reserved.
//

import UIKit

class MainController: KRBaseTabController, UITabBarControllerDelegate {

    var blurView = UIVisualEffectView(effect: UIBlurEffect(style: UIBlurEffectStyle.light))

    
    lazy var aboutButton:UIBarButtonItem = {
        return UIBarButtonItem(image: UIImage(named: "gear"), style: UIBarButtonItemStyle.plain, target: self, action: #selector(MainController.aboutTapped))
    }()
    
    lazy var helpButton:UIBarButtonItem = {
        return UIBarButtonItem(image: UIImage(named: "help"), style: UIBarButtonItemStyle.plain, target: self, action: #selector(MainController.helpTapped))
    }()

    
    override func viewDidLoad() {
        super.viewDidLoad()

        self.navigationItem.setKrLogo()
        
        self.navigationController?.navigationBar.tintColor = UIColor.white
        self.navigationController?.navigationBar.barTintColor = UIColor.app
        
        self.navigationController?.navigationBar.titleTextAttributes = [NSForegroundColorAttributeName: UIColor.white]
        
        self.tabBar.tintColor = UIColor.app
        self.delegate = self
        
        // add a blur view
        view.addSubview(blurView)
                
        self.navigationItem.leftBarButtonItem = aboutButton
        self.navigationItem.rightBarButtonItem = helpButton
        
//        log("\(LogManager.shared.all.count)")
//        let _ = KeyManager.destroyKeyPair()
//        SessionManager.shared.destory()
//        PeerManager.shared.destory()
    }
    

    func showPushErrorAlert() {
        if TARGET_IPHONE_SIMULATOR == 1 {
            return
        }

        let alertController = UIAlertController(title: "Push Notifications",
                                                message: "Push notifications are not enabled. Please enable push notifications to get real-time notifications when your private key is used for ssh. Push notifications also enable the app to work in the background. Tap `Settings` to continue.",
                                                preferredStyle: .alert)
        
        let settingsAction = UIAlertAction(title: "Settings", style: .default) { (alertAction) in
            
            if let appSettings = URL(string: UIApplicationOpenSettingsURLString) {
                UIApplication.shared.openURL(appSettings)
            }
        }
        alertController.addAction(settingsAction)
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(cancelAction)
        
        present(alertController, animated: true, completion: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        blurView.frame = view.frame

        if !KeyManager.hasKey() {
            self.blurView.isHidden = false
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // temp delete
        
        
        guard KeyManager.hasKey() else {
            self.performSegue(withIdentifier: "showOnboard", sender: nil)
            return
        }
        
        do {
            let kp = try KeyManager.sharedInstance().keyPair
            let pk = try kp.publicKey.export().toBase64()
            
            log("started with: \(pk)")
            
            UIView.animate(withDuration: 0.2, animations: { 
                self.blurView.isHidden = true
            })
            
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "load_new_me"), object: nil)
            

        } catch (let e) {
            log("\(e)", LogType.error)
            showWarning(title: "Fatal Error", body: "\(e)")
            return
        }
        
        // check push
        
        //if push allow reauthorized just incase
        if !UIApplication.shared.isRegisteredForRemoteNotifications && !UserDefaults.standard.bool(forKey: "did_ask_push")
        {
            (UIApplication.shared.delegate as? AppDelegate)?.registerPushNotifications()
            UserDefaults.standard.set(true, forKey: "did_ask_push")
            UserDefaults.standard.synchronize()
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    
    @IBAction func dismissOnboarding(segue: UIStoryboardSegue) {
    }
    

    @IBAction func dismissHelpAndGoToPair(segue: UIStoryboardSegue) {
        self.selectedIndex = 1
    }
    
    
    //MARK: Nav Bar Buttons
    
    dynamic func aboutTapped() {
        self.performSegue(withIdentifier: "showAbout", sender: nil)
    }
    
    dynamic func helpTapped() {
        self.performSegue(withIdentifier: "showHelp", sender: nil)
    }

}
