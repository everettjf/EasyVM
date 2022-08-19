//
//  AppConfig.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/18.
//

import Foundation

/*
 
 VM items come from :
 1. items in default workspace directory
 2. additional items manually added to the list
 
 */

struct AppConfigModel: Decodable {
    let workspaceDir: String
}

class AppConfigManager {
    
}

let sharedAppConfigManager = AppConfigManager()


