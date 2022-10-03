//
//  CreatePhaseCompleteView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI



class CreatePhaseCompleteViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }
    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseCompleteView: View {
    @EnvironmentObject var formData: VMCreateViewStateObject
    var body: some View {
        Text("Congratulations :)")
            .font(.title)
            .padding(.all)
    }
}

struct CreatePhaseCompleteView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = VMCreateViewStateObject()
        CreatePhaseCompleteView()
            .environmentObject(formData)
    }
}
