//
//  CreateFormModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/15.
//

import SwiftUI

class CreateFormModel: ObservableObject {
    @Published var osType: VMModelOSType = .macOS
}
