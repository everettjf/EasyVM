//
//  CreatePhaseConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseConfigurationView: View {
    @EnvironmentObject var formData: CreateFormModel
    var body: some View {
        VStack {
            Text("Config Virtual Hardwares")
                .font(.title3)
                .padding(.all)
            VMConfigurationView()
        }
    }
}

struct CreatePhaseConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = CreateFormModel()
        CreatePhaseConfigurationView()
            .environmentObject(formData)
    }
}