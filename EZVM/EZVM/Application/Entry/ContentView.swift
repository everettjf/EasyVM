//
//  ContentView.swift
//  EZVM
//
//  Created by everettjf on 2022/6/24.
//
import Foundation
import SwiftUI


#if arch(arm64)
struct ContentView: View {
    var body: some View {
        MachinesDetailHomeView()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


#endif
