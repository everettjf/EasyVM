//
//  ContentView.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/24.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack {
            HeaderView()

            BodyView()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
