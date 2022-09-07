//
//  CreateStepperView.swift
//  EasyVM
//
//  Created by everettjf on 2022/9/7.
//

import SwiftUI

struct CreateStepperView: View {
    var body: some View {
        HStack {
            VStack {
                Text("One")
                Text("One")
                Text("One")
                Text("One")
                Text("One")
                
            }
            
            VStack {
                ZStack {
                    Text("content")
                        
                    Text("content")
                    Text("content")
                    Text("content")
                    Text("content")
                    Text("content")
                }
            }
        }
    }
}

struct CreateStepperView_Previews: PreviewProvider {
    static var previews: some View {
        CreateStepperView()
    }
}
