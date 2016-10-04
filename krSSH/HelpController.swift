//
//  HelpController.swift
//  krSSH
//
//  Created by Alex Grinman on 10/4/16.
//  Copyright © 2016 KryptCo. All rights reserved.
//

import Foundation
import UIKit

class HelpController:KRBaseController {
    

}

class HelpInstallController:KRBaseController {

    @IBOutlet weak var installLabel:UILabel!

    enum InstallMethod:String {
        case brew = "brew install kryptco/tap/kr"
        case curl = "curl https://krypt.co/kr | sh"
        case apt = "apt-get install kr"
        
    }
    
    @IBAction func brewTapped() {
        installLabel.text = InstallMethod.brew.rawValue
    }
    
    @IBAction func aptGetTapped() {
        installLabel.text = InstallMethod.apt.rawValue
    }
    
    @IBAction func curlTapped() {
        installLabel.text = InstallMethod.curl.rawValue
    }

}
