//
//  CreateSelectSystemTypeView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/7.
//

import SwiftUI

struct SystemCardView: View {
    let image: String
    let name: String
    let selected: Bool
    
    @State private var borderColor: Color = .gray
    
    var body: some View {
        VStack {
            Image(systemName: image)
                .font(.system(size: 70))
                .frame(width:100,height: 120)
            
            Text(name)
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: selected ? 5 : 1)
        )
        .shadow(radius: 16)
        .onHover { hover in
            if hover {
                borderColor = .blue
            } else {
                borderColor = .gray
            }
        }
    }
}

class CreatePhaseSystemTypeViewHandler: CreateStepperGuidePhaseHandler {
    
    func verifyForm(context: CreateStepperGuidePhaseContext) -> CreateStepperGuidePhaseVerifyResult {
        return .success
    }
    func onStepMovedIn(context: CreateStepperGuidePhaseContext) -> Bool {
        return true
    }
}

struct CreatePhaseSystemTypeView: View {
    @EnvironmentObject var formData: CreateFormStateObject
    
    var body: some View {
        VStack {
            Text("Choose one of the operating systems.")
                .font(.title3)
                .padding(.all)
            Spacer()
            HStack(spacing: 30) {
                SystemCardView(image: "macpro.gen3", name: "macOS", selected: formData.osType == .macOS)
                    .onTapGesture {
                        formData.osType = .macOS
                    }
                SystemCardView(image: "pc", name: "Linux", selected: formData.osType == .linux)
                    .onTapGesture {
                        formData.osType = .linux
                    }
            }
            VStack {
                if formData.osType == .macOS {
                    Text("You choose macOS now :)")
                } else {
                    Text("You choose linux now :)")
                }
            }
            .padding(.all)
            
            Spacer()
        }
        
    }
}

struct CreatePhaseSystemTypeView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = CreateFormStateObject()
        CreatePhaseSystemTypeView()
            .frame(width:500, height: 500)
            .environmentObject(formData)
    }
}
