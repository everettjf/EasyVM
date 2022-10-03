//
//  CreatePhaseConfigurationView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI


class CreatePhaseConfigurationViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseConfigurationView: View {
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
        CreatePhaseConfigurationView()
    }
}
