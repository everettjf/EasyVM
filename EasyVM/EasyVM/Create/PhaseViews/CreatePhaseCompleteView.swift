//
//  CreatePhaseCompleteView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI

struct CreatePhaseCompleteView: View {
    @EnvironmentObject var formData: CreateFormModel
    var body: some View {
        Text("Congratulations :)")
            .font(.title)
            .padding(.all)
    }
}

struct CreatePhaseCompleteView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = CreateFormModel()
        CreatePhaseCompleteView()
            .environmentObject(formData)
    }
}
