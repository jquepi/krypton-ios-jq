//
//  Globals.swift
//  krSSH
//
//  Created by Alex Grinman on 8/29/16.
//  Copyright © 2016 KryptCo Inc. All rights reserved.
//

import Foundation

//MARK: Keys
let KR_ENDPOINT_ARN_KEY = "aws_endpoint_arn_key"

//MARK: Functions
func isDebug() -> Bool {
    #if DEBUG
        return true
    #else
        return false
    #endif
}



